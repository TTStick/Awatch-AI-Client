import Foundation

struct Memo: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPinned: Bool = false
    var createdByAI: Bool = false
}

struct TodoItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var notes: String = ""
    var isDone: Bool = false
    var isHighPriority: Bool = false
    var dueDate: Date?
    var createdAt: Date = Date()
    var completedAt: Date?
    var createdByAI: Bool = false

    var isOverdue: Bool {
        guard let dueDate, !isDone else { return false }
        return dueDate < Date()
    }

    /// 未完成待办的排序：高优先级 → 有截止时间（早的在前）→ 新建的在前（App 列表与小组件共用）
    static func pendingOrder(_ a: TodoItem, _ b: TodoItem) -> Bool {
        if a.isHighPriority != b.isHighPriority { return a.isHighPriority }
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.createdAt > b.createdAt
        }
    }
}

enum TimerState: String, Codable {
    case running, paused, finished, cancelled
}

struct CountdownTimer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String
    var duration: TimeInterval
    var endDate: Date?
    var remainingWhenPaused: TimeInterval?
    var state: TimerState = .running
    var createdAt: Date = Date()
    var finishedAt: Date?
    var createdByAI: Bool = false

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch state {
        case .running: return max(0, (endDate ?? date).timeIntervalSince(date))
        case .paused: return remainingWhenPaused ?? duration
        case .finished, .cancelled: return 0
        }
    }

    var isActive: Bool { state == .running || state == .paused }
}

enum MemorySource: String, Codable {
    case reflection, tool, manual

    var title: String {
        switch self {
        case .reflection: return "反思"
        case .tool: return "AI 写入"
        case .manual: return "手动"
        }
    }

    var symbol: String {
        switch self {
        case .reflection: return "sparkles"
        case .tool: return "wand.and.stars"
        case .manual: return "hand.point.up.left"
        }
    }
}

struct MemoryItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var content: String
    var category: String = "其他"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var source: MemorySource = .manual
    var conversationID: UUID?
    var isEnabled: Bool = true
    var isPinned: Bool = false

    static let categories = ["背景", "偏好", "习惯", "目标", "项目", "关系", "其他"]
}

struct ReflectionLog: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var conversationID: UUID?
    var title: String
    var added: [String] = []
    var updated: [String] = []
    var removed: [String] = []
    var note: String?

    var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}

/// 短 ID：便于模型引用
extension UUID {
    var short: String { String(uuidString.prefix(8)).lowercased() }
}

extension Array where Element: Identifiable, Element.ID == UUID {
    func index(matchingShort key: String) -> Int? {
        let k = key.lowercased().trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return nil }
        return firstIndex(where: { $0.id.uuidString.lowercased().hasPrefix(k) })
    }
}
