import SwiftUI

struct ConversationListView: View {
    let filter: ConversationFilter
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var folderFilter: UUID?
    @State private var showUnfiledOnly = false
    @State private var actionTarget: Conversation?

    private var base: [Conversation] {
        let store = app.conversations
        switch filter {
        case .all: return store.active
        case .favorites: return store.favorites
        case .archived: return store.archived
        case .folder(let id): return store.active.filter { $0.folderID == id }
        case .unfiled: return store.active.filter { $0.folderID == nil }
        case .tag(let t): return store.active.filter { $0.tags.contains(t) }
        }
    }

    private var items: [Conversation] {
        var list = base.filter { $0.messageCount > 0 || $0.isPinned }
        if filter == .all {
            if showUnfiledOnly { list = list.filter { $0.folderID == nil } }
            else if let f = folderFilter { list = list.filter { $0.folderID == f } }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q)
                    || $0.lastQuestion.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }
                    || ($0.summary?.lowercased().contains(q) ?? false)
            }
        }
        return list
    }

    private var title: String {
        if case .folder(let id) = filter, let f = app.conversations.folder(id) { return f.emoji + f.name }
        return filter.title
    }

    var body: some View {
        List {
            if filter == .all && !app.conversations.folders.isEmpty {
                folderChips
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if items.isEmpty {
                Text(query.isEmpty ? "这里还没有对话" : "没有匹配的对话").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(items) { c in
                NavigationLink(value: Route.chat(c.id)) {
                    ConversationRow(conversation: c)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { app.conversations.delete(c.id) } label: { Image(systemName: "trash") }
                    Button {
                        app.conversations.update(c.id) { $0.isArchived.toggle() }
                    } label: { Image(systemName: c.isArchived ? "tray.and.arrow.up" : "archivebox") }
                        .tint(.indigo)
                    Button { actionTarget = c } label: { Image(systemName: "ellipsis") }
                        .tint(.gray)
                }
                .swipeActions(edge: .leading) {
                    Button { app.conversations.update(c.id) { $0.isPinned.toggle() } } label: {
                        Image(systemName: c.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                    Button { app.conversations.update(c.id) { $0.isFavorite.toggle() } } label: {
                        Image(systemName: c.isFavorite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
            }
            if !query.isEmpty {
                NavigationLink(value: Route.search) {
                    Label("在消息内容中搜索", systemImage: "text.magnifyingglass").font(.footnote)
                }
            }
            if filter == .archived && !items.isEmpty {
                Section {
                    Text("左滑可取消归档或删除").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query, prompt: "搜索标题/内容/标签")
        .navigationTitle(title)
        .toolbar {
            if filter == .all || filter == .favorites {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let id = app.newConversation()
                        app.router.open(.chat(id))
                    } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
        .sheet(item: $actionTarget) { c in
            NavigationStack { ConversationActionsSheet(conversationID: c.id) }
        }
    }

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip("全部", selected: folderFilter == nil && !showUnfiledOnly) { folderFilter = nil; showUnfiledOnly = false }
                ForEach(app.conversations.folders) { f in
                    chip("\(f.emoji)\(f.name)", selected: folderFilter == f.id) { folderFilter = f.id; showUnfiledOnly = false }
                }
                chip("未分类", selected: showUnfiledOnly) { showUnfiledOnly = true; folderFilter = nil }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// 对话的快捷整理操作
struct ConversationActionsSheet: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        if let c = app.conversations.conversation(conversationID) {
            List {
                Section {
                    TextField("标题", text: Binding(
                        get: { app.conversations.conversation(conversationID)?.title ?? "" },
                        set: { v in app.conversations.update(conversationID) { $0.title = v; $0.titleGenerated = true } }))
                        .font(.footnote)
                }
                Section {
                    Button { app.conversations.update(conversationID) { $0.isPinned.toggle() } } label: {
                        Label(c.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                    }
                    Button { app.conversations.update(conversationID) { $0.isFavorite.toggle() } } label: {
                        Label(c.isFavorite ? "取消收藏" : "收藏", systemImage: "star")
                    }
                    NavigationLink { FolderPickerView(conversationID: conversationID) } label: {
                        Label("移动到文件夹", systemImage: "folder")
                    }
                    NavigationLink { TagEditorView(conversationID: conversationID) } label: {
                        Label("编辑标签", systemImage: "tag")
                    }
                    Button {
                        app.conversations.update(conversationID) { $0.isArchived.toggle() }
                        dismiss()
                    } label: {
                        Label(c.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                    }
                    ShareLink(item: app.conversations.exportMarkdown(conversationID)) {
                        Label("导出 Markdown", systemImage: "square.and.arrow.up")
                    }
                }
                if let s = c.summary {
                    Section("摘要") { MarkdownView(s, compact: true) }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                }
            }
            .navigationTitle(c.title)
            .confirmationDialog("删除对话？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    app.conversations.delete(conversationID)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 文件夹与智能整理

struct FolderListView: View {
    @Environment(AppModel.self) private var app
    @State private var organizing = false
    @State private var result: String?
    @State private var renameTitles = true
    @State private var onlyUnfiled = true
    @State private var editing: Folder?
    @State private var archiveDays = 30

    var body: some View {
        List {
            Section {
                Button {
                    organizing = true
                    result = nil
                    Task {
                        do {
                            let r = try await app.engine.organize(renameTitles: renameTitles, onlyUnfiled: onlyUnfiled)
                            result = "已整理 \(r.moved) 个对话，新建 \(r.newFolders) 个文件夹，重命名 \(r.renamed) 个。"
                        } catch {
                            result = "⚠️ " + ChatEngine.describe(error)
                        }
                        organizing = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text(organizing ? "AI 整理中…" : "AI 智能整理")
                        if organizing { Spacer(); ProgressView().controlSize(.mini).frame(width: 14) }
                    }
                }
                .disabled(organizing)
                Toggle("只整理未分类", isOn: $onlyUnfiled).font(.footnote)
                Toggle("同时优化标题", isOn: $renameTitles).font(.footnote)
                if let result { Text(result).font(.caption2).foregroundStyle(.secondary) }
            } footer: {
                Text("由 AI 根据内容自动分配文件夹、生成标题与标签（最多 40 个对话）。")
            }

            Section("文件夹") {
                NavigationLink(value: Route.conversations(.unfiled)) {
                    HStack {
                        Text("📥 未分类")
                        Spacer()
                        Text("\(app.conversations.active.filter { $0.folderID == nil && $0.messageCount > 0 }.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(app.conversations.folders) { f in
                    NavigationLink(value: Route.conversations(.folder(f.id))) {
                        HStack {
                            Text("\(f.emoji) \(f.name)")
                            Spacer()
                            Text("\(app.conversations.count(in: f.id))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { app.conversations.deleteFolder(f.id) } label: { Image(systemName: "trash") }
                        Button { editing = f } label: { Image(systemName: "pencil") }.tint(.gray)
                    }
                }
                TextFieldLink(prompt: Text("文件夹名称")) {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                } onSubmit: { name in
                    let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { app.conversations.addFolder(name: t) }
                }
            }

            let tags = app.conversations.allTags
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags, id: \.self) { t in
                        NavigationLink(value: Route.conversations(.tag(t))) { Text("#\(t)") }
                    }
                }
            }

            Section {
                Stepper(value: $archiveDays, in: 1...365, step: archiveDays < 14 ? 1 : 7) {
                    Text("\(archiveDays) 天前").font(.footnote)
                }
                Button {
                    let n = app.conversations.archiveAll(olderThanDays: archiveDays)
                    result = "已归档 \(n) 个对话。"
                } label: {
                    Label("批量归档旧对话", systemImage: "archivebox")
                }
            } header: {
                Text("批量归档")
            } footer: {
                Text("置顶对话不会被归档。可在设置中开启自动归档。")
            }
        }
        .navigationTitle("整理")
        .sheet(item: $editing) { f in
            FolderEditSheet(folder: f)
        }
    }
}

struct FolderEditSheet: View {
    let folder: Folder
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = ""
    private let emojis = ["📁", "💼", "📚", "💻", "✈️", "🍳", "💡", "🏃", "🎮", "🎵", "💰", "🏠", "❤️", "🔬", "🌐", "📝"]

    var body: some View {
        List {
            TextField("名称", text: $name)
            Section("图标") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    ForEach(emojis, id: \.self) { e in
                        Button { emoji = e } label: {
                            Text(e).font(.title3)
                                .padding(3)
                                .background(Circle().fill(emoji == e ? Color.accentColor.opacity(0.4) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("保存") {
                app.conversations.renameFolder(folder.id, name: name.isEmpty ? folder.name : name, emoji: emoji)
                dismiss()
            }
        }
        .onAppear { name = folder.name; emoji = folder.emoji }
    }
}

// MARK: - 收藏

struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = 0

    var body: some View {
        List {
            Picker("类型", selection: $tab) {
                Text("对话").tag(0)
                Text("消息").tag(1)
            }
            .pickerStyle(.navigationLink)
            if tab == 0 {
                let favs = app.conversations.favorites
                if favs.isEmpty { Text("左滑对话即可收藏").font(.caption2).foregroundStyle(.secondary) }
                ForEach(favs) { c in
                    NavigationLink(value: Route.chat(c.id)) { ConversationRow(conversation: c) }
                        .swipeActions {
                            Button { app.conversations.update(c.id) { $0.isFavorite = false } } label: { Image(systemName: "star.slash") }
                        }
                }
            } else {
                let refs = app.conversations.favoriteMessages
                if refs.isEmpty { Text("在消息的 ⋯ 菜单中收藏").font(.caption2).foregroundStyle(.secondary) }
                ForEach(refs) { ref in
                    NavigationLink {
                        FavoriteMessageDetail(ref: ref)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 3) {
                                Image(systemName: ref.role == .user ? "person.fill" : "sparkles").font(.system(size: 9))
                                Text(app.conversations.conversation(ref.conversationID)?.title ?? "已删除的对话")
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            Text(ref.snippet).font(.footnote).lineLimit(3)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            app.conversations.toggleFavoriteMessage(ref.conversationID, ref.messageID)
                        } label: { Image(systemName: "star.slash") }
                    }
                }
            }
        }
        .navigationTitle("收藏")
    }
}

struct FavoriteMessageDetail: View {
    let ref: FavoriteMessageRef
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let m = app.conversations.message(ref.conversationID, ref.messageID) {
                    if m.role == .user { Text(m.content) } else { MarkdownView(m.content) }
                    Text(Fmt.dateTime(m.createdAt)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(ref.snippet)
                }
                if app.conversations.conversation(ref.conversationID) != nil {
                    Button {
                        app.router.path.append(.chat(ref.conversationID))
                    } label: {
                        Label("打开所在对话", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        }
        .navigationTitle("收藏的消息")
        .modifier(InlineWebLinks())
    }
}

// MARK: - 全文搜索

struct GlobalSearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var includeArchived = true

    var body: some View {
        List {
            TextFieldLink(prompt: Text("关键词，空格分隔")) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(query.isEmpty ? "输入关键词" : query).lineLimit(1)
                }
            } onSubmit: { q in
                query = q
                run()
            }
            Toggle("包含归档", isOn: $includeArchived).font(.footnote)
                .onChange(of: includeArchived) { _, _ in if !query.isEmpty { run() } }
            if searching {
                ProgressView()
            } else if !query.isEmpty {
                Section("\(hits.count) 条结果") {
                    ForEach(hits) { h in
                        NavigationLink(value: Route.chat(h.conversationID)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.conversationTitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Text(highlight(h.snippet)).font(.caption).lineLimit(4)
                                Text("\(h.role == .user ? "提问" : "回答") · \(Fmt.relative(h.date))")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("全文搜索")
    }

    private func run() {
        guard !query.isEmpty else { return }
        searching = true
        Task {
            hits = await SearchService.search(query, in: app.conversations, includeArchived: includeArchived, limit: 60)
            searching = false
        }
    }

    private func highlight(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        for term in query.split(separator: " ").map(String.init) where !term.isEmpty {
            var searchRange = a.startIndex..<a.endIndex
            while let r = a[searchRange].range(of: term, options: .caseInsensitive) {
                a[r].foregroundColor = .yellow
                a[r].font = .caption.bold()
                searchRange = r.upperBound..<a.endIndex
            }
        }
        return a
    }
}
