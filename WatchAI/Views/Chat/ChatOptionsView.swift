import SwiftUI

/// 对话设置：模型、上下文管理、提示词、整理操作
struct ChatOptionsView: View {
    let conversationID: UUID
    let onJump: (UUID) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working: String?
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let conv = app.conversations.conversation(conversationID) {
                    content(conv)
                } else {
                    Text("对话不存在")
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }

    @ViewBuilder
    private func content(_ conv: Conversation) -> some View {
        let messages = app.conversations.messages(conversationID)
        let estimate = ContextBuilder.quickEstimate(conversation: conv, history: messages, settings: app.settings)
        let resolved = app.providers.resolve(providerID: conv.providerID, modelName: conv.modelName, settings: app.settings)
        List {
            if let message {
                Section { Text(message).font(.caption2).foregroundStyle(.secondary) }
            }

            Section("标题") {
                TextField("标题", text: Binding(
                    get: { app.conversations.conversation(conversationID)?.title ?? conv.title },
                    set: { v in app.conversations.update(conversationID) { $0.title = v; $0.titleGenerated = true } }))
                    .font(.footnote)
            }

            Section("模型") {
                NavigationLink {
                    ModelPickerView(selectedProviderID: conv.providerID, selectedModel: conv.modelName, allowDefault: true) { pid, model in
                        app.conversations.update(conversationID) { $0.providerID = pid; $0.modelName = model }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(resolved?.1.label ?? "未配置").font(.footnote)
                        Text(conv.providerID == nil ? "跟随默认 · \(resolved?.0.name ?? "")" : (resolved?.0.name ?? ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let model = resolved?.1 {
                    HStack(spacing: 6) {
                        if model.supportsVision { Label("视觉", systemImage: "eye").labelStyle(.titleAndIcon) }
                        if model.supportsTools { Label("工具", systemImage: "wrench") }
                        Text(TokenEstimator.format(model.contextWindow))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    let window = resolved?.1.contextWindow ?? 128_000
                    HStack {
                        Text("≈\(TokenEstimator.format(estimate.tokens))").font(.footnote.monospacedDigit())
                        Text("/ \(TokenEstimator.format(window))").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(estimate.messages) 条").font(.caption2).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, Double(estimate.tokens) / Double(max(window, 1))))
                        .tint(Double(estimate.tokens) / Double(max(window, 1)) > 0.8 ? .orange : .accentColor)
                }
                Stepper(value: contextLimitBinding(conv), in: 0...200, step: 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        let v = conv.contextLimit ?? app.settings.defaultContextLimit
                        Text(v == 0 ? "不限条数" : "最近 \(v) 条").font(.footnote)
                        Text(conv.contextLimit == nil ? "跟随全局" : "本对话").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if conv.contextLimit != nil {
                    Button("恢复全局条数设置") { app.conversations.update(conversationID) { $0.contextLimit = nil } }
                        .font(.caption2)
                }
                Button {
                    app.engine.insertDivider(conversationID)
                    dismiss()
                } label: {
                    Label("清除上下文（保留记录）", systemImage: "scissors")
                }
                .disabled(app.engine.isGenerating(conversationID))
                Button {
                    run("压缩中…") {
                        try await app.engine.compressContext(conversationID)
                        return "已将当前上下文压缩为摘要，后续对话将基于摘要继续。"
                    }
                } label: {
                    Label(working == "压缩中…" ? "压缩中…" : "AI 压缩上下文", systemImage: "archivebox")
                }
                .disabled(working != nil || messages.isEmpty)
                if estimate.usesSummary {
                    Button("取消压缩摘要", role: .destructive) { app.engine.clearContextSummary(conversationID) }
                        .font(.footnote)
                }
            } header: {
                Text("上下文")
            } footer: {
                Text("被排除或超出条数的消息在对话中会变暗显示。长按消息可单独排除。")
            }

            Section("行为") {
                Toggle(isOn: binding(conv, \.toolsEnabled)) {
                    Label("Agent 工具", systemImage: "wrench.and.screwdriver")
                }
                Toggle(isOn: binding(conv, \.memoryEnabled)) {
                    Label("使用记忆", systemImage: "brain.head.profile")
                }
                NavigationLink {
                    SystemPromptEditor(conversationID: conversationID)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("系统提示词").font(.footnote)
                        Text(conv.systemPrompt.isEmpty ? "未设置" : conv.systemPrompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                NavigationLink {
                    GenerationParamsView(conversationID: conversationID)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("生成参数").font(.footnote)
                        Text("温度 \(conv.temperature.map { String(format: "%.1f", $0) } ?? "默认") · 输出 \(conv.maxTokens.map(String.init) ?? "默认")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("整理") {
                Toggle(isOn: binding(conv, \.isPinned)) { Label("置顶", systemImage: "pin") }
                Toggle(isOn: binding(conv, \.isFavorite)) { Label("收藏", systemImage: "star") }
                NavigationLink {
                    FolderPickerView(conversationID: conversationID)
                } label: {
                    HStack {
                        Label("文件夹", systemImage: "folder")
                        Spacer()
                        Text(app.conversations.folder(conv.folderID).map { $0.emoji + $0.name } ?? "未分类")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    TagEditorView(conversationID: conversationID)
                } label: {
                    HStack {
                        Label("标签", systemImage: "tag")
                        Spacer()
                        Text(conv.tags.isEmpty ? "无" : conv.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button {
                    run("生成摘要…") {
                        try await app.engine.summarize(conversationID)
                        return "摘要已生成。"
                    }
                } label: {
                    Label(working == "生成摘要…" ? "生成中…" : "AI 生成对话摘要", systemImage: "text.badge.star")
                }
                .disabled(working != nil || messages.isEmpty)
                if let s = conv.summary {
                    MarkdownView(s, compact: true).font(.caption2)
                }
                Button {
                    run("重新命名…") {
                        await app.engine.generateTitle(conversationID)
                        return "标题已更新。"
                    }
                } label: {
                    Label("AI 重新命名", systemImage: "character.cursor.ibeam")
                }
                .disabled(working != nil || messages.isEmpty)
            }

            Section("记忆") {
                Button {
                    run("反思中…") {
                        let log = try await app.engine.reflect(conversationID, manual: true)
                        guard let log else { return "没有可反思的内容。" }
                        if log.isEmpty { return "本次反思没有发现值得记住的新信息。" }
                        return "反思完成：新增 \(log.added.count)，更新 \(log.updated.count)，删除 \(log.removed.count)。"
                    }
                } label: {
                    Label(working == "反思中…" ? "反思中…" : "反思此对话", systemImage: "sparkles")
                }
                .disabled(working != nil || messages.isEmpty || !app.settings.memoryEnabled)
                if !app.settings.memoryEnabled {
                    Text("记忆功能已在全局关闭").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("统计") {
                let s = app.usage.summary(conversation: conversationID)
                LabeledContent("请求", value: "\(s.requests)")
                LabeledContent("Tokens", value: "\(TokenEstimator.format(s.promptTokens)) ↑ / \(TokenEstimator.format(s.completionTokens)) ↓")
                LabeledContent("费用", value: Fmt.moneyMap(s.costByCurrency))
                LabeledContent("创建", value: Fmt.dateTime(conv.createdAt))
            }
            .font(.caption2)

            Section {
                ShareLink(item: app.conversations.exportMarkdown(conversationID)) {
                    Label("导出为 Markdown", systemImage: "square.and.arrow.up")
                }
                Button {
                    app.conversations.update(conversationID) { $0.isArchived.toggle() }
                    dismiss()
                } label: {
                    Label(conv.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("删除对话", systemImage: "trash")
                }
            }
        }
        .navigationTitle("对话设置")
        .confirmationDialog("删除整个对话？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                app.engine.stop(conversationID)
                dismiss()
                app.router.path.removeAll { $0 == .chat(conversationID) }
                app.conversations.delete(conversationID)
            }
        }
    }

    private func binding<T>(_ conv: Conversation, _ key: WritableKeyPath<Conversation, T>) -> Binding<T> {
        Binding(
            get: { app.conversations.conversation(conversationID)?[keyPath: key] ?? conv[keyPath: key] },
            set: { v in app.conversations.update(conversationID) { $0[keyPath: key] = v } }
        )
    }

    private func contextLimitBinding(_ conv: Conversation) -> Binding<Int> {
        Binding(
            get: { app.conversations.conversation(conversationID)?.contextLimit ?? app.settings.defaultContextLimit },
            set: { v in app.conversations.update(conversationID) { $0.contextLimit = v } }
        )
    }

    private func run(_ label: String, _ op: @escaping () async throws -> String) {
        working = label
        message = nil
        Task {
            do {
                message = try await op()
            } catch {
                message = "⚠️ " + ChatEngine.describe(error)
            }
            working = nil
        }
    }
}

struct SystemPromptEditor: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        let binding = Binding(
            get: { app.conversations.conversation(conversationID)?.systemPrompt ?? "" },
            set: { v in app.conversations.update(conversationID) { $0.systemPrompt = v } })
        List {
            Section {
                TextField("例如：你是一名英语老师", text: binding, axis: .vertical)
                    .lineLimit(2...10)
                    .font(.footnote)
            } footer: {
                Text("仅作用于本对话，会与全局提示词叠加。")
            }
            Section("从助手模板套用") {
                ForEach(app.settingsStore.personas.filter { !$0.systemPrompt.isEmpty }) { p in
                    Button("\(p.emoji) \(p.name)") { binding.wrappedValue = p.systemPrompt }
                }
                Button("清空", role: .destructive) { binding.wrappedValue = "" }
            }
        }
        .navigationTitle("系统提示词")
    }
}

struct GenerationParamsView: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        let conv = app.conversations.conversation(conversationID)
        List {
            Section {
                Toggle("自定义温度", isOn: Binding(
                    get: { conv?.temperature != nil },
                    set: { on in app.conversations.update(conversationID) { $0.temperature = on ? 1.0 : nil } }))
                if let t = conv?.temperature {
                    Stepper(value: Binding(get: { t }, set: { v in app.conversations.update(conversationID) { $0.temperature = (v * 10).rounded() / 10 } }),
                            in: 0...2, step: 0.1) {
                        Text(String(format: "温度 %.1f", t)).font(.footnote)
                    }
                }
            } footer: {
                Text("MiniMax 推荐 1.0；越低越稳定，越高越有创意。")
            }
            Section {
                Toggle("限制输出长度", isOn: Binding(
                    get: { conv?.maxTokens != nil },
                    set: { on in app.conversations.update(conversationID) { $0.maxTokens = on ? 2048 : nil } }))
                if let m = conv?.maxTokens {
                    Stepper(value: Binding(get: { m }, set: { v in app.conversations.update(conversationID) { $0.maxTokens = v } }),
                            in: 256...32768, step: 512) {
                        Text("\(m) tokens").font(.footnote)
                    }
                }
            } footer: {
                Text("思考模型的 max_tokens 包含思考内容，过小会导致回答被截断。")
            }
        }
        .navigationTitle("生成参数")
    }
}

struct FolderPickerView: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = app.conversations.conversation(conversationID)?.folderID
        List {
            Button {
                app.conversations.update(conversationID) { $0.folderID = nil }
                dismiss()
            } label: {
                HStack { Text("未分类"); Spacer(); if current == nil { Image(systemName: "checkmark") } }
            }
            ForEach(app.conversations.folders) { f in
                Button {
                    app.conversations.update(conversationID) { $0.folderID = f.id }
                    dismiss()
                } label: {
                    HStack { Text("\(f.emoji) \(f.name)"); Spacer(); if current == f.id { Image(systemName: "checkmark") } }
                }
            }
            TextFieldLink(prompt: Text("文件夹名称")) {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            } onSubmit: { name in
                let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                let f = app.conversations.addFolder(name: t)
                app.conversations.update(conversationID) { $0.folderID = f.id }
            }
        }
        .navigationTitle("移动到")
    }
}

struct TagEditorView: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        let tags = app.conversations.conversation(conversationID)?.tags ?? []
        let others = app.conversations.allTags.filter { !tags.contains($0) }
        List {
            Section("当前标签") {
                if tags.isEmpty { Text("无").foregroundStyle(.secondary) }
                ForEach(tags, id: \.self) { t in
                    Text("#\(t)")
                        .swipeActions {
                            Button(role: .destructive) {
                                app.conversations.update(conversationID) { $0.tags.removeAll { $0 == t } }
                            } label: { Image(systemName: "trash") }
                        }
                }
                TextFieldLink(prompt: Text("标签")) {
                    Label("添加标签", systemImage: "plus")
                } onSubmit: { t in
                    let v = t.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                    guard !v.isEmpty else { return }
                    app.conversations.update(conversationID) { if !$0.tags.contains(v) { $0.tags.append(v) } }
                }
            }
            if !others.isEmpty {
                Section("已有标签") {
                    ForEach(others, id: \.self) { t in
                        Button("#\(t)") { app.conversations.update(conversationID) { $0.tags.append(t) } }
                    }
                }
            }
        }
        .navigationTitle("标签")
    }
}

/// 选择服务商与模型
struct ModelPickerView: View {
    let selectedProviderID: UUID?
    let selectedModel: String?
    var allowDefault: Bool = false
    let onPick: (UUID?, String?) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if allowDefault {
                Button {
                    onPick(nil, nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("跟随默认模型")
                        Spacer()
                        if selectedProviderID == nil { Image(systemName: "checkmark") }
                    }
                }
            }
            ForEach(app.providers.enabled) { p in
                Section(p.name) {
                    ForEach(p.models) { m in
                        Button {
                            onPick(p.id, m.name)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.label).font(.footnote)
                                    HStack(spacing: 4) {
                                        if m.supportsVision { Image(systemName: "eye") }
                                        if m.supportsTools { Image(systemName: "wrench") }
                                        if m.hasPricing {
                                            Text("\(Fmt.money(m.inputPrice, p.currency))/\(Fmt.money(m.outputPrice, p.currency))")
                                        }
                                    }
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedProviderID == p.id && selectedModel == m.name { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if p.models.isEmpty {
                        Text("尚未添加模型").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if app.providers.enabled.isEmpty {
                NavigationLink(value: Route.providers) { Label("添加服务商", systemImage: "plus") }
            }
        }
        .navigationTitle("选择模型")
    }
}
