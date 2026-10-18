import Foundation
import Observation
import UserNotifications
import WatchKit

enum Notifier {
    static func requestAuthorization() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-WAINoNotif") { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(id: String, title: String, body: String, at date: Date, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    static func notifyNow(id: String = UUID().uuidString, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

@MainActor
@Observable
final class AgentStore {
    private(set) var memos: [Memo] = []
    private(set) var todos: [TodoItem] = []
    private(set) var timers: [CountdownTimer] = []
    /// 刚刚结束的计时器（用于前台提示）
    var finishedTimer: CountdownTimer?

    @ObservationIgnored private var watcher: Task<Void, Never>?

    init() {
        memos = FileStore.load([Memo].self, from: "memos.json") ?? []
        todos = FileStore.load([TodoItem].self, from: "todos.json") ?? []
        timers = FileStore.load([CountdownTimer].self, from: "timers.json") ?? []
        checkTimers(silent: true)
        restartWatcher()
        // 首次启动可能刚完成数据迁移，让小组件重新读取
        WidgetRefresher.reload()
    }

    // MARK: - 备忘录

    var sortedMemos: [Memo] {
        memos.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    @discardableResult
    func addMemo(title: String, content: String, byAI: Bool = false) -> Memo {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            t = String(content.split(separator: "\n").first ?? "备忘").prefix(20).description
        }
        let m = Memo(title: t, content: content, createdByAI: byAI)
        memos.insert(m, at: 0)
        saveMemos()
        return m
    }

    func updateMemo(_ id: UUID, _ mutate: (inout Memo) -> Void) {
        guard let i = memos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&memos[i])
        memos[i].updatedAt = Date()
        saveMemos()
    }

    func deleteMemo(_ id: UUID) {
        memos.removeAll { $0.id == id }
        saveMemos()
    }

    private func saveMemos() { FileStore.save(memos, to: "memos.json") }

    // MARK: - 待办

    var pendingTodos: [TodoItem] {
        todos.filter { !$0.isDone }.sorted(by: TodoItem.pendingOrder)
    }

    var doneTodos: [TodoItem] {
        todos.filter { $0.isDone }.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    @discardableResult
    func addTodo(title: String, notes: String = "", due: Date? = nil, highPriority: Bool = false, byAI: Bool = false) -> TodoItem {
        let t = TodoItem(title: title, notes: notes, isHighPriority: highPriority, dueDate: due, createdByAI: byAI)
        todos.insert(t, at: 0)
        scheduleTodoReminder(t)
        saveTodos()
        return t
    }

    func updateTodo(_ id: UUID, _ mutate: (inout TodoItem) -> Void) {
        guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&todos[i])
        if todos[i].isDone && todos[i].completedAt == nil { todos[i].completedAt = Date() }
        if !todos[i].isDone { todos[i].completedAt = nil }
        scheduleTodoReminder(todos[i])
        saveTodos()
    }

    func toggleTodo(_ id: UUID) {
        updateTodo(id) { $0.isDone.toggle() }
    }

    func deleteTodo(_ id: UUID) {
        Notifier.cancel(id: "todo-\(id.uuidString)")
        todos.removeAll { $0.id == id }
        saveTodos()
    }

    func clearCompletedTodos() {
        todos.removeAll { $0.isDone }
        saveTodos()
    }

    private func scheduleTodoReminder(_ t: TodoItem) {
        let nid = "todo-\(t.id.uuidString)"
        Notifier.cancel(id: nid)
        if let due = t.dueDate, !t.isDone, due > Date() {
            Notifier.requestAuthorization()
            Notifier.schedule(id: nid, title: "待办提醒", body: t.title, at: due)
        }
    }

    private func saveTodos() {
        FileStore.save(todos, to: "todos.json")
        WidgetRefresher.reload()
    }

    // MARK: - 倒计时

    var activeTimers: [CountdownTimer] {
        timers.filter { $0.isActive }.sorted { $0.remaining() < $1.remaining() }
    }

    var recentFinishedTimers: [CountdownTimer] {
        timers.filter { $0.state == .finished }.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    @discardableResult
    func startTimer(seconds: TimeInterval, label: String, byAI: Bool = false) -> CountdownTimer {
        let secs = max(1, seconds)
        var t = CountdownTimer(label: label.isEmpty ? Self.formatDuration(secs) : label, duration: secs, createdByAI: byAI)
        t.endDate = Date().addingTimeInterval(secs)
        timers.insert(t, at: 0)
        Notifier.requestAuthorization()
        scheduleTimerNotification(t)
        saveTimers()
        restartWatcher()
        return t
    }

    func pauseTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }), timers[i].state == .running else { return }
        timers[i].remainingWhenPaused = timers[i].remaining()
        timers[i].state = .paused
        timers[i].endDate = nil
        Notifier.cancel(id: "timer-\(id.uuidString)")
        saveTimers()
        restartWatcher()
    }

    func resumeTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }), timers[i].state == .paused else { return }
        let remain = timers[i].remainingWhenPaused ?? timers[i].duration
        timers[i].endDate = Date().addingTimeInterval(remain)
        timers[i].remainingWhenPaused = nil
        timers[i].state = .running
        scheduleTimerNotification(timers[i])
        saveTimers()
        restartWatcher()
    }

    func cancelTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].state = .cancelled
        Notifier.cancel(id: "timer-\(id.uuidString)")
        timers.remove(at: i)
        saveTimers()
        restartWatcher()
    }

    func addTime(_ id: UUID, seconds: TimeInterval) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        switch timers[i].state {
        case .running:
            timers[i].endDate = (timers[i].endDate ?? Date()).addingTimeInterval(seconds)
            timers[i].duration += seconds
            scheduleTimerNotification(timers[i])
        case .paused:
            timers[i].remainingWhenPaused = (timers[i].remainingWhenPaused ?? 0) + seconds
            timers[i].duration += seconds
        default: return
        }
        saveTimers()
        restartWatcher()
    }

    func restartTimer(_ id: UUID) {
        guard let t = timers.first(where: { $0.id == id }) else { return }
        timers.removeAll { $0.id == id }
        startTimer(seconds: t.duration, label: t.label, byAI: t.createdByAI)
    }

    func clearFinishedTimers() {
        timers.removeAll { $0.state == .finished || $0.state == .cancelled }
        saveTimers()
    }

    private func scheduleTimerNotification(_ t: CountdownTimer) {
        let nid = "timer-\(t.id.uuidString)"
        Notifier.cancel(id: nid)
        guard t.state == .running, let end = t.endDate else { return }
        Notifier.schedule(id: nid, title: "⏰ 倒计时结束", body: t.label, at: end)
    }

    private func saveTimers() {
        FileStore.save(timers, to: "timers.json")
        WidgetRefresher.reload()
    }

    func checkTimers(silent: Bool = false) {
        let now = Date()
        var changed = false
        for i in timers.indices where timers[i].state == .running {
            if let end = timers[i].endDate, end <= now {
                timers[i].state = .finished
                timers[i].finishedAt = end
                changed = true
                if !silent {
                    finishedTimer = timers[i]
                    WKInterfaceDevice.current().play(.notification)
                }
            }
        }
        // 只保留最近 20 个已结束计时
        let finished = recentFinishedTimers
        if finished.count > 20 {
            let drop = Set(finished.dropFirst(20).map(\.id))
            timers.removeAll { drop.contains($0.id) }
            changed = true
        }
        if changed { saveTimers() }
    }

    private func restartWatcher() {
        watcher?.cancel()
        let next = timers.filter { $0.state == .running }.compactMap(\.endDate).min()
        guard let next else { return }
        watcher = Task { [weak self] in
            let delay = max(0.05, next.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.checkTimers()
            self.restartWatcher()
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return m > 0 ? "\(h)小时\(m)分钟" : "\(h)小时" }
        if m > 0 { return sec > 0 ? "\(m)分\(sec)秒" : "\(m)分钟" }
        return "\(sec)秒"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
