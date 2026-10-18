import SwiftUI

/// 反思记忆：可开关、可管理
struct MemoryView: View {
    @Environment(AppModel.self) private var app
    @State private var working: String?
    @State private var result: String?
    @State private var editing: MemoryItem?
    @State private var confirmClear = false

    var body: some View {
        let s = Binding(get: { app.settings }, set: { app.settings = $0 })
        List {
            Section {
                Toggle(isOn: s.memoryEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("启用记忆")
                        Text(app.settings.memoryEnabled ? "回答时会参考记忆" : "已关闭，不会注入或生成记忆")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if app.settings.memoryEnabled {
                    Toggle(isOn: s.memoryAutoReflect) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("自动反思")
                            Text("离开对话时提炼长期信息").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("允许 AI 主动写入", isOn: s.memoryAllowAIWrite)
                    Stepper(value: s.memoryInjectLimit, in: 0...100, step: 5) {
                        Text("注入最多 \(app.settings.memoryInjectLimit) 条").font(.footnote)
                    }
                    Stepper(value: s.reflectMinNewMessages, in: 2...20, step: 2) {
                        Text("新增 \(app.settings.reflectMinNewMessages) 条消息后反思").font(.footnote)
                    }
                }
            } header: {
                Text("设置")
            } footer: {
                Text("反思使用「辅助模型」（设置中可单独指定更便宜的模型）。")
            }

            if app.settings.memoryEnabled {
                Section {
                    Button {
                        run("反思中…") {
                            let n = await app.engine.reflectRecent(limit: 5)
                            return n == 0 ? "没有发现新的可记忆信息。" : "已从 \(n) 个对话中更新记忆。"
                        }
                    } label: {
                        Label(working == "反思中…" ? "反思中…" : "反思最近对话", systemImage: "sparkles")
                    }
                    .disabled(working != nil)
                    Button {
                        run("整理中…") {
                            let log = try await app.engine.consolidateMemories()
                            return "整理完成：合并/更新 \(log.updated.count)，删除 \(log.removed.count)。"
                        }
                    } label: {
                        Label(working == "整理中…" ? "整理中…" : "AI 合并整理记忆", systemImage: "wand.and.stars")
                    }
                    .disabled(working != nil || app.memory.memories.count < 2)
                    if !app.memory.reflectingIDs.isEmpty {
                        HStack { ProgressView().controlSize(.mini).frame(width: 14); Text("后台反思中…").font(.caption2) }
                    }
                    if let result { Text(result).font(.caption2).foregroundStyle(.secondary) }
                }
            }

            Section {
                TextFieldLink(prompt: Text("例如：我是一名 iOS 开发者")) {
                    Label("手动添加记忆", systemImage: "plus.circle")
                } onSubmit: { t in
                    app.memory.add(t, category: "其他", source: .manual)
                }
                let enabledCount = app.memory.memories.filter(\.isEnabled).count
                Text("共 \(app.memory.memories.count) 条 · 启用 \(enabledCount) 条").font(.caption2).foregroundStyle(.secondary)
            }

            ForEach(app.memory.grouped, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.items) { m in
                        Button { editing = m } label: { MemoryRow(item: m) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { app.memory.delete(m.id) } label: { Image(systemName: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    app.memory.update(m.id) { $0.isEnabled.toggle() }
                                } label: { Image(systemName: m.isEnabled ? "pause.circle" : "play.circle") }
                                    .tint(m.isEnabled ? .gray : .green)
                            }
                    }
                }
            }

            Section {
                NavigationLink {
                    ReflectionLogView()
                } label: {
                    Label("反思日志（\(app.memory.logs.count)）", systemImage: "clock.arrow.circlepath")
                }
                if !app.memory.memories.isEmpty {
                    Button("清空全部记忆", role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle("反思记忆")
        .sheet(item: $editing) { m in MemoryEditSheet(item: m) }
        .confirmationDialog("清空所有记忆？此操作不可撤销。", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { app.memory.deleteAll() }
        }
    }

    private func run(_ label: String, _ op: @escaping () async throws -> String) {
        working = label
        result = nil
        Task {
            do { result = try await op() } catch { result = "⚠️ " + ChatEngine.describe(error) }
            working = nil
        }
    }
}

struct MemoryRow: View {
    let item: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.content)
                .font(.footnote)
                .foregroundStyle(item.isEnabled ? .primary : .secondary)
                .strikethrough(!item.isEnabled)
                .lineLimit(4)
            HStack(spacing: 3) {
                if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                Image(systemName: item.source.symbol)
                Text(item.source.title)
                Text("· \(Fmt.relative(item.updatedAt))")
                if !item.isEnabled { Text("· 已停用") }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}

struct MemoryEditSheet: View {
    let item: MemoryItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var category = "其他"
    @State private var enabled = true
    @State private var pinned = false

    var body: some View {
        NavigationStack {
            List {
                TextField("内容", text: $content, axis: .vertical).lineLimit(2...6)
                Picker("分类", selection: $category) {
                    ForEach(MemoryItem.categories, id: \.self) { Text($0).tag($0) }
                }
                Toggle("启用", isOn: $enabled)
                Toggle("置顶（优先注入）", isOn: $pinned)
                Button("保存") {
                    app.memory.update(item.id) {
                        $0.content = content
                        $0.category = category
                        $0.isEnabled = enabled
                        $0.isPinned = pinned
                    }
                    dismiss()
                }
                if let cid = item.conversationID, app.conversations.conversation(cid) != nil {
                    Button {
                        dismiss()
                        app.router.path.append(.chat(cid))
                    } label: {
                        Label("查看来源对话", systemImage: "bubble.left")
                    }
                }
                Section {
                    Text("来源：\(item.source.title) · 创建于 \(Fmt.dateTime(item.createdAt))").font(.caption2).foregroundStyle(.secondary)
                    Button("删除", role: .destructive) {
                        app.memory.delete(item.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑记忆")
        }
        .onAppear {
            content = item.content
            category = item.category
            enabled = item.isEnabled
            pinned = item.isPinned
        }
    }
}

struct ReflectionLogView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if app.memory.logs.isEmpty {
                Text("暂无反思记录").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(app.memory.logs) { log in
                VStack(alignment: .leading, spacing: 3) {
                    Text(log.title.isEmpty ? "反思" : log.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(Fmt.dateTime(log.date)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    if log.isEmpty {
                        Text("无变化").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(log.added, id: \.self) { Text("＋ \($0)").font(.caption2).foregroundStyle(.green) }
                    ForEach(log.updated, id: \.self) { Text("✎ \($0)").font(.caption2).foregroundStyle(.orange) }
                    ForEach(log.removed, id: \.self) { Text("－ \($0)").font(.caption2).foregroundStyle(.red) }
                }
            }
            if !app.memory.logs.isEmpty {
                Button("清空日志", role: .destructive) { app.memory.clearLogs() }
            }
        }
        .navigationTitle("反思日志")
    }
}
