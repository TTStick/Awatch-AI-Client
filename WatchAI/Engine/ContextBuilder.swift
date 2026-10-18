import Foundation

enum TokenEstimator {
    /// 粗略估算 tokens：中日韩字符约 0.7 token/字，其他约 3.6 字符/token
    static func estimate(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for s in text.unicodeScalars {
            let v = s.value
            if (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return Int(Double(cjk) * 0.7 + Double(other) / 3.6) + (text.isEmpty ? 0 : 1)
    }

    static let imageTokens = 800

    static func estimate(wire messages: [[String: Any]]) -> Int {
        var total = 0
        for m in messages {
            total += 4
            if let s = m["content"] as? String { total += estimate(s) }
            if let parts = m["content"] as? [[String: Any]] {
                for p in parts {
                    if let t = p["text"] as? String { total += estimate(t) }
                    if p["type"] as? String == "image_url" { total += imageTokens }
                }
            }
            if let calls = m["tool_calls"] as? [[String: Any]] {
                for c in calls {
                    if let fn = c["function"] as? [String: Any] {
                        total += estimate((fn["name"] as? String) ?? "") + estimate((fn["arguments"] as? String) ?? "")
                    }
                }
            }
        }
        return total
    }

    static func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        if n >= 1000 { return String(format: "%.2fk", Double(n) / 1000) }
        return "\(n)"
    }
}

struct BuiltContext {
    var messages: [[String: Any]]
    var estimatedTokens: Int
    var systemTokens: Int
    var includedCount: Int
    var droppedCount: Int
    var usesSummary: Bool
}

enum ContextBuilder {
    static func systemPrompt(conversation: Conversation, settings: AppSettings, memories: [MemoryItem],
                             toolsActive: Bool, includeSummary: Bool) -> String {
        var parts: [String] = []
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        parts.append("你是 Watch AI，运行在用户 Apple Watch 上的智能助手。当前本地时间：\(df.string(from: Date()))（时区 \(TimeZone.current.identifier)）。")
        if settings.conciseMode {
            parts.append("用户在手表小屏幕上阅读：先给结论，表达简洁、结构清晰，避免冗长铺垫与重复；除非用户要求详细，回答尽量控制在 200 字以内；合理使用短列表、加粗、表格与带语言标注的代码块。")
        }
        let global = settings.globalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { parts.append(global) }
        let local = conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty { parts.append(local) }
        if toolsActive {
            parts.append("你可以调用工具管理用户手表上的备忘录、待办事项和倒计时，也可以读取网页、检索历史对话、维护对用户的长期记忆。当用户提出相关需求（如“记一下…”、“提醒我…”、“5 分钟后叫我”）时直接调用工具完成，完成后用一句话确认结果。不要编造工具执行结果；工具返回错误时如实告知。")
        }
        if !memories.isEmpty {
            let list = memories.map { "- \($0.content)" }.joined(separator: "\n")
            parts.append("关于用户的长期记忆（来自过往对话的反思，可能不完全准确；仅在相关时自然地使用，不要逐条复述）：\n\(list)")
        }
        if includeSummary, let summary = conversation.contextSummary, !summary.isEmpty {
            parts.append("此前对话已被压缩，摘要如下：\n\(summary)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 当前上下文窗口中的消息（分隔线、摘要之后）
    static func contextSlice(conversation: Conversation, history: [ChatMessage]) -> (messages: [ChatMessage], usesSummary: Bool) {
        var start = 0
        let dividerIndex = history.lastIndex(where: { $0.role == .divider })
        if let d = dividerIndex { start = d + 1 }
        var usesSummary = false
        if let until = conversation.contextSummaryUntil, conversation.contextSummary != nil,
           let idx = history.firstIndex(where: { $0.id == until }), idx >= (dividerIndex ?? -1) {
            start = max(start, idx + 1)
            usesSummary = true
        }
        guard start < history.count else { return ([], usesSummary) }
        let slice = history[start...].filter { m in
            guard !m.excludedFromContext else { return false }
            switch m.role {
            case .user, .tool: return true
            case .assistant: return m.status != .streaming && !(m.status == .error && m.isEmptyAssistant)
            case .system, .divider: return false
            }
        }
        return (validatePairs(Array(slice)), usesSummary)
    }

    /// 保证 tool_calls 与工具结果成对出现
    static func validatePairs(_ list: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var i = 0
        while i < list.count {
            let m = list[i]
            if m.role == .assistant && !m.toolCalls.isEmpty {
                var j = i + 1
                var tools: [ChatMessage] = []
                while j < list.count && list[j].role == .tool {
                    tools.append(list[j])
                    j += 1
                }
                let ids = Set(tools.compactMap(\.toolCallID))
                var mm = m
                mm.toolCalls = m.toolCalls.filter { ids.contains($0.id) }
                let valid = Set(mm.toolCalls.map(\.id))
                if !mm.toolCalls.isEmpty || !mm.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(mm)
                    result += tools.filter { valid.contains($0.toolCallID ?? "") }
                }
                i = j
            } else if m.role == .tool {
                i += 1
            } else {
                if !(m.role == .assistant && m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    result.append(m)
                }
                i += 1
            }
        }
        return result
    }

    static func build(conversation: Conversation, history: [ChatMessage], provider: APIProvider, model: ModelConfig,
                      settings: AppSettings, memories: [MemoryItem], toolsActive: Bool) -> BuiltContext {
        let (sliceAll, usesSummary) = contextSlice(conversation: conversation, history: history)
        var slice = sliceAll
        let total = slice.count

        // 条数限制（只计算用户/助手消息）
        let limit = conversation.contextLimit ?? settings.defaultContextLimit
        if limit > 0 {
            var count = 0
            var cut = 0
            for idx in stride(from: slice.count - 1, through: 0, by: -1) {
                if slice[idx].role == .user || (slice[idx].role == .assistant && slice[idx].toolCalls.isEmpty) {
                    count += 1
                    if count > limit {
                        cut = idx + 1
                        break
                    }
                }
            }
            if cut > 0 { slice = Array(slice[cut...]) }
        }
        slice = dropLeadingNonUser(slice)

        let system = systemPrompt(conversation: conversation, settings: settings, memories: memories,
                                  toolsActive: toolsActive, includeSummary: usesSummary)
        let systemTokens = TokenEstimator.estimate(system)

        // 图片：仅最近若干条带图消息发送原图
        let imageMessageIDs: Set<UUID> = {
            guard model.supportsVision else { return [] }
            let withImages = slice.filter { $0.role == .user && !$0.images.isEmpty }
            return Set(withImages.suffix(max(0, settings.maxImagesInContext)).map(\.id))
        }()

        var wire = slice.map { wireMessage($0, sendImages: imageMessageIDs.contains($0.id), model: model, replay: provider.thinkingReplay) }

        // tokens 预算
        let reserve = max(1024, min(conversation.maxTokens ?? (model.maxOutputTokens > 0 ? model.maxOutputTokens : 8192), model.contextWindow / 3))
        let budget = max(2048, model.contextWindow - reserve - systemTokens)
        var tokens = TokenEstimator.estimate(wire: wire)
        while tokens > budget && slice.count > 1 {
            var dropCount = 1
            if slice[0].role == .assistant && !slice[0].toolCalls.isEmpty {
                while dropCount < slice.count && slice[dropCount].role == .tool { dropCount += 1 }
            }
            slice.removeFirst(dropCount)
            wire.removeFirst(dropCount)
            while let f = slice.first, f.role != .user, slice.count > 1 {
                slice.removeFirst()
                wire.removeFirst()
            }
            tokens = TokenEstimator.estimate(wire: wire)
        }

        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += wire
        return BuiltContext(messages: messages, estimatedTokens: tokens + systemTokens, systemTokens: systemTokens,
                            includedCount: slice.count, droppedCount: total - slice.count, usesSummary: usesSummary)
    }

    struct Estimate {
        var messages: Int
        var tokens: Int
        var limited: Bool
        var usesSummary: Bool
        /// 当前会发送给模型的消息 ID
        var includedIDs: Set<UUID>
    }

    /// 供界面展示的轻量估算（不读取图片数据）
    static func quickEstimate(conversation: Conversation, history: [ChatMessage], settings: AppSettings) -> Estimate {
        let (sliceAll, usesSummary) = contextSlice(conversation: conversation, history: history)
        var slice = sliceAll
        let limit = conversation.contextLimit ?? settings.defaultContextLimit
        var limited = false
        if limit > 0 {
            var count = 0
            for idx in stride(from: slice.count - 1, through: 0, by: -1) {
                if slice[idx].role == .user || (slice[idx].role == .assistant && slice[idx].toolCalls.isEmpty) {
                    count += 1
                    if count > limit {
                        slice = Array(slice[(idx + 1)...])
                        limited = true
                        break
                    }
                }
            }
        }
        slice = dropLeadingNonUser(slice)
        var tokens = 0
        for m in slice {
            tokens += TokenEstimator.estimate(m.content) + 4 + m.images.count * TokenEstimator.imageTokens
            for tc in m.toolCalls { tokens += TokenEstimator.estimate(tc.arguments) + 4 }
        }
        if usesSummary, let s = conversation.contextSummary { tokens += TokenEstimator.estimate(s) }
        tokens += TokenEstimator.estimate(settings.globalSystemPrompt + conversation.systemPrompt) + 120
        return Estimate(messages: slice.filter { $0.role == .user || $0.role == .assistant }.count, tokens: tokens,
                        limited: limited, usesSummary: usesSummary, includedIDs: Set(slice.map(\.id)))
    }

    private static func dropLeadingNonUser(_ list: [ChatMessage]) -> [ChatMessage] {
        guard let first = list.firstIndex(where: { $0.role == .user }) else { return list.filter { $0.role != .tool } }
        return Array(list[first...])
    }

    static func wireMessage(_ m: ChatMessage, sendImages: Bool, model: ModelConfig, replay: ThinkingReplay) -> [String: Any] {
        switch m.role {
        case .user:
            if m.images.isEmpty { return ["role": "user", "content": m.content] }
            if sendImages {
                var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                for img in m.images {
                    if let url = AttachmentStore.dataURL(for: img) {
                        parts.append(["type": "image_url", "image_url": ["url": url]])
                    }
                }
                return ["role": "user", "content": parts]
            }
            let note = model.supportsVision ? "［此处有 \(m.images.count) 张较早的图片，已省略］" : "［用户附带了 \(m.images.count) 张图片，但当前模型不支持识别图片］"
            return ["role": "user", "content": m.content + "\n" + note]
        case .assistant:
            var content = m.content
            if let r = m.reasoning, !r.isEmpty, replay == .all || (replay == .toolTurns && !m.toolCalls.isEmpty) {
                content = "<think>\n\(r)\n</think>\n\n" + content
            }
            var dict: [String: Any] = ["role": "assistant"]
            dict["content"] = content.isEmpty && !m.toolCalls.isEmpty ? NSNull() : content
            if !m.toolCalls.isEmpty {
                dict["tool_calls"] = m.toolCalls.map { tc -> [String: Any] in
                    ["id": tc.id, "type": "function", "function": ["name": tc.name, "arguments": tc.arguments]]
                }
            }
            return dict
        case .tool:
            return ["role": "tool", "tool_call_id": m.toolCallID ?? "", "name": m.toolName ?? "", "content": m.content]
        case .system:
            return ["role": "system", "content": m.content]
        case .divider:
            return ["role": "system", "content": ""]
        }
    }
}
