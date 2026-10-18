import SwiftUI

struct ProviderListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if app.providers.providers.isEmpty {
                Section {
                    Text("推荐先添加「MiniMax 国内」，填写在 platform.minimax.cn 创建的 API Key。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("服务商") {
                ForEach(app.providers.providers) { p in
                    NavigationLink(value: Route.provider(p.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if app.settings.defaultProviderID == p.id {
                                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                                }
                                Text(p.name).font(.footnote.weight(.semibold))
                                if !p.isEnabled { Text("已停用").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }
                            Text(p.host).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(p.models.count) 个模型 · Key \(app.providers.maskedKey(for: p))")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { app.providers.delete(p.id) } label: { Image(systemName: "trash") }
                    }
                }
                NavigationLink {
                    PresetPickerView()
                } label: {
                    Label("添加服务商", systemImage: "plus.circle.fill")
                }
            }
            if !app.providers.providers.isEmpty {
                Section {
                    NavigationLink {
                        ModelPickerView(selectedProviderID: app.settings.defaultProviderID, selectedModel: app.settings.defaultModelName) { pid, m in
                            app.settings.defaultProviderID = pid
                            app.settings.defaultModelName = m
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("默认模型").font(.footnote)
                            let r = app.providers.resolve(providerID: nil, modelName: nil, settings: app.settings)
                            Text(r.map { "\($0.0.name) · \($0.1.label)" } ?? "未设置").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        AuxModelPicker()
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("辅助模型").font(.footnote)
                            let r = app.providers.provider(app.settings.auxProviderID).flatMap { p in p.model(named: app.settings.auxModelName).map { (p, $0) } }
                            Text(r.map { "\($0.0.name) · \($0.1.label)" } ?? "与对话模型相同").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("辅助模型用于生成标题、压缩上下文、整理对话与反思记忆，可选更快更便宜的模型。")
                }
            }
        }
        .navigationTitle("API 管理")
    }
}

struct AuxModelPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                app.settings.auxProviderID = nil
                app.settings.auxModelName = nil
                dismiss()
            } label: {
                HStack { Text("与对话模型相同"); Spacer(); if app.settings.auxProviderID == nil { Image(systemName: "checkmark") } }
            }
            ForEach(app.providers.enabled) { p in
                Section(p.name) {
                    ForEach(p.models) { m in
                        Button {
                            app.settings.auxProviderID = p.id
                            app.settings.auxModelName = m.name
                            dismiss()
                        } label: {
                            HStack {
                                Text(m.label)
                                Spacer()
                                if app.settings.auxProviderID == p.id && app.settings.auxModelName == m.name { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("辅助模型")
    }
}

struct PresetPickerView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            ForEach(ProviderPreset.all) { preset in
                Button {
                    let p = preset.makeProvider()
                    app.providers.add(p)
                    if app.settings.defaultProviderID == nil || app.providers.provider(app.settings.defaultProviderID) == nil {
                        app.settings.defaultProviderID = p.id
                        app.settings.defaultModelName = p.defaultModel?.name
                    }
                    app.router.path.append(.provider(p.id))
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name).font(.footnote.weight(.semibold))
                        Text(preset.note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("选择服务商")
    }
}

struct ProviderEditView: View {
    let providerID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var fetching = false
    @State private var fetched: [String] = []
    @State private var showFetched = false
    @State private var confirmDelete = false

    var body: some View {
        if let p = app.providers.provider(providerID) {
            form(p)
        } else {
            Text("服务商已删除").foregroundStyle(.secondary)
        }
    }

    private func bind<T>(_ key: WritableKeyPath<APIProvider, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { app.providers.provider(providerID)?[keyPath: key] ?? fallback },
            set: { v in app.providers.update(providerID) { $0[keyPath: key] = v } }
        )
    }

    @ViewBuilder
    private func form(_ p: APIProvider) -> some View {
        List {
            Section {
                TextField("名称", text: bind(\.name, ""))
                VStack(alignment: .leading, spacing: 2) {
                    Text("接口地址").font(.caption2).foregroundStyle(.secondary)
                    TextField("https://…/v1", text: bind(\.baseURL, ""))
                        .textContentType(.URL)
                        .font(.caption)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前：\(app.providers.maskedKey(for: p))").font(.caption2).foregroundStyle(.secondary)
                    SecureField("粘贴或输入 API Key", text: $keyInput)
                        .font(.caption)
                        .onSubmit { saveKey(p) }
                }
                if !keyInput.isEmpty {
                    Button("保存 Key") { saveKey(p) }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Key 保存在手表钥匙串中。iPhone 在附近时可用 iPhone 键盘输入。")
            }

            Section {
                Button {
                    test(p)
                } label: {
                    HStack {
                        Label(testing ? "测试中…" : "测试连接", systemImage: "bolt.horizontal")
                        if testing { Spacer(); ProgressView().controlSize(.mini).frame(width: 14) }
                    }
                }
                .disabled(testing || p.models.isEmpty)
                if let testResult { Text(testResult).font(.caption2).foregroundStyle(.secondary) }
                Button {
                    fetchModels(p)
                } label: {
                    Label(fetching ? "获取中…" : "获取模型列表", systemImage: "arrow.down.circle")
                }
                .disabled(fetching)
            }

            Section("模型") {
                ForEach(p.models) { m in
                    NavigationLink {
                        ModelEditView(providerID: providerID, modelID: m.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                if p.defaultModelID == m.id || (p.defaultModelID == nil && p.models.first?.id == m.id) {
                                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                                }
                                Text(m.label).font(.footnote)
                            }
                            HStack(spacing: 4) {
                                if m.supportsVision { Image(systemName: "eye") }
                                if m.supportsTools { Image(systemName: "wrench") }
                                Text(m.hasPricing ? "\(Fmt.money(m.inputPrice, p.currency))/\(Fmt.money(m.outputPrice, p.currency)) 每百万" : "未设置单价")
                            }
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            app.providers.update(providerID) { $0.models.removeAll { $0.id == m.id } }
                        } label: { Image(systemName: "trash") }
                        Button {
                            app.providers.update(providerID) { $0.defaultModelID = m.id }
                        } label: { Image(systemName: "star") }.tint(.yellow)
                    }
                }
                TextFieldLink(prompt: Text("模型 ID，如 MiniMax-M3")) {
                    Label("手动添加模型", systemImage: "plus")
                } onSubmit: { name in
                    let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    app.providers.update(providerID) { $0.models.append(ModelConfig(name: t)) }
                }
            }

            Section {
                Picker("计价币种", selection: bind(\.currency, "CNY")) {
                    Text("人民币 ¥").tag("CNY")
                    Text("美元 $").tag("USD")
                }
                Picker("思考回传", selection: bind(\.thinkingReplay, .none)) {
                    ForEach(ThinkingReplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("启用", isOn: bind(\.isEnabled, true))
                if app.settings.defaultProviderID != providerID {
                    Button("设为默认服务商") {
                        app.settings.defaultProviderID = providerID
                        app.settings.defaultModelName = p.defaultModel?.name
                    }
                }
            } header: {
                Text("高级")
            } footer: {
                Text("MiniMax M2/M3 建议选择“仅工具调用轮”，把 <think> 思考内容随工具调用回传以保持推理连贯。")
            }

            Section {
                Button("删除服务商", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(p.name)
        .sheet(isPresented: $showFetched) {
            FetchedModelsSheet(providerID: providerID, models: fetched)
        }
        .confirmationDialog("删除「\(p.name)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                app.providers.delete(providerID)
                dismiss()
            }
        }
    }

    private func saveKey(_ p: APIProvider) {
        guard !keyInput.isEmpty else { return }
        app.providers.setAPIKey(keyInput, for: p)
        keyInput = ""
        testResult = "Key 已保存"
    }

    private func test(_ p: APIProvider) {
        guard let model = p.defaultModel else { return }
        testing = true
        testResult = nil
        Task {
            do {
                testResult = try await app.engine.testConnection(p, model: model)
            } catch {
                testResult = "❌ " + ChatEngine.describe(error)
            }
            testing = false
        }
    }

    private func fetchModels(_ p: APIProvider) {
        fetching = true
        testResult = nil
        Task {
            do {
                fetched = try await OpenAIClient.shared.listModels(baseURL: p.baseURL, apiKey: app.providers.apiKey(for: p))
                if fetched.isEmpty { testResult = "接口没有返回模型" } else { showFetched = true }
            } catch {
                testResult = "❌ " + ChatEngine.describe(error)
            }
            fetching = false
        }
    }
}

struct FetchedModelsSheet: View {
    let providerID: UUID
    let models: [String]
    @Environment(AppModel.self) private var app
    @State private var filter = ""

    var body: some View {
        let existing = Set(app.providers.provider(providerID)?.models.map(\.name) ?? [])
        let list = models.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
        List {
            Section {
                Text("点按添加或移除 · 共 \(models.count) 个").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(list, id: \.self) { name in
                Button {
                    app.providers.update(providerID) { p in
                        if p.models.contains(where: { $0.name == name }) {
                            p.models.removeAll { $0.name == name }
                        } else {
                            let lower = name.lowercased()
                            let vision = lower.contains("vl") || lower.contains("vision") || lower.contains("4o") || lower.contains("m3") || lower.contains("gpt-5") || lower.contains("gemini")
                            p.models.append(ModelConfig(name: name, supportsVision: vision))
                        }
                    }
                } label: {
                    HStack {
                        Text(name).font(.caption).lineLimit(2)
                        Spacer()
                        Image(systemName: existing.contains(name) ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(existing.contains(name) ? .green : .secondary)
                    }
                }
            }
        }
        .searchable(text: $filter)
    }
}

struct ModelEditView: View {
    let providerID: UUID
    let modelID: UUID
    @Environment(AppModel.self) private var app
    @State private var extraError: String?

    private let windows = [8_192, 32_768, 65_536, 128_000, 200_000, 204_800, 256_000, 1_000_000, 2_000_000]

    private var model: ModelConfig? {
        app.providers.provider(providerID)?.models.first(where: { $0.id == modelID })
    }

    private func bind<T>(_ key: WritableKeyPath<ModelConfig, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { model?[keyPath: key] ?? fallback },
            set: { v in
                app.providers.update(providerID) { p in
                    if let i = p.models.firstIndex(where: { $0.id == modelID }) { p.models[i][keyPath: key] = v }
                }
            })
    }

    private func priceBinding(_ key: WritableKeyPath<ModelConfig, Double>) -> Binding<String> {
        Binding(
            get: {
                let v = model?[keyPath: key] ?? 0
                return v == 0 ? "" : String(format: "%g", v)
            },
            set: { s in
                let v = Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
                bind(key, 0).wrappedValue = v
            })
    }

    var body: some View {
        let currency = app.providers.provider(providerID)?.currency ?? "CNY"
        let symbol = currency == "USD" ? "$" : "¥"
        List {
            Section("名称") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型 ID").font(.caption2).foregroundStyle(.secondary)
                    TextField("model", text: bind(\.name, "")).font(.caption)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示名").font(.caption2).foregroundStyle(.secondary)
                    TextField("可选", text: bind(\.displayName, "")).font(.caption)
                }
            }
            Section {
                priceRow("输入", symbol, priceBinding(\.inputPrice))
                priceRow("输出", symbol, priceBinding(\.outputPrice))
                priceRow("缓存命中", symbol, priceBinding(\.cachedPrice))
            } header: {
                Text("单价（每百万 tokens）")
            } footer: {
                Text("用于计算费用。未填写时只统计 tokens。")
            }
            Section("能力") {
                Toggle("图片输入（视觉）", isOn: bind(\.supportsVision, false))
                Toggle("工具调用", isOn: bind(\.supportsTools, true))
                Picker("上下文窗口", selection: bind(\.contextWindow, 128_000)) {
                    ForEach(windows, id: \.self) { Text(TokenEstimator.format($0)).tag($0) }
                }
                Stepper(value: bind(\.maxOutputTokens, 0), in: 0...65536, step: 1024) {
                    Text(model?.maxOutputTokens == 0 ? "输出上限：默认" : "输出上限：\(model?.maxOutputTokens ?? 0)").font(.footnote)
                }
            }
            Section {
                TextField("{\"key\": value}", text: Binding(
                    get: { model?.extraParams ?? "" },
                    set: { v in
                        bind(\.extraParams, "").wrappedValue = v
                        validate(v)
                    }), axis: .vertical)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1...5)
                if let extraError { Text(extraError).font(.caption2).foregroundStyle(.red) }
                Button("M3 关闭思考") { setExtra("{\"thinking\": {\"type\": \"disabled\"}}") }.font(.caption2)
                Button("思考与正文分离") { setExtra("{\"reasoning_split\": true}") }.font(.caption2)
                Button("低思考强度") { setExtra("{\"reasoning_effort\": \"low\"}") }.font(.caption2)
                Button("清空", role: .destructive) { setExtra("") }.font(.caption2)
            } header: {
                Text("额外请求参数（JSON）")
            } footer: {
                Text("会合并到请求体中，例如 MiniMax-M3 可关闭思考以加快速度、节省 tokens。")
            }
            Section {
                Button("设为该服务商默认模型") {
                    app.providers.update(providerID) { $0.defaultModelID = modelID }
                }
            }
        }
        .navigationTitle(model?.label ?? "模型")
    }

    private func priceRow(_ title: String, _ symbol: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            Text(symbol).foregroundStyle(.secondary)
            TextField("0", text: binding)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .font(.footnote.monospacedDigit())
        }
    }

    private func setExtra(_ v: String) {
        bind(\.extraParams, "").wrappedValue = v
        validate(v)
    }

    private func validate(_ v: String) {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { extraError = nil; return }
        if let d = t.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] {
            extraError = nil
        } else {
            extraError = "不是有效的 JSON 对象"
        }
    }
}
