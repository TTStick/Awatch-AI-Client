import SwiftUI
import WatchKit

struct ToolboxView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.memos) {
                    toolRow("备忘录", "note.text", .yellow, "\(app.agent.memos.count) 条")
                }
                NavigationLink(value: Route.todos) {
                    toolRow("待办", "checklist", .green, "\(app.agent.pendingTodos.count) 项未完成")
                }
                NavigationLink(value: Route.timers) {
                    toolRow("倒计时", "timer", .orange, app.agent.activeTimers.isEmpty ? "无进行中" : "\(app.agent.activeTimers.count) 个进行中")
                }
            } footer: {
                Text("在对话里直接说“记一下…”“提醒我…”“10 分钟后叫我”，AI 会自动调用这些工具。")
            }
            Section("AI 工具开关") {
                let s = Binding(get: { app.settings }, set: { app.settings = $0 })
                Toggle("启用 Agent", isOn: s.agentEnabled)
                if app.settings.agentEnabled {
                    Toggle("备忘录", isOn: s.toolMemo)
                    Toggle("待办", isOn: s.toolTodo)
                    Toggle("倒计时", isOn: s.toolTimer)
                    Toggle("读取网页", isOn: s.toolWeb)
                    Toggle("检索历史对话", isOn: s.toolSearch)
                    Stepper(value: s.maxToolRounds, in: 1...12) {
                        Text("最多 \(app.settings.maxToolRounds) 轮工具调用").font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("工具箱")
    }

    private func toolRow(_ title: String, _ icon: String, _ color: Color, _ sub: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 备忘录

struct MemoListView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        let memos = app.agent.sortedMemos.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.content.localizedCaseInsensitiveContains(query)
        }
        List {
            TextFieldLink(prompt: Text("说出或写下备忘内容")) {
                Label("新建备忘", systemImage: "square.and.pencil").foregroundStyle(.yellow)
            } onSubmit: { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                app.agent.addMemo(title: "", content: t)
            }
            if memos.isEmpty {
                Text("还没有备忘").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(memos) { m in
                NavigationLink(value: Route.memo(m.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            if m.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                            if m.createdByAI { Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.purple) }
                            Text(m.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        }
                        Text(ConversationStore.plainSnippet(m.content, limit: 60)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        Text(Fmt.relative(m.updatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { app.agent.deleteMemo(m.id) } label: { Image(systemName: "trash") }
                    Button { app.agent.updateMemo(m.id) { $0.isPinned.toggle() } } label: { Image(systemName: "pin") }.tint(.orange)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("备忘录")
    }
}

struct MemoDetailView: View {
    let memoID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        if let memo = app.agent.memos.first(where: { $0.id == memoID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(memo.title).font(.headline)
                    MarkdownView(memo.content)
                    Text("更新于 \(Fmt.dateTime(memo.updatedAt))\(memo.createdByAI ? " · AI 创建" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    TextFieldLink(prompt: Text("追加内容")) {
                        Label("追加一行", systemImage: "text.append")
                    } onSubmit: { t in
                        guard !t.isEmpty else { return }
                        app.agent.updateMemo(memoID) { $0.content += ($0.content.isEmpty ? "" : "\n") + t }
                    }
                    Button {
                        let c = app.conversations.create()
                        app.engine.send("这是我的一条备忘，请帮我整理和补充：\n\n# \(memo.title)\n\(memo.content)", to: c.id)
                        app.router.path.append(.chat(c.id))
                    } label: {
                        Label("交给 AI 处理", systemImage: "sparkles")
                    }
                    Button { app.agent.updateMemo(memoID) { $0.isPinned.toggle() } } label: {
                        Label(memo.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                    }
                    ShareLink(item: "\(memo.title)\n\n\(memo.content)") { Label("分享", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                }
            }
            .navigationTitle("备忘")
            .modifier(InlineWebLinks())
            .sheet(isPresented: $editing) { MemoEditSheet(memo: memo) }
            .confirmationDialog("删除备忘？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    app.agent.deleteMemo(memoID)
                    dismiss()
                }
            }
        } else {
            Text("备忘已删除").foregroundStyle(.secondary)
        }
    }
}

struct MemoEditSheet: View {
    let memo: Memo
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""

    var body: some View {
        List {
            TextField("标题", text: $title)
            TextField("内容", text: $content, axis: .vertical).lineLimit(3...12)
            Button("保存") {
                app.agent.updateMemo(memo.id) { $0.title = title; $0.content = content }
                dismiss()
            }
        }
        .onAppear { title = memo.title; content = memo.content }
    }
}

// MARK: - 待办

struct TodoListView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: TodoItem?
    @State private var showDone = false

    var body: some View {
        List {
            TextFieldLink(prompt: Text("待办内容")) {
                Label("新增待办", systemImage: "plus.circle.fill").foregroundStyle(.green)
            } onSubmit: { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                app.agent.addTodo(title: t)
            }
            let pending = app.agent.pendingTodos
            Section("待完成 · \(pending.count)") {
                if pending.isEmpty { Text("全部完成 🎉").font(.caption2).foregroundStyle(.secondary) }
                ForEach(pending) { t in todoRow(t) }
            }
            let done = app.agent.doneTodos
            if !done.isEmpty {
                Section {
                    Button(showDone ? "隐藏已完成" : "显示已完成（\(done.count)）") { withAnimation { showDone.toggle() } }
                        .font(.footnote)
                    if showDone {
                        ForEach(done) { t in todoRow(t) }
                        Button("清除已完成", role: .destructive) { app.agent.clearCompletedTodos() }.font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("待办")
        .sheet(item: $editing) { t in TodoEditSheet(todo: t) }
    }

    private func todoRow(_ t: TodoItem) -> some View {
        HStack(spacing: 8) {
            Button {
                app.agent.toggleTodo(t.id)
                WKHaptic.click()
            } label: {
                Image(systemName: t.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(t.isDone ? .green : (t.isHighPriority ? .red : .secondary))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title)
                    .font(.footnote)
                    .strikethrough(t.isDone)
                    .foregroundStyle(t.isDone ? .secondary : .primary)
                    .lineLimit(3)
                HStack(spacing: 3) {
                    if t.isHighPriority { Image(systemName: "exclamationmark").foregroundStyle(.red) }
                    if let due = t.dueDate {
                        Image(systemName: "bell")
                        Text(Fmt.dateTime(due))
                    }
                    if t.createdByAI { Image(systemName: "sparkles").foregroundStyle(.purple) }
                }
                .font(.system(size: 9))
                .foregroundStyle(t.isOverdue ? .red : .secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = t }
        .swipeActions {
            Button(role: .destructive) { app.agent.deleteTodo(t.id) } label: { Image(systemName: "trash") }
        }
    }
}

enum WKHaptic {
    static func click() { WKInterfaceDevice.current().play(.click) }
}

struct TodoEditSheet: View {
    let todo: TodoItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var high = false
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        List {
            TextField("内容", text: $title, axis: .vertical).lineLimit(1...4)
            TextField("备注", text: $notes, axis: .vertical).lineLimit(1...4)
            Toggle("重要", isOn: $high)
            Toggle("提醒", isOn: $hasDue)
            if hasDue {
                DatePicker("日期", selection: $due, displayedComponents: [.date])
                DatePicker("时间", selection: $due, displayedComponents: [.hourAndMinute])
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        quick("1小时后") { due = Date().addingTimeInterval(3600) }
                        quick("今晚") { due = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date() }
                        quick("明早") {
                            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                            due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                        }
                    }
                }
            }
            Button("保存") {
                app.agent.updateTodo(todo.id) {
                    $0.title = title.isEmpty ? todo.title : title
                    $0.notes = notes
                    $0.isHighPriority = high
                    $0.dueDate = hasDue ? due : nil
                }
                dismiss()
            }
            Button(todo.isDone ? "标记为未完成" : "标记为完成") {
                app.agent.toggleTodo(todo.id)
                dismiss()
            }
        }
        .onAppear {
            title = todo.title
            notes = todo.notes
            high = todo.isHighPriority
            hasDue = todo.dueDate != nil
            due = todo.dueDate ?? Date().addingTimeInterval(3600)
        }
    }

    private func quick(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(t, action: action).font(.caption2).buttonStyle(.bordered).controlSize(.small)
    }
}

// MARK: - 倒计时

struct TimerListView: View {
    @Environment(AppModel.self) private var app
    @State private var customMinutes = 5
    @State private var customSeconds = 0
    @State private var label = ""
    private let presets: [(String, Double)] = [("1分", 60), ("3分", 180), ("5分", 300), ("10分", 600), ("15分", 900), ("25分", 1500), ("30分", 1800), ("1时", 3600)]

    var body: some View {
        List {
            let active = app.agent.activeTimers
            if !active.isEmpty {
                Section("进行中") {
                    ForEach(active) { t in TimerCard(timer: t) }
                }
            }
            Section("快速开始") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(presets, id: \.0) { p in
                        Button {
                            app.agent.startTimer(seconds: p.1, label: label)
                            label = ""
                            WKHaptic.click()
                        } label: {
                            Text(p.0).font(.caption2.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.clear)
                TextField("名称（可选）", text: $label).font(.footnote)
            }
            Section("自定义") {
                HStack {
                    Picker("分", selection: $customMinutes) {
                        ForEach(0..<181) { Text("\($0)分").tag($0) }
                    }
                    Picker("秒", selection: $customSeconds) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0)秒").tag($0) }
                    }
                }
                .frame(height: 60)
                Button {
                    let secs = Double(customMinutes * 60 + customSeconds)
                    guard secs > 0 else { return }
                    app.agent.startTimer(seconds: secs, label: label)
                    label = ""
                } label: {
                    Label("开始", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .tint(.orange)
            }
            let finished = app.agent.recentFinishedTimers
            if !finished.isEmpty {
                Section("已结束") {
                    ForEach(finished.prefix(8)) { t in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.label).font(.footnote).lineLimit(1)
                                Text(AgentStore.formatDuration(t.duration)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { app.agent.restartTimer(t.id) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).foregroundStyle(.orange)
                        }
                    }
                    Button("清除记录", role: .destructive) { app.agent.clearFinishedTimers() }.font(.footnote)
                }
            }
        }
        .navigationTitle("倒计时")
    }
}

struct TimerCard: View {
    let timer: CountdownTimer
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(timer.label).font(.footnote.weight(.semibold)).lineLimit(1)
                if timer.createdByAI { Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.purple) }
                Spacer()
            }
            if timer.state == .running, let end = timer.endDate {
                Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
                ProgressView(timerInterval: end.addingTimeInterval(-timer.duration)...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(.orange)
            } else {
                Text(AgentStore.clock(timer.remaining()))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if timer.state == .running {
                    Button { app.agent.pauseTimer(timer.id) } label: { Image(systemName: "pause.fill") }
                } else {
                    Button { app.agent.resumeTimer(timer.id) } label: { Image(systemName: "play.fill") }
                }
                Button { app.agent.addTime(timer.id, seconds: 60) } label: { Text("+1分").font(.caption2) }
                Button(role: .destructive) { app.agent.cancelTimer(timer.id) } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
