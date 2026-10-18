import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDeleteAll = false
    @State private var confirmReset = false
    @State private var storage: String = "计算中…"

    var body: some View {
        let s = Binding(get: { app.settings }, set: { app.settings = $0 })
        List {
            Section("回答") {
                Toggle(isOn: s.conciseMode) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("小屏简洁模式")
                        Text("要求 AI 先给结论、控制篇幅").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Toggle("流式输出", isOn: s.streamEnabled)
                NavigationLink {
                    GlobalPromptView()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("全局系统提示词")
                        Text(app.settings.globalSystemPrompt.isEmpty ? "未设置" : app.settings.globalSystemPrompt)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                NavigationLink(value: Route.personas) { Text("助手模板") }
            }

            Section {
                Stepper(value: s.defaultContextLimit, in: 0...200, step: 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("默认上下文条数").font(.caption2).foregroundStyle(.secondary)
                        Text(app.settings.defaultContextLimit == 0 ? "不限" : "最近 \(app.settings.defaultContextLimit) 条").font(.footnote)
                    }
                }
                Stepper(value: s.maxImagesInContext, in: 0...10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("上下文中保留图片").font(.caption2).foregroundStyle(.secondary)
                        Text("最近 \(app.settings.maxImagesInContext) 条带图消息").font(.footnote)
                    }
                }
            } header: {
                Text("上下文")
            } footer: {
                Text("超出条数或模型上下文窗口时会自动截断最早的消息；也可在对话中压缩或清除上下文。")
            }

            Section("显示") {
                Picker("文字大小", selection: s.fontScale) {
                    ForEach(FontScale.allCases) { Text($0.title).tag($0) }
                }
                Picker("思考过程", selection: s.reasoningDisplay) {
                    ForEach(ReasoningDisplay.allCases) { Text($0.title).tag($0) }
                }
                Picker("新回答滚动", selection: s.scrollBehavior) {
                    ForEach(ScrollBehavior.allCases) { Text($0.title).tag($0) }
                }
                Toggle("显示消息信息", isOn: s.showMessageMeta)
                Toggle("快捷回复", isOn: s.showQuickReplies)
                NavigationLink {
                    QuickPromptsEditor()
                } label: {
                    Text("快捷短语（\(app.settings.quickPrompts.count)）")
                }
            }

            Section("交互") {
                Toggle("触感反馈", isOn: s.hapticsEnabled)
                Toggle("自动朗读回答", isOn: s.autoReadAloud)
                Toggle("后台完成时通知", isOn: s.notifyOnBackgroundReply)
                    .onChange(of: app.settings.notifyOnBackgroundReply) { _, on in if on { Notifier.requestAuthorization() } }
            }

            Section("对话管理") {
                Toggle("AI 自动生成标题", isOn: s.autoTitle)
                Picker("自动归档", selection: s.autoArchiveDays) {
                    Text("关闭").tag(0)
                    Text("7 天未活动").tag(7)
                    Text("30 天未活动").tag(30)
                    Text("90 天未活动").tag(90)
                }
            }

            Section {
                Picker("最大边长", selection: s.imageMaxDimension) {
                    Text("512 px").tag(512)
                    Text("768 px").tag(768)
                    Text("1024 px").tag(1024)
                    Text("1536 px").tag(1536)
                    Text("2048 px").tag(2048)
                }
                Picker("压缩质量", selection: s.imageQuality) {
                    Text("低").tag(0.5)
                    Text("中").tag(0.7)
                    Text("高").tag(0.85)
                }
            } header: {
                Text("图片上传")
            } footer: {
                Text("图片越小，上传越快、消耗 tokens 越少。")
            }

            Section("数据") {
                LabeledContent("存储占用", value: storage).font(.footnote)
                LabeledContent("对话", value: "\(app.conversations.conversations.count)").font(.footnote)
                Button("删除所有对话（保留收藏）", role: .destructive) { confirmDeleteAll = true }
                Button("恢复默认设置", role: .destructive) { confirmReset = true }
            }

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Text("Watch AI · 独立运行的 Apple Watch AI 客户端，支持任意 OpenAI 兼容接口。数据仅保存在本机。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .task {
            let size = FileStore.directorySize(FileStore.root)
            storage = Fmt.bytes(size)
        }
        .confirmationDialog("删除所有未收藏的对话？", isPresented: $confirmDeleteAll) {
            Button("删除", role: .destructive) { app.conversations.deleteAll(includeFavorites: false) }
        }
        .confirmationDialog("恢复所有设置为默认值？（不影响 API 与数据）", isPresented: $confirmReset) {
            Button("恢复", role: .destructive) {
                let keepProvider = app.settings.defaultProviderID
                let keepModel = app.settings.defaultModelName
                app.settingsStore.reset()
                app.settings.defaultProviderID = keepProvider
                app.settings.defaultModelName = keepModel
            }
        }
    }
}

struct GlobalPromptView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = Binding(get: { app.settings }, set: { app.settings = $0 })
        List {
            Section {
                TextField("例如：请始终用简体中文回答", text: s.globalSystemPrompt, axis: .vertical)
                    .lineLimit(2...10)
                    .font(.footnote)
            } footer: {
                Text("作用于所有对话，位于对话提示词之前。")
            }
            Button("清空", role: .destructive) { app.settings.globalSystemPrompt = "" }
        }
        .navigationTitle("全局提示词")
    }
}

struct QuickPromptsEditor: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            ForEach(app.settings.quickPrompts, id: \.self) { p in
                Text(p).font(.footnote)
            }
            .onDelete { idx in app.settings.quickPrompts.remove(atOffsets: idx) }
            .onMove { from, to in app.settings.quickPrompts.move(fromOffsets: from, toOffset: to) }
            TextFieldLink(prompt: Text("新的快捷短语")) {
                Label("添加", systemImage: "plus")
            } onSubmit: { t in
                let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty && !app.settings.quickPrompts.contains(v) { app.settings.quickPrompts.append(v) }
            }
            Text("左滑删除；前 4 条会显示在回答下方。").font(.caption2).foregroundStyle(.secondary)
        }
        .navigationTitle("快捷短语")
    }
}

struct PersonaListView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Persona?

    var body: some View {
        List {
            ForEach(app.settingsStore.personas) { p in
                Button { editing = p } label: {
                    HStack {
                        Text(p.emoji)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.footnote)
                            if !p.systemPrompt.isEmpty {
                                Text(p.systemPrompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .onDelete { idx in app.settingsStore.personas.remove(atOffsets: idx) }
            Button {
                let p = Persona(name: "新助手", emoji: "✨", systemPrompt: "")
                app.settingsStore.personas.append(p)
                editing = p
            } label: {
                Label("新建助手", systemImage: "plus")
            }
            Button("恢复默认助手") { app.settingsStore.personas = Persona.defaults }
                .font(.caption2)
        }
        .navigationTitle("助手模板")
        .sheet(item: $editing) { p in PersonaEditSheet(persona: p) }
    }
}

struct PersonaEditSheet: View {
    let persona: Persona
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Persona

    init(persona: Persona) {
        self.persona = persona
        _draft = State(initialValue: persona)
    }

    var body: some View {
        NavigationStack {
            List {
                TextField("名称", text: $draft.name)
                TextField("图标 Emoji", text: $draft.emoji)
                TextField("系统提示词", text: $draft.systemPrompt, axis: .vertical).lineLimit(2...10)
                NavigationLink {
                    ModelPickerView(selectedProviderID: draft.providerID, selectedModel: draft.modelName, allowDefault: true) { pid, m in
                        draft.providerID = pid
                        draft.modelName = m
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("模型").font(.footnote)
                        Text(draft.modelName ?? "跟随默认").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("保存") {
                    if let i = app.settingsStore.personas.firstIndex(where: { $0.id == persona.id }) {
                        app.settingsStore.personas[i] = draft
                    }
                    dismiss()
                }
            }
            .navigationTitle("编辑助手")
        }
    }
}
