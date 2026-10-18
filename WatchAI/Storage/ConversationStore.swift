import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    private(set) var folders: [Folder] = []
    private(set) var favoriteMessages: [FavoriteMessageRef] = []
    /// 已加载的消息缓存（懒加载不触发界面刷新，修改时通过 revision 通知）
    @ObservationIgnored private var messageCache: [UUID: [ChatMessage]] = [:]
    private(set) var revision: [UUID: Int] = [:]

    private let indexFile = "conversations.json"
    private let foldersFile = "folders.json"
    private let favoritesFile = "favorite_messages.json"
    private let messagesDir = FileStore.directory("messages")
    @ObservationIgnored private var indexSaveScheduled = false

    init() {
        conversations = FileStore.load([Conversation].self, from: indexFile) ?? []
        folders = FileStore.load([Folder].self, from: foldersFile) ?? []
        favoriteMessages = FileStore.load([FavoriteMessageRef].self, from: favoritesFile) ?? []
    }

    // MARK: - 查询

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    var active: [Conversation] {
        conversations.filter { !$0.isArchived }.sorted(by: Self.sortRule)
    }

    var archived: [Conversation] {
        conversations.filter { $0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var pinned: [Conversation] { active.filter { $0.isPinned } }

    var recent: [Conversation] { active.filter { !$0.isPinned && $0.messageCount > 0 } }

    var favorites: [Conversation] {
        conversations.filter { $0.isFavorite }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func sortRule(_ a: Conversation, _ b: Conversation) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.updatedAt > b.updatedAt
    }

    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first(where: { $0.id == id })
    }

    // MARK: - 消息

    private func bump(_ id: UUID) { revision[id, default: 0] &+= 1 }

    func messages(_ id: UUID) -> [ChatMessage] {
        _ = revision[id]
        if let cached = messageCache[id] { return cached }
        let loaded = loadMessagesFromDisk(id)
        messageCache[id] = loaded
        return loaded
    }

    private func messagesURL(_ id: UUID) -> URL {
        messagesDir.appendingPathComponent(id.uuidString + ".json")
    }

    private func loadMessagesFromDisk(_ id: UUID) -> [ChatMessage] {
        var list = FileStore.load([ChatMessage].self, from: messagesURL(id)) ?? []
        for i in list.indices where list[i].status == .streaming {
            list[i].status = .interrupted
        }
        return list
    }

    /// 后台读取所有对话的消息（用于速览与全文搜索）
    nonisolated static func loadMessagesInBackground(ids: [UUID]) async -> [UUID: [ChatMessage]] {
        await Task.detached(priority: .userInitiated) {
            var result: [UUID: [ChatMessage]] = [:]
            let dir = FileStore.directory("messages")
            for id in ids {
                let url = dir.appendingPathComponent(id.uuidString + ".json")
                if let list = FileStore.load([ChatMessage].self, from: url) {
                    result[id] = list
                }
            }
            return result
        }.value
    }

    func allMessagesSnapshot(includeArchived: Bool) async -> [UUID: [ChatMessage]] {
        let ids = conversations.filter { includeArchived || !$0.isArchived }.map(\.id)
        let missing = ids.filter { messageCache[$0] == nil }
        let loaded = await Self.loadMessagesInBackground(ids: missing)
        var result: [UUID: [ChatMessage]] = [:]
        for id in ids {
            result[id] = messageCache[id] ?? loaded[id] ?? []
        }
        return result
    }

    func setMessages(_ id: UUID, _ list: [ChatMessage], persist: Bool = true) {
        messageCache[id] = list
        bump(id)
        if persist {
            saveMessages(id)
            refreshMeta(id)
        }
    }

    func saveMessages(_ id: UUID) {
        guard let list = messageCache[id] else { return }
        FileStore.save(list, to: messagesURL(id))
    }

    func append(_ message: ChatMessage, to id: UUID, persist: Bool = true) {
        var list = messages(id)
        list.append(message)
        setMessages(id, list, persist: persist)
    }

    func updateMessage(_ conversationID: UUID, _ messageID: UUID, persist: Bool = false, _ mutate: (inout ChatMessage) -> Void) {
        var list = messages(conversationID)
        guard let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        mutate(&list[idx])
        messageCache[conversationID] = list
        bump(conversationID)
        if persist {
            saveMessages(conversationID)
            refreshMeta(conversationID)
        }
    }

    func message(_ conversationID: UUID, _ messageID: UUID) -> ChatMessage? {
        messages(conversationID).first(where: { $0.id == messageID })
    }

    func deleteMessage(_ conversationID: UUID, _ messageID: UUID) {
        var list = messages(conversationID)
        guard let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        let msg = list.remove(at: idx)
        // 删除 assistant 工具调用时，一并删除对应的工具结果
        if msg.role == .assistant, !msg.toolCalls.isEmpty {
            let ids = Set(msg.toolCalls.map(\.id))
            list.removeAll { $0.role == .tool && ids.contains($0.toolCallID ?? "") }
        }
        AttachmentStore.delete(msg.images)
        removeFavoriteRef(messageID)
        setMessages(conversationID, list)
    }

    /// 删除某条消息之后（含自身可选）的所有消息
    func truncate(_ conversationID: UUID, from messageID: UUID, inclusive: Bool) {
        var list = messages(conversationID)
        guard let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        let start = inclusive ? idx : idx + 1
        guard start < list.count else { return }
        let removed = list[start...]
        for m in removed {
            removeFavoriteRef(m.id)
        }
        list.removeSubrange(start...)
        setMessages(conversationID, list)
    }

    // MARK: - 元数据

    func refreshMeta(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let list = messageCache[id] ?? []
        var c = conversations[idx]
        let visible = list.filter { $0.role == .user || $0.role == .assistant }
        c.messageCount = visible.count
        if let lastAssistant = list.last(where: { $0.role == .assistant && !$0.content.isEmpty }) {
            c.preview = Self.plainSnippet(lastAssistant.content, limit: 80)
        } else if let last = visible.last {
            c.preview = Self.plainSnippet(last.content, limit: 80)
        }
        if let q = list.last(where: { $0.role == .user }) {
            c.lastQuestion = Self.plainSnippet(q.content, limit: 60)
        }
        let usage = list.compactMap(\.usage)
        c.totalTokens = usage.reduce(0) { $0 + $1.totalTokens }
        c.totalCost = usage.reduce(0) { $0 + $1.cost }
        if let cur = usage.last?.currency { c.costCurrency = cur }
        if let last = list.last { c.updatedAt = max(c.updatedAt, last.createdAt) }
        conversations[idx] = c
        scheduleIndexSave()
    }

    static func plainSnippet(_ text: String, limit: Int) -> String {
        var s = text
        if let range = s.range(of: "</think>") { s = String(s[range.upperBound...]) }
        s = s.replacingOccurrences(of: "```[a-zA-Z0-9]*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[#*`>|_]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    func update(_ id: UUID, _ mutate: (inout Conversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[idx])
        scheduleIndexSave()
    }

    @discardableResult
    func create(persona: Persona? = nil) -> Conversation {
        var c = Conversation()
        if let persona {
            c.personaID = persona.id
            c.systemPrompt = persona.systemPrompt
            c.providerID = persona.providerID
            c.modelName = persona.modelName
            c.temperature = persona.temperature
            if !persona.systemPrompt.isEmpty { c.title = persona.emoji + " " + persona.name }
        }
        conversations.insert(c, at: 0)
        messageCache[c.id] = []
        scheduleIndexSave()
        return c
    }

    func delete(_ id: UUID) {
        let list = messages(id)
        for m in list { AttachmentStore.delete(m.images) }
        favoriteMessages.removeAll { $0.conversationID == id }
        FileStore.save(favoriteMessages, to: favoritesFile)
        conversations.removeAll { $0.id == id }
        messageCache[id] = nil
        bump(id)
        FileStore.remove(messagesURL(id))
        scheduleIndexSave()
    }

    /// 删除未发送过消息的空对话
    func discardIfEmpty(_ id: UUID) {
        guard let c = conversation(id), c.messageCount == 0, messages(id).isEmpty else { return }
        conversations.removeAll { $0.id == id }
        messageCache[id] = nil
        FileStore.remove(messagesURL(id))
        scheduleIndexSave()
    }

    func deleteAll(includeFavorites: Bool) {
        for c in conversations where includeFavorites || !c.isFavorite {
            delete(c.id)
        }
    }

    /// 从某条消息处分叉出新对话
    func branch(_ conversationID: UUID, upTo messageID: UUID) -> Conversation? {
        guard let source = conversation(conversationID) else { return nil }
        let list = messages(conversationID)
        guard let idx = list.firstIndex(where: { $0.id == messageID }) else { return nil }
        var c = source
        c.id = UUID()
        c.title = "分叉 · " + source.title
        c.createdAt = Date()
        c.updatedAt = Date()
        c.isPinned = false
        c.isFavorite = false
        c.isArchived = false
        c.reflectedMessageCount = 0
        c.titleGenerated = true
        var copied: [ChatMessage] = []
        for var m in list[...idx] {
            m.id = UUID()
            m.isFavorite = false
            // 复制图片文件，避免删除原对话时丢失
            m.images = m.images.compactMap { img in
                guard let data = AttachmentStore.data(for: img) else { return nil }
                let name = UUID().uuidString + ".jpg"
                try? data.write(to: AttachmentStore.directory.appendingPathComponent(name))
                var n = img
                n.id = UUID()
                n.fileName = name
                return n
            }
            copied.append(m)
        }
        // 对齐上下文摘要引用
        c.contextSummary = nil
        c.contextSummaryUntil = nil
        conversations.insert(c, at: 0)
        setMessages(c.id, copied)
        return c
    }

    // MARK: - 收藏消息

    func toggleFavoriteMessage(_ conversationID: UUID, _ messageID: UUID) {
        guard let msg = message(conversationID, messageID) else { return }
        let newValue = !msg.isFavorite
        updateMessage(conversationID, messageID, persist: true) { $0.isFavorite = newValue }
        if newValue {
            let ref = FavoriteMessageRef(conversationID: conversationID, messageID: messageID, role: msg.role,
                                         snippet: Self.plainSnippet(msg.content, limit: 120), date: Date())
            favoriteMessages.insert(ref, at: 0)
        } else {
            favoriteMessages.removeAll { $0.messageID == messageID }
        }
        FileStore.save(favoriteMessages, to: favoritesFile)
    }

    private func removeFavoriteRef(_ messageID: UUID) {
        guard favoriteMessages.contains(where: { $0.messageID == messageID }) else { return }
        favoriteMessages.removeAll { $0.messageID == messageID }
        FileStore.save(favoriteMessages, to: favoritesFile)
    }

    // MARK: - 文件夹

    @discardableResult
    func addFolder(name: String, emoji: String = "📁") -> Folder {
        if let existing = folders.first(where: { $0.name == name }) { return existing }
        let f = Folder(name: name, emoji: emoji)
        folders.append(f)
        FileStore.save(folders, to: foldersFile)
        return f
    }

    func renameFolder(_ id: UUID, name: String, emoji: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        folders[i].emoji = emoji
        FileStore.save(folders, to: foldersFile)
    }

    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for i in conversations.indices where conversations[i].folderID == id {
            conversations[i].folderID = nil
        }
        FileStore.save(folders, to: foldersFile)
        scheduleIndexSave()
    }

    func count(in folderID: UUID) -> Int {
        conversations.filter { $0.folderID == folderID && !$0.isArchived }.count
    }

    var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in conversations {
            for t in c.tags where !seen.contains(t) {
                seen.insert(t)
                out.append(t)
            }
        }
        return out
    }

    // MARK: - 归档

    func autoArchive(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var changed = false
        for i in conversations.indices {
            let c = conversations[i]
            if !c.isArchived && !c.isPinned && !c.isFavorite && c.updatedAt < cutoff && c.messageCount > 0 {
                conversations[i].isArchived = true
                changed = true
            }
        }
        if changed { scheduleIndexSave() }
    }

    func archiveAll(olderThanDays days: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var n = 0
        for i in conversations.indices where !conversations[i].isArchived && !conversations[i].isPinned && conversations[i].updatedAt < cutoff {
            conversations[i].isArchived = true
            n += 1
        }
        scheduleIndexSave()
        return n
    }

    // MARK: - 持久化

    private func scheduleIndexSave() {
        guard !indexSaveScheduled else { return }
        indexSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.indexSaveScheduled = false
            FileStore.save(self.conversations, to: self.indexFile)
        }
    }

    func saveNow(including ids: [UUID] = []) {
        FileStore.save(conversations, to: indexFile)
        for id in ids { saveMessages(id) }
    }

    // MARK: - 导出

    func exportMarkdown(_ id: UUID) -> String {
        guard let c = conversation(id) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(c.title)\n\n> \(df.string(from: c.createdAt))\n\n"
        for m in messages(id) {
            switch m.role {
            case .user: out += "**🙋 用户**\n\n\(m.content)\n\n"
            case .assistant:
                if !m.content.isEmpty { out += "**🤖 助手**\(m.modelName.map { "（\($0)）" } ?? "")\n\n\(m.content)\n\n" }
            case .tool: out += "> 🔧 \(m.displayText ?? m.toolName ?? "工具")\n\n"
            case .divider: out += "---\n\n"
            case .system: break
            }
        }
        return out
    }
}
