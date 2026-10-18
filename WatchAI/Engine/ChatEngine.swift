import Foundation
import Observation
import WatchKit

enum GenerationPhase: Equatable {
    case connecting
    case thinking
    case writing
    case tool(String)

    var title: String {
        switch self {
        case .connecting: return "连接中…"
        case .thinking: return "思考中…"
        case .writing: return "输出中…"
        case .tool(let name): return "调用\(name)…"
        }
    }
}

/// 让生成在抬腕结束后仍能短暂继续
final class BackgroundActivity: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    static func begin() -> BackgroundActivity {
        let token = BackgroundActivity()
        ProcessInfo.processInfo.performExpiringActivity(withReason: "生成 AI 回复") { expired in
            if !expired { _ = token.semaphore.wait(timeout: .now() + 240) }
        }
        return token
    }

    func end() { semaphore.signal() }
}

@MainActor
@Observable
final class ChatEngine {
    private(set) var phases: [UUID: GenerationPhase] = [:]
    /// 正在进行的辅助任务（标题、压缩、整理等）
    var busyTasks: Set<String> = []

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let conversations: ConversationStore
    @ObservationIgnored let providers: ProviderStore
    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let usage: UsageStore
    @ObservationIgnored let agent: AgentStore
    @ObservationIgnored let memory: MemoryStore
    @ObservationIgnored let client = OpenAIClient.shared

    init(conversations: ConversationStore, providers: ProviderStore, settingsStore: SettingsStore,
         usage: UsageStore, agent: AgentStore, memory: MemoryStore) {
        self.conversations = conversations
        self.providers = providers
        self.settingsStore = settingsStore
        self.usage = usage
        self.agent = agent
        self.memory = memory
    }

    var settings: AppSettings { settingsStore.settings }

    func isGenerating(_ id: UUID) -> Bool { phases[id] != nil }
    var anyGenerating: Bool { !phases.isEmpty }

    // MARK: - 公共操作

    func send(_ text: String, images: [ImageAttachment] = [], to cid: UUID) {
        guard !isGenerating(cid) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        let content = trimmed.isEmpty ? "请描述并分析这张图片。" : trimmed
        let msg = ChatMessage(role: .user, content: content, images: images)
        conversations.append(msg, to: cid)
        if let c = conversations.conversation(cid), !c.titleGenerated, c.messageCount <= 1 {
            let fallback = ConversationStore.plainSnippet(content, limit: 18)
            conversations.update(cid) { $0.title = fallback.isEmpty ? "图片对话" : fallback }
        }
        conversations.update(cid) { $0.updatedAt = Date() }
        Haptics.play(.click, settings)
        start(cid)
    }

    func stop(_ cid: UUID) {
        tasks[cid]?.cancel()
    }

    /// 重新生成最后一轮回答
    func regenerate(_ cid: UUID, from assistantID: UUID? = nil) {
        guard !isGenerating(cid) else { return }
        let list = conversations.messages(cid)
        var userIndex: Int?
        if let assistantID, let idx = list.firstIndex(where: { $0.id == assistantID }) {
            userIndex = list[..<idx].lastIndex(where: { $0.role == .user })
        } else {
            userIndex = list.lastIndex(where: { $0.role == .user })
        }
        guard let userIndex else { return }
        conversations.truncate(cid, from: list[userIndex].id, inclusive: false)
        start(cid)
    }

    /// 编辑用户消息并重新发送
    func resend(_ cid: UUID, userMessageID: UUID, newText: String) {
        guard !isGenerating(cid) else { return }
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        conversations.updateMessage(cid, userMessageID, persist: true) { $0.content = t; $0.createdAt = Date() }
        conversations.truncate(cid, from: userMessageID, inclusive: false)
        start(cid)
    }

    func insertDivider(_ cid: UUID) {
        let list = conversations.messages(cid)
        if list.last?.role == .divider || list.isEmpty { return }
        conversations.append(ChatMessage(role: .divider, content: ""), to: cid)
        Haptics.play(.click, settings)
    }

    private func start(_ cid: UUID) {
        phases[cid] = .connecting
        tasks[cid] = Task { [weak self] in
            await self?.run(cid)
        }
    }

    // MARK: - 生成主流程

    private func run(_ cid: UUID) async {
        let bg = BackgroundActivity.begin()
        defer {
            bg.end()
            phases[cid] = nil
            tasks[cid] = nil
        }
        guard let conv = conversations.conversation(cid) else { return }
        guard let resolved = providers.resolve(providerID: conv.providerID, modelName: conv.modelName, settings: settings) else {
            var m = ChatMessage(role: .assistant, content: "")
            m.status = .error
            m.errorText = "还没有可用的模型。请在「API 管理」中添加服务商并填写 API Key。"
            conversations.append(m, to: cid)
            Haptics.play(.failure, settings)
            return
        }
        let (provider, model) = resolved
        let apiKey = providers.apiKey(for: provider)
        let toolDefs = ToolRegistry.definitions(settings)
        let toolsActive = settings.agentEnabled && conv.toolsEnabled && model.supportsTools && !toolDefs.isEmpty
        let memories = settings.memoryEnabled && conv.memoryEnabled ? memory.injectable(limit: settings.memoryInjectLimit) : []
        let extra = OpenAIClient.parseExtraParams(model.extraParams)
        var round = 0
        var lastAssistantText = ""

        while !Task.isCancelled {
            round += 1
            let allowTools = toolsActive && round <= settings.maxToolRounds
            var placeholder = ChatMessage(role: .assistant, content: "")
            placeholder.status = .streaming
            placeholder.modelName = model.label
            let pid = placeholder.id
            conversations.append(placeholder, to: cid, persist: false)

            guard let currentConv = conversations.conversation(cid) else { return }
            let history = conversations.messages(cid).filter { $0.id != pid }
            let ctx = ContextBuilder.build(conversation: currentConv, history: history, provider: provider, model: model,
                                           settings: settings, memories: memories, toolsActive: toolsActive)
            let config = RequestConfig(
                baseURL: provider.baseURL, apiKey: apiKey, model: model.name,
                temperature: currentConv.temperature ?? settings.temperature,
                maxTokens: currentConv.maxTokens ?? (model.maxOutputTokens > 0 ? model.maxOutputTokens : nil),
                tools: allowTools ? toolDefs : nil,
                extraParams: extra,
                stream: settings.streamEnabled)

            var raw = ""
            var reasoningField = ""
            var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
            var apiUsage: TokenUsage?
            var finishReason: String?
            var firstToken: Double?
            let reqStart = Date()
            var lastFlush = Date.distantPast

            func flush() {
                let s = ThinkParser.split(raw)
                let reasoning = [reasoningField, s.reasoning].filter { !$0.isEmpty }.joined(separator: "\n")
                conversations.updateMessage(cid, pid) { m in
                    m.content = s.content
                    m.reasoning = reasoning.isEmpty ? nil : reasoning
                }
                let phase: GenerationPhase
                if !toolAcc.isEmpty, s.content.isEmpty {
                    phase = .tool(ToolRegistry.displayName(toolAcc.values.first?.name ?? ""))
                } else if s.isThinking || (s.content.isEmpty && !reasoning.isEmpty) {
                    phase = .thinking
                } else if s.content.isEmpty {
                    phase = .connecting
                } else {
                    phase = .writing
                }
                if phases[cid] != phase { phases[cid] = phase }
            }

            do {
                if config.stream {
                    for try await ev in client.stream(config, messages: ctx.messages) {
                        switch ev {
                        case .content(let t):
                            raw += t
                            if firstToken == nil { firstToken = Date().timeIntervalSince(reqStart) }
                        case .reasoning(let t):
                            reasoningField += t
                            if firstToken == nil { firstToken = Date().timeIntervalSince(reqStart) }
                        case let .toolCall(index, id, name, args):
                            var e = toolAcc[index] ?? (id: "", name: "", args: "")
                            if let id, !id.isEmpty, e.id.isEmpty { e.id = id }
                            if let name, !name.isEmpty, e.name.isEmpty { e.name = name }
                            if let args { e.args += args }
                            toolAcc[index] = e
                        case .usage(let u):
                            apiUsage = u
                        case .finish(let r):
                            if let r { finishReason = r }
                        }
                        if Date().timeIntervalSince(lastFlush) > 0.12 {
                            flush()
                            lastFlush = Date()
                        }
                    }
                } else {
                    phases[cid] = .thinking
                    let r = try await client.complete(config, messages: ctx.messages)
                    raw = r.content
                    reasoningField = r.reasoning
                    apiUsage = r.usage
                    finishReason = r.finishReason
                    firstToken = Date().timeIntervalSince(reqStart)
                    for (i, tc) in r.toolCalls.enumerated() { toolAcc[i] = (tc.id, tc.name, tc.arguments) }
                }
                try Task.checkCancellation()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                let s = ThinkParser.split(raw)
                let reasoning = [reasoningField, s.reasoning].filter { !$0.isEmpty }.joined(separator: "\n")
                let hasOutput = !raw.isEmpty || !reasoningField.isEmpty
                var usageValue: TokenUsage?
                if hasOutput || apiUsage != nil {
                    usageValue = makeUsage(apiUsage, promptEstimate: ctx.estimatedTokens, output: raw + reasoningField, model: model, provider: provider)
                    record(usageValue!, provider: provider, model: model, kind: .chat, conversationID: cid, latency: firstToken)
                }
                conversations.updateMessage(cid, pid, persist: true) { m in
                    m.content = s.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    m.reasoning = reasoning.isEmpty ? nil : reasoning
                    m.status = cancelled ? .interrupted : .error
                    m.errorText = cancelled ? nil : Self.describe(error)
                    m.usage = usageValue
                    m.firstTokenLatency = firstToken
                    m.duration = Date().timeIntervalSince(reqStart)
                }
                if cancelled, !hasOutput {
                    conversations.deleteMessage(cid, pid)
                }
                if !cancelled { Haptics.play(.failure, settings) }
                return
            }

            // 本轮结束
            let split = ThinkParser.split(raw)
            let reasoning = [reasoningField, split.reasoning].filter { !$0.isEmpty }.joined(separator: "\n")
            let toolCalls: [ToolCall] = toolAcc.sorted { $0.key < $1.key }.compactMap { entry in
                let v = entry.value
                guard !v.name.isEmpty else { return nil }
                return ToolCall(id: v.id.isEmpty ? "call_\(UUID().short)" : v.id, name: v.name,
                                arguments: v.args.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : v.args)
            }
            let toolText = toolCalls.map { $0.name + $0.arguments }.joined()
            let usageValue = makeUsage(apiUsage, promptEstimate: ctx.estimatedTokens, output: raw + reasoningField + toolText, model: model, provider: provider)
            record(usageValue, provider: provider, model: model, kind: .chat, conversationID: cid, latency: firstToken)
            let content = split.content.trimmingCharacters(in: .whitespacesAndNewlines)
            conversations.updateMessage(cid, pid, persist: true) { m in
                m.content = content
                m.reasoning = reasoning.isEmpty ? nil : reasoning
                m.toolCalls = allowTools ? toolCalls : []
                m.status = .complete
                m.usage = usageValue
                m.firstTokenLatency = firstToken
                m.duration = Date().timeIntervalSince(reqStart)
                if content.isEmpty && toolCalls.isEmpty {
                    if finishReason == "length" {
                        m.status = .error
                        m.errorText = "输出被截断：max_tokens 过小，思考过程已用尽额度。"
                    } else if reasoning.isEmpty {
                        m.status = .error
                        m.errorText = "模型没有返回内容。"
                    }
                } else if finishReason == "length" {
                    m.errorText = "已达到最大输出长度，回答可能不完整。"
                }
            }
            if !content.isEmpty { lastAssistantText = content }

            if allowTools && !toolCalls.isEmpty {
                for call in toolCalls {
                    if Task.isCancelled { break }
                    phases[cid] = .tool(ToolRegistry.displayName(call.name))
                    let out = await ToolRegistry.execute(call, engine: self, conversationID: cid)
                    var tm = ChatMessage(role: .tool, content: out.result)
                    tm.toolCallID = call.id
                    tm.toolName = call.name
                    tm.displayText = out.display
                    tm.status = out.ok ? .complete : .error
                    conversations.append(tm, to: cid)
                }
                Haptics.play(.click, settings)
                phases[cid] = .connecting
                continue
            }
            break
        }

        if Task.isCancelled { return }
        Haptics.play(.success, settings)
        afterReply(cid, text: lastAssistantText)
    }

    private func afterReply(_ cid: UUID, text: String) {
        if settings.notifyOnBackgroundReply, WKApplication.shared().applicationState != .active, !text.isEmpty {
            let title = conversations.conversation(cid)?.title ?? "Watch AI"
            Notifier.notifyNow(id: "reply-\(cid.uuidString)", title: title, body: ConversationStore.plainSnippet(text, limit: 120))
        }
        if settings.autoReadAloud, !text.isEmpty {
            SpeechService.shared.speak(text)
        }
        if settings.autoTitle, let c = conversations.conversation(cid), !c.titleGenerated {
            Task { await self.generateTitle(cid) }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? APIError { return e.errorDescription ?? "\(e)" }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "网络未连接。请检查手表的 Wi-Fi / 蜂窝网络或与 iPhone 的连接。"
            case .timedOut: return "请求超时，请稍后重试。"
            case .cannotFindHost, .cannotConnectToHost: return "无法连接服务器，请检查接口地址。"
            case .networkConnectionLost: return "网络连接中断（可能是放下手腕后应用进入了后台）。"
            case .secureConnectionFailed: return "安全连接失败。"
            default: return u.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - 计费

    func makeUsage(_ api: TokenUsage?, promptEstimate: Int, output: String, model: ModelConfig, provider: APIProvider) -> TokenUsage {
        var u = api ?? TokenUsage(promptTokens: promptEstimate, completionTokens: TokenEstimator.estimate(output), estimated: true)
        u.cost = model.cost(prompt: u.promptTokens, completion: u.completionTokens, cached: u.cachedTokens)
        u.currency = provider.currency
        return u
    }

    func record(_ u: TokenUsage, provider: APIProvider, model: ModelConfig, kind: UsageKind, conversationID: UUID?, latency: Double?) {
        usage.add(UsageRecord(providerID: provider.id, providerName: provider.name, model: model.name, kind: kind,
                              promptTokens: u.promptTokens, completionTokens: u.completionTokens, cachedTokens: u.cachedTokens,
                              cost: u.cost, currency: u.currency, estimated: u.estimated, conversationID: conversationID, latency: latency))
    }

    // MARK: - 辅助调用

    func auxComplete(system: String, user: String, kind: UsageKind, conversationID: UUID?, maxTokens: Int = 4096) async throws -> String {
        let conv = conversationID.flatMap { conversations.conversation($0) }
        guard let resolved = providers.resolveAux(settings: settings, fallbackProviderID: conv?.providerID, fallbackModel: conv?.modelName) else {
            throw APIError.server("还没有可用的模型，请先在「API 管理」中配置。")
        }
        let (p, m) = resolved
        let config = RequestConfig(baseURL: p.baseURL, apiKey: providers.apiKey(for: p), model: m.name,
                                   temperature: nil, maxTokens: maxTokens, tools: nil,
                                   extraParams: OpenAIClient.parseExtraParams(m.extraParams), stream: false)
        let messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": user]]
        let start = Date()
        let r = try await client.complete(config, messages: messages)
        let u = makeUsage(r.usage, promptEstimate: TokenEstimator.estimate(system + user), output: r.content + r.reasoning, model: m, provider: p)
        record(u, provider: p, model: m, kind: kind, conversationID: conversationID, latency: Date().timeIntervalSince(start))
        let text = ThinkParser.strip(r.content)
        if text.isEmpty { throw APIError.empty }
        return text
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        var t = text
        if let r = t.range(of: "```json") { t = String(t[r.upperBound...]) }
        else if let r = t.range(of: "```") { t = String(t[r.upperBound...]) }
        guard let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}"), s < e else { return nil }
        let body = String(t[s...e])
        guard let d = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private func transcript(_ list: [ChatMessage], perMessage: Int, total: Int) -> String {
        var lines: [String] = []
        var count = 0
        for m in list.reversed() {
            let role: String
            switch m.role {
            case .user: role = "用户"
            case .assistant: role = "助手"
            default: continue
            }
            var c = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.isEmpty { continue }
            if !m.images.isEmpty { c = "［\(m.images.count) 张图片］" + c }
            if c.count > perMessage { c = String(c.prefix(perMessage)) + "…" }
            count += c.count
            if count > total && !lines.isEmpty { break }
            lines.append("\(role)：\(c)")
        }
        return lines.reversed().joined(separator: "\n\n")
    }

    // MARK: 标题

    func generateTitle(_ cid: UUID) async {
        let key = "title-\(cid)"
        guard !busyTasks.contains(key) else { return }
        busyTasks.insert(key)
        defer { busyTasks.remove(key) }
        let list = conversations.messages(cid)
        let text = transcript(Array(list.prefix(6)), perMessage: 500, total: 1500)
        guard !text.isEmpty else { return }
        do {
            let raw = try await auxComplete(system: "你是标题生成器。根据对话内容生成一个精炼的中文标题，不超过 12 个字，不要标点、引号和解释，只输出标题本身。",
                                            user: text, kind: .title, conversationID: cid, maxTokens: 2048)
            var t = raw.split(separator: "\n").first.map(String.init) ?? raw
            t = t.replacingOccurrences(of: "标题：", with: "").replacingOccurrences(of: "标题:", with: "")
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’《》「」#*。.，,"))
            if t.count > 20 { t = String(t.prefix(20)) }
            guard !t.isEmpty else { return }
            conversations.update(cid) { $0.title = t; $0.titleGenerated = true }
        } catch {
            conversations.update(cid) { $0.titleGenerated = true }
        }
    }

    // MARK: 压缩上下文

    func compressContext(_ cid: UUID) async throws {
        guard let conv = conversations.conversation(cid) else { return }
        let list = conversations.messages(cid)
        let slice = ContextBuilder.contextSlice(conversation: conv, history: list).messages
        guard let last = list.last(where: { $0.role == .user || $0.role == .assistant }), !slice.isEmpty else {
            throw APIError.server("当前上下文为空，无需压缩。")
        }
        let key = "compress-\(cid)"
        busyTasks.insert(key)
        defer { busyTasks.remove(key) }
        var input = transcript(slice, perMessage: 1500, total: 14000)
        if let old = conv.contextSummary, ContextBuilder.contextSlice(conversation: conv, history: list).usesSummary {
            input = "【已有摘要】\n\(old)\n\n【后续对话】\n" + input
        }
        let summary = try await auxComplete(
            system: "你是对话压缩器。将对话压缩为精炼但信息完整的摘要，保留：用户的目标与偏好、已确定的事实与结论、关键数据/代码要点、尚未解决的问题。使用中文要点列表，不超过 400 字。只输出摘要。",
            user: input, kind: .summary, conversationID: cid)
        conversations.update(cid) {
            $0.contextSummary = summary
            $0.contextSummaryUntil = last.id
        }
    }

    func clearContextSummary(_ cid: UUID) {
        conversations.update(cid) {
            $0.contextSummary = nil
            $0.contextSummaryUntil = nil
        }
    }

    // MARK: 对话摘要

    func summarize(_ cid: UUID) async throws {
        let key = "summary-\(cid)"
        busyTasks.insert(key)
        defer { busyTasks.remove(key) }
        let text = transcript(conversations.messages(cid), perMessage: 800, total: 10000)
        guard !text.isEmpty else { throw APIError.server("对话为空") }
        let s = try await auxComplete(system: "用 3-5 个要点总结这段对话的主题、结论与待办，每点不超过 30 字，使用“- ”开头的 Markdown 列表，只输出列表。",
                                      user: text, kind: .summary, conversationID: cid)
        conversations.update(cid) { $0.summary = s }
    }

    // MARK: 智能整理

    struct OrganizeResult {
        var moved = 0
        var renamed = 0
        var newFolders = 0
    }

    func organize(renameTitles: Bool, onlyUnfiled: Bool) async throws -> OrganizeResult {
        busyTasks.insert("organize")
        defer { busyTasks.remove("organize") }
        let candidates = conversations.active.filter { $0.messageCount > 0 && (!onlyUnfiled || $0.folderID == nil) }.prefix(40)
        guard !candidates.isEmpty else { throw APIError.server("没有需要整理的对话。") }
        let folderNames = conversations.folders.map { "\($0.emoji)\($0.name)" }.joined(separator: "、")
        let lines = candidates.map { c in
            "[\(c.id.short)] 标题：\(c.title) | 问题：\(c.lastQuestion) | 回答：\(String(c.preview.prefix(50)))"
        }.joined(separator: "\n")
        let system = """
        你是对话整理助手。为每个对话分配一个分类文件夹：优先使用已有文件夹，必要时新建；文件夹总数不超过 8 个，名称 2-4 个字，并配一个 emoji。\
        同时给出不超过 12 字的精炼标题和最多 2 个标签。只输出 JSON，格式：
        {"items":[{"id":"短ID","folder":"文件夹名","emoji":"📁","title":"标题","tags":["标签"]}]}
        """
        let user = "已有文件夹：\(folderNames.isEmpty ? "无" : folderNames)\n\n对话列表：\n\(lines)"
        let text = try await auxComplete(system: system, user: user, kind: .organize, conversationID: nil, maxTokens: 6000)
        guard let json = Self.extractJSON(text), let items = json["items"] as? [[String: Any]] else {
            throw APIError.decoding("模型返回的整理结果不是有效 JSON")
        }
        var result = OrganizeResult()
        let before = conversations.folders.count
        for item in items {
            guard let sid = item["id"] as? String,
                  let idx = conversations.conversations.index(matchingShort: sid) else { continue }
            let cid = conversations.conversations[idx].id
            if let name = (item["folder"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                let emoji = (item["emoji"] as? String) ?? "📁"
                let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: emoji))
                let folder = conversations.addFolder(name: cleanName.isEmpty ? name : cleanName, emoji: emoji.isEmpty ? "📁" : String(emoji.prefix(2)))
                if conversations.conversation(cid)?.folderID != folder.id {
                    conversations.update(cid) { $0.folderID = folder.id }
                    result.moved += 1
                }
            }
            if renameTitles, let t = item["title"] as? String, !t.isEmpty {
                conversations.update(cid) { $0.title = String(t.prefix(20)); $0.titleGenerated = true }
                result.renamed += 1
            }
            if let tags = item["tags"] as? [String] {
                conversations.update(cid) { $0.tags = Array(tags.prefix(3)) }
            }
        }
        result.newFolders = conversations.folders.count - before
        return result
    }

    // MARK: - 反思记忆

    private func reflectable(_ list: [ChatMessage]) -> [ChatMessage] {
        list.filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
    }

    func maybeAutoReflect(_ cid: UUID) {
        guard settings.memoryEnabled, settings.memoryAutoReflect, !isGenerating(cid),
              let c = conversations.conversation(cid), c.memoryEnabled else { return }
        let count = reflectable(conversations.messages(cid)).count
        guard count - min(c.reflectedMessageCount, count) >= settings.reflectMinNewMessages else { return }
        Task { _ = try? await self.reflect(cid, manual: false) }
    }

    @discardableResult
    func reflect(_ cid: UUID, manual: Bool) async throws -> ReflectionLog? {
        guard !memory.reflectingIDs.contains(cid), let c = conversations.conversation(cid) else { return nil }
        let all = reflectable(conversations.messages(cid))
        let startIndex = manual ? max(0, all.count - 30) : min(c.reflectedMessageCount, all.count)
        let fresh = Array(all[startIndex...].suffix(30))
        guard !fresh.isEmpty else {
            if manual { throw APIError.server("没有新的对话内容可供反思。") }
            return nil
        }
        memory.reflectingIDs.insert(cid)
        defer { memory.reflectingIDs.remove(cid) }

        let existing = memory.sorted.prefix(80).map { "[\($0.id.short)] (\($0.category)) \($0.content)" }.joined(separator: "\n")
        let system = """
        你是 AI 助手的“反思记忆”模块。阅读用户与助手的对话，提炼值得长期记住的、关于用户本人的信息：身份背景、长期偏好、习惯、目标、正在进行的项目、重要的人和事、对回答风格的反馈等。
        规则：
        1. 只记录稳定、可复用、对未来对话有帮助的信息；不要记录一次性的问题、常识或助手自己的观点。
        2. 每条一句话，第三人称（如“用户……”），不超过 60 字。
        3. 与已有记忆重复则不新增；有更新或矛盾时用 update 修改对应 id；用户明确否定的记忆放入 delete。
        4. 没有值得记住的内容时返回空数组。
        只输出 JSON：{"add":[{"content":"…","category":"背景|偏好|习惯|目标|项目|关系|其他"}],"update":[{"id":"…","content":"…"}],"delete":["id"]}
        """
        let user = "已有记忆：\n\(existing.isEmpty ? "（无）" : existing)\n\n对话：\n\(transcript(fresh, perMessage: 800, total: 9000))"
        let text = try await auxComplete(system: system, user: user, kind: .reflection, conversationID: cid)
        guard let json = Self.extractJSON(text) else { throw APIError.decoding("反思结果不是有效 JSON") }
        var log = applyMemoryOps(json, conversationID: cid, source: .reflection)
        log.title = c.title
        conversations.update(cid) { $0.reflectedMessageCount = all.count }
        if !log.isEmpty || manual { memory.addLog(log) }
        return log
    }

    func reflectRecent(limit: Int = 5) async -> Int {
        var n = 0
        let candidates = conversations.active.filter { c in
            c.memoryEnabled && reflectable(conversations.messages(c.id)).count > c.reflectedMessageCount
        }.prefix(limit)
        for c in candidates {
            if let log = try? await reflect(c.id, manual: false), !log.isEmpty { n += 1 }
        }
        return n
    }

    func consolidateMemories() async throws -> ReflectionLog {
        guard memory.memories.count >= 2 else { throw APIError.server("记忆条目太少，无需整理。") }
        memory.isConsolidating = true
        defer { memory.isConsolidating = false }
        let list = memory.sorted.map { "[\($0.id.short)] (\($0.category)) \($0.content)" }.joined(separator: "\n")
        let system = """
        你是记忆整理模块。下面是关于用户的记忆条目。请合并重复或相近的条目、修正相互矛盾的内容、删除明显过时或无价值的条目。合并时保留其中一条（用 update 写入合并后的内容）并删除其余。
        只输出 JSON：{"update":[{"id":"…","content":"…","category":"…"}],"delete":["id"],"add":[]}
        """
        let text = try await auxComplete(system: system, user: list, kind: .reflection, conversationID: nil, maxTokens: 6000)
        guard let json = Self.extractJSON(text) else { throw APIError.decoding("整理结果不是有效 JSON") }
        var log = applyMemoryOps(json, conversationID: nil, source: .reflection)
        log.title = "整理合并记忆"
        memory.addLog(log)
        return log
    }

    private func applyMemoryOps(_ json: [String: Any], conversationID: UUID?, source: MemorySource) -> ReflectionLog {
        var log = ReflectionLog(conversationID: conversationID, title: "")
        if let adds = json["add"] as? [[String: Any]] {
            for a in adds {
                guard let c = a["content"] as? String else { continue }
                let before = memory.memories.count
                if memory.add(c, category: (a["category"] as? String) ?? "其他", source: source, conversationID: conversationID) != nil,
                   memory.memories.count > before {
                    log.added.append(c)
                }
            }
        }
        if let ups = json["update"] as? [[String: Any]] {
            for u in ups {
                guard let id = u["id"] as? String, let idx = memory.memories.index(matchingShort: id),
                      let c = u["content"] as? String, !c.isEmpty else { continue }
                let mid = memory.memories[idx].id
                memory.update(mid) { m in
                    m.content = c
                    if let cat = u["category"] as? String, MemoryItem.categories.contains(cat) { m.category = cat }
                }
                log.updated.append(c)
            }
        }
        if let dels = json["delete"] as? [String] {
            for id in dels {
                guard let idx = memory.memories.index(matchingShort: id) else { continue }
                let m = memory.memories[idx]
                memory.delete(m.id)
                log.removed.append(m.content)
            }
        }
        return log
    }

    // MARK: - 连接测试

    func testConnection(_ provider: APIProvider, model: ModelConfig) async throws -> String {
        let config = RequestConfig(baseURL: provider.baseURL, apiKey: providers.apiKey(for: provider), model: model.name,
                                   temperature: nil, maxTokens: 1024, tools: nil,
                                   extraParams: OpenAIClient.parseExtraParams(model.extraParams), stream: false)
        let start = Date()
        let r = try await client.complete(config, messages: [["role": "user", "content": "只回复：OK"]])
        let u = makeUsage(r.usage, promptEstimate: 10, output: r.content + r.reasoning, model: model, provider: provider)
        record(u, provider: provider, model: model, kind: .test, conversationID: nil, latency: Date().timeIntervalSince(start))
        let reply = ThinkParser.strip(r.content)
        return String(format: "✅ %.1fs · %@", Date().timeIntervalSince(start), reply.isEmpty ? "(仅思考内容)" : String(reply.prefix(30)))
    }
}
