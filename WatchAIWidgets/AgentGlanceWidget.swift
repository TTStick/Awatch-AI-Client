import SwiftUI
import WidgetKit

// MARK: - 数据

/// App 写入 App Group 的计时器与待办
struct AgentSnapshot {
    var timers: [CountdownTimer] = []
    var todos: [TodoItem] = []

    static func load() -> AgentSnapshot {
        guard let root = AppGroup.sharedStoreRoot else { return AgentSnapshot() }
        return AgentSnapshot(timers: read([CountdownTimer].self, root.appendingPathComponent("timers.json")) ?? [],
                             todos: read([TodoItem].self, root.appendingPathComponent("todos.json")) ?? [])
    }

    private static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct GlanceEntry: TimelineEntry {
    enum Content {
        case running(CountdownTimer, end: Date)
        case paused(CountdownTimer)
        case todo(TodoItem)
        case empty
    }

    let date: Date
    let content: Content
    /// 展示项之外还在进行的计时器
    let otherTimers: Int
    let pendingTodos: Int

    /// 优先级：最先结束的计时 → 下一项待办 → 暂停的计时 → 空
    init(date: Date, snapshot: AgentSnapshot) {
        self.date = date
        let running = snapshot.timers
            .compactMap { t -> (CountdownTimer, Date)? in
                guard t.state == .running, let end = t.endDate, end > date else { return nil }
                return (t, end)
            }
            .sorted { $0.1 < $1.1 }
        let paused = snapshot.timers.filter { $0.state == .paused }
        let pending = snapshot.todos.filter { !$0.isDone }.sorted(by: TodoItem.pendingOrder)
        pendingTodos = pending.count
        if let nearest = running.first {
            content = .running(nearest.0, end: nearest.1)
            otherTimers = running.count - 1 + paused.count
        } else if let todo = pending.first {
            content = .todo(todo)
            otherTimers = paused.count
        } else if let t = paused.first {
            content = .paused(t)
            otherTimers = paused.count - 1
        } else {
            content = .empty
            otherTimers = 0
        }
    }

    var isEmpty: Bool {
        if case .empty = content { return true }
        return false
    }

    var url: URL {
        switch content {
        case .running, .paused: return WidgetLink.timers
        case .todo: return WidgetLink.todos
        case .empty: return WidgetLink.new
        }
    }

    /// 智能叠放：计时进行中或待办临近时排在前面
    var relevance: TimelineEntryRelevance? {
        switch content {
        case .running(_, let end):
            return TimelineEntryRelevance(score: 100, duration: end.timeIntervalSince(date))
        case .todo(let todo):
            guard let due = todo.dueDate, due.timeIntervalSince(date) < 2 * 3600 else { return nil }
            return TimelineEntryRelevance(score: 50, duration: max(0, due.timeIntervalSince(date)) + 1800)
        case .paused, .empty:
            return nil
        }
    }

    /// 小组件库中没有真实数据时的示例
    static var preview: GlanceEntry {
        let now = Date()
        var timer = CountdownTimer(label: "番茄钟", duration: 25 * 60)
        timer.endDate = now.addingTimeInterval(18 * 60 + 42)
        return GlanceEntry(date: now, snapshot: AgentSnapshot(timers: [timer], todos: [TodoItem(title: "给妈妈打电话")]))
    }
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let entry = GlanceEntry(date: Date(), snapshot: .load())
        completion(context.isPreview && entry.isEmpty ? .preview : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let snapshot = AgentSnapshot.load()
        let now = Date()
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        // 计时结束、待办到期（变为逾期）和跨天（「今天/明天」）时内容会变化；App 改动数据时会主动刷新
        let changes = snapshot.timers.compactMap { $0.state == .running ? $0.endDate : nil }
            + snapshot.todos.compactMap { $0.isDone ? nil : $0.dueDate }
        let dates = [now] + Set(changes.filter { $0 > now && $0 < midnight }).sorted().prefix(30) + [midnight]
        let entries = dates.map { GlanceEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// 最近的倒计时或下一项待办
struct AgentGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchAIAgentGlance", provider: GlanceProvider()) { entry in
            GlanceView(entry: entry)
        }
        .configurationDisplayName("计时与待办")
        .description("显示最先结束的倒计时，没有计时时显示下一项待办。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

// MARK: - 视图

struct GlanceView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(entry.url)
            .containerBackground(tint.opacity(0.3), for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: inline
        default: rectangular
        }
    }

    private var tint: Color {
        switch entry.content {
        case .running, .paused: return .orange
        case .todo: return .blue
        case .empty: return .accentColor
        }
    }

    // MARK: 矩形

    @ViewBuilder
    private var rectangular: some View {
        switch entry.content {
        case .running(let t, let end):
            VStack(alignment: .leading, spacing: 1) {
                timerHeader(t, symbol: "timer")
                Text(timerInterval: entry.date...end, countsDown: true)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
                    .widgetAccentable()
                ProgressView(timerInterval: Self.start(t, end: end)...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .paused(let t):
            VStack(alignment: .leading, spacing: 1) {
                timerHeader(t, symbol: "pause.circle")
                pausedText(t)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: t.remaining(), total: max(t.duration, t.remaining()))
                    .tint(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .todo(let todo):
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.blue)
                        .widgetAccentable()
                    Text("待办 \(entry.pendingTodos)")
                    Spacer(minLength: 0)
                    if todo.isHighPriority {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
                .font(.caption.weight(.semibold))
                Text(todo.title)
                    .font(.headline)
                    .lineLimit(2)
                if let due = todo.dueDate {
                    Label(Self.dueText(due, now: entry.date), systemImage: "bell")
                        .font(.caption2)
                        .foregroundStyle(due < entry.date ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            VStack(alignment: .leading, spacing: 2) {
                Label("Watch AI", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .widgetAccentable()
                Text("没有进行中的计时或待办")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("轻点开始提问")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timerHeader(_ t: CountdownTimer, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .widgetAccentable()
            Text(t.label).lineLimit(1)
            Spacer(minLength: 0)
            if entry.otherTimers > 0 {
                Text("+\(entry.otherTimers)").foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
    }

    // MARK: 圆形

    @ViewBuilder
    private var circular: some View {
        switch entry.content {
        case .running(let t, let end):
            ZStack {
                AccessoryWidgetBackground()
                ProgressView(timerInterval: Self.start(t, end: end)...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(.orange)
                .widgetAccentable()
                Text(timerInterval: entry.date...end, countsDown: true)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
        case .paused(let t):
            ZStack {
                AccessoryWidgetBackground()
                ProgressView(value: t.remaining(), total: max(t.duration, t.remaining()))
                    .progressViewStyle(.circular)
                    .tint(.secondary)
                VStack(spacing: 0) {
                    Image(systemName: "pause.fill").font(.system(size: 9))
                    pausedText(t)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 6)
            }
        case .todo:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .widgetAccentable()
                    Text("\(entry.pendingTodos)")
                        .font(.system(.headline, design: .rounded))
                }
            }
        case .empty:
            QuickAskBadge()
        }
    }

    // MARK: 角落

    @ViewBuilder
    private var corner: some View {
        switch entry.content {
        case .running(_, let end):
            cornerIcon("timer", color: .orange)
                .widgetLabel {
                    Text(timerInterval: entry.date...end, countsDown: true)
                }
        case .paused(let t):
            cornerIcon("pause.circle", color: .orange)
                .widgetLabel {
                    pausedText(t)
                }
        case .todo(let todo):
            cornerIcon("checklist", color: .blue)
                .widgetLabel(todo.title)
        case .empty:
            cornerIcon("sparkles", color: .accentColor)
                .widgetLabel("问 AI")
        }
    }

    private func cornerIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(color)
            .widgetAccentable()
    }

    // MARK: 行内

    @ViewBuilder
    private var inline: some View {
        switch entry.content {
        case .running(let t, let end):
            Label {
                Text(t.label + " ") + Text(timerInterval: entry.date...end, countsDown: true)
            } icon: {
                Image(systemName: "timer")
            }
        case .paused(let t):
            Label {
                Text(t.label + " ") + pausedText(t)
            } icon: {
                Image(systemName: "pause.circle")
            }
        case .todo(let todo):
            Label(todo.title, systemImage: "checklist")
        case .empty:
            Label("问 AI", systemImage: "sparkles")
        }
    }

    // MARK: 工具

    /// 暂停中的剩余时间（静止显示，格式与进行中的计时一致）
    private func pausedText(_ t: CountdownTimer) -> Text {
        Text(timerInterval: entry.date...entry.date.addingTimeInterval(t.remaining()), pauseTime: entry.date, countsDown: true)
    }

    /// 进度条起点：剩余 / 总时长
    private static func start(_ t: CountdownTimer, end: Date) -> Date {
        end.addingTimeInterval(-max(t.duration, 1))
    }

    private static func dueText(_ due: Date, now: Date) -> String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        if cal.isDate(due, inSameDayAs: now) {
            df.dateFormat = "今天 HH:mm"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(due, inSameDayAs: tomorrow) {
            df.dateFormat = "明天 HH:mm"
        } else {
            df.dateFormat = "M月d日 HH:mm"
        }
        return (due < now ? "已逾期 · " : "") + df.string(from: due)
    }
}

#if DEBUG
#Preview("计时", as: .accessoryRectangular) {
    AgentGlanceWidget()
} timeline: {
    GlanceEntry.preview
}

#Preview("问 AI", as: .accessoryCircular) {
    QuickAskWidget()
} timeline: {
    QuickAskEntry(date: Date())
}
#endif
