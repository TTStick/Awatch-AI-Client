import Foundation
import Observation

@MainActor
@Observable
final class MemoryStore {
    private(set) var memories: [MemoryItem] = []
    private(set) var logs: [ReflectionLog] = []
    /// 正在反思的对话
    var reflectingIDs: Set<UUID> = []
    var isConsolidating = false

    init() {
        memories = FileStore.load([MemoryItem].self, from: "memories.json") ?? []
        logs = FileStore.load([ReflectionLog].self, from: "reflection_logs.json") ?? []
    }

    var sorted: [MemoryItem] {
        memories.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    var grouped: [(category: String, items: [MemoryItem])] {
        let dict = Dictionary(grouping: sorted, by: \.category)
        let order = MemoryItem.categories
        return dict.keys.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            .map { ($0, dict[$0] ?? []) }
    }

    /// 注入系统提示词的记忆
    func injectable(limit: Int) -> [MemoryItem] {
        Array(sorted.filter { $0.isEnabled }.prefix(max(0, limit)))
    }

    @discardableResult
    func add(_ content: String, category: String = "其他", source: MemorySource, conversationID: UUID? = nil) -> MemoryItem? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let dup = memories.first(where: { $0.content == text }) { return dup }
        let cat = MemoryItem.categories.contains(category) ? category : "其他"
        let m = MemoryItem(content: text, category: cat, source: source, conversationID: conversationID)
        memories.insert(m, at: 0)
        save()
        return m
    }

    func update(_ id: UUID, _ mutate: (inout MemoryItem) -> Void) {
        guard let i = memories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&memories[i])
        memories[i].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        memories.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        memories = []
        save()
    }

    func search(_ query: String) -> [MemoryItem] {
        let q = query.lowercased()
        guard !q.isEmpty else { return sorted }
        let terms = q.split(separator: " ").map(String.init)
        return sorted.filter { m in
            let c = m.content.lowercased()
            return terms.contains { c.contains($0) } || m.category.contains(q)
        }
    }

    func addLog(_ log: ReflectionLog) {
        logs.insert(log, at: 0)
        if logs.count > 100 { logs = Array(logs.prefix(100)) }
        FileStore.save(logs, to: "reflection_logs.json")
    }

    func clearLogs() {
        logs = []
        FileStore.save(logs, to: "reflection_logs.json")
    }

    private func save() { FileStore.save(memories, to: "memories.json") }
}
