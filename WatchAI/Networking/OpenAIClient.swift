import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case missingKey
    case http(Int, String)
    case server(String)
    case decoding(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "接口地址无效"
        case .missingKey: return "未设置 API Key"
        case let .http(code, msg):
            let hint: String
            switch code {
            case 401, 403: hint = "（Key 无效或无权限）"
            case 404: hint = "（地址或模型不存在）"
            case 429: hint = "（请求过快或额度不足）"
            case 500...599: hint = "（服务端错误）"
            default: hint = ""
            }
            return "HTTP \(code)\(hint)：\(msg)"
        case let .server(msg): return msg
        case let .decoding(msg): return "解析失败：\(msg)"
        case .empty: return "模型没有返回内容"
        }
    }
}

struct RequestConfig {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double?
    var maxTokens: Int?
    var tools: [[String: Any]]?
    var extraParams: [String: Any] = [:]
    var stream: Bool = true
}

enum StreamEvent {
    case content(String)
    case reasoning(String)
    case toolCall(index: Int, id: String?, name: String?, arguments: String?)
    case usage(TokenUsage)
    case finish(String?)
}

struct CompletionResult {
    var content: String = ""
    var reasoning: String = ""
    var toolCalls: [ToolCall] = []
    var usage: TokenUsage?
    var finishReason: String?
}

final class OpenAIClient: @unchecked Sendable {
    static let shared = OpenAIClient()

    let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "chat/completions", b.hasSuffix("/chat/completions") { return URL(string: b) }
        if b.hasSuffix("/chat/completions") { b = String(b.dropLast("/chat/completions".count)) }
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + "/" + path)
    }

    /// 本地/局域网服务（如 Ollama、LM Studio）可以不填 Key
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
    }

    static func parseExtraParams(_ json: String) -> [String: Any] {
        let t = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func makeRequest(_ config: RequestConfig, messages: [[String: Any]]) throws -> URLRequest {
        guard let url = Self.endpoint(config.baseURL, "chat/completions") else { throw APIError.invalidURL }
        if config.apiKey.isEmpty && !Self.isLocal(url) { throw APIError.missingKey }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        if config.stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.setValue("WatchAI/1.0 (watchOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("https://watchai.app", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Watch AI", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": config.stream
        ]
        if config.stream { body["stream_options"] = ["include_usage": true] }
        if let t = config.temperature { body["temperature"] = t }
        if let m = config.maxTokens, m > 0 { body["max_tokens"] = m }
        if let tools = config.tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        for (k, v) in config.extraParams { body[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - 流式

    func stream(_ config: RequestConfig, messages: [[String: Any]]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try makeRequest(config, messages: messages)
                    let (bytes, response) = try await session.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4000 { break }
                        }
                        throw APIError.http(status, Self.extractError(body) ?? body)
                    }
                    var rawBuffer = ""
                    var sawSSE = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed.hasPrefix(":") { continue }
                        if trimmed.hasPrefix("data:") {
                            sawSSE = true
                            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            try Self.emit(json, into: continuation)
                        } else if trimmed.hasPrefix("event:") || trimmed.hasPrefix("id:") || trimmed.hasPrefix("retry:") {
                            continue
                        } else {
                            rawBuffer += line + "\n"
                        }
                    }
                    // 服务端忽略了 stream 参数，直接返回完整 JSON
                    if !sawSSE, !rawBuffer.isEmpty {
                        guard let data = rawBuffer.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw APIError.decoding(String(rawBuffer.prefix(300)))
                        }
                        try Self.checkBaseResp(json)
                        let r = Self.parseCompletion(json)
                        if !r.reasoning.isEmpty { continuation.yield(.reasoning(r.reasoning)) }
                        if !r.content.isEmpty { continuation.yield(.content(r.content)) }
                        for (i, tc) in r.toolCalls.enumerated() {
                            continuation.yield(.toolCall(index: i, id: tc.id, name: tc.name, arguments: tc.arguments))
                        }
                        if let u = r.usage { continuation.yield(.usage(u)) }
                        continuation.yield(.finish(r.finishReason))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func emit(_ json: [String: Any], into c: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws {
        if let err = json["error"] as? [String: Any] {
            throw APIError.server((err["message"] as? String) ?? "\(err)")
        }
        try checkBaseResp(json)
        if let u = json["usage"] as? [String: Any], let usage = parseUsage(u) {
            c.yield(.usage(usage))
        }
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else { return }
        let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
        if let r = delta["reasoning_content"] as? String, !r.isEmpty { c.yield(.reasoning(r)) }
        else if let r = delta["reasoning"] as? String, !r.isEmpty { c.yield(.reasoning(r)) }
        if let details = delta["reasoning_details"] as? [[String: Any]] {
            for d in details { if let t = d["text"] as? String, !t.isEmpty { c.yield(.reasoning(t)) } }
        }
        if let text = delta["content"] as? String, !text.isEmpty { c.yield(.content(text)) }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for (offset, call) in calls.enumerated() {
                let index = (call["index"] as? Int) ?? offset
                let fn = call["function"] as? [String: Any]
                c.yield(.toolCall(index: index, id: call["id"] as? String,
                                  name: fn?["name"] as? String, arguments: fn?["arguments"] as? String))
            }
        }
        if let reason = choice["finish_reason"] as? String { c.yield(.finish(reason)) }
    }

    // MARK: - 非流式

    func complete(_ config: RequestConfig, messages: [[String: Any]]) async throws -> CompletionResult {
        var cfg = config
        cfg.stream = false
        let req = try makeRequest(cfg, messages: messages)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw APIError.http(status, Self.extractError(text) ?? String(text.prefix(300)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding(String(text.prefix(300)))
        }
        if let err = json["error"] as? [String: Any] {
            throw APIError.server((err["message"] as? String) ?? "\(err)")
        }
        try Self.checkBaseResp(json)
        return Self.parseCompletion(json)
    }

    static func parseCompletion(_ json: [String: Any]) -> CompletionResult {
        var r = CompletionResult()
        if let u = json["usage"] as? [String: Any] { r.usage = parseUsage(u) }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return r }
        r.finishReason = choice["finish_reason"] as? String
        let msg = (choice["message"] as? [String: Any]) ?? [:]
        r.content = (msg["content"] as? String) ?? ""
        r.reasoning = (msg["reasoning_content"] as? String) ?? (msg["reasoning"] as? String) ?? ""
        if r.reasoning.isEmpty, let details = msg["reasoning_details"] as? [[String: Any]] {
            r.reasoning = details.compactMap { $0["text"] as? String }.joined()
        }
        if let calls = msg["tool_calls"] as? [[String: Any]] {
            r.toolCalls = calls.compactMap { call in
                guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
                let args: String
                if let s = fn["arguments"] as? String { args = s }
                else if let o = fn["arguments"], let d = try? JSONSerialization.data(withJSONObject: o) { args = String(data: d, encoding: .utf8) ?? "{}" }
                else { args = "{}" }
                return ToolCall(id: (call["id"] as? String) ?? "call_\(UUID().short)", name: name, arguments: args)
            }
        }
        return r
    }

    static func parseUsage(_ u: [String: Any]) -> TokenUsage? {
        func int(_ v: Any?) -> Int {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            if let s = v as? String { return Int(s) ?? 0 }
            return 0
        }
        let prompt = int(u["prompt_tokens"] ?? u["input_tokens"])
        let completion = int(u["completion_tokens"] ?? u["output_tokens"])
        guard prompt > 0 || completion > 0 else { return nil }
        var usage = TokenUsage(promptTokens: prompt, completionTokens: completion)
        if let d = u["prompt_tokens_details"] as? [String: Any] { usage.cachedTokens = int(d["cached_tokens"]) }
        if usage.cachedTokens == 0 { usage.cachedTokens = int(u["prompt_cache_hit_tokens"] ?? u["cached_tokens"]) }
        if let d = u["completion_tokens_details"] as? [String: Any] { usage.reasoningTokens = int(d["reasoning_tokens"]) }
        return usage
    }

    /// MiniMax 等服务商在 200 响应中通过 base_resp 返回错误
    static func checkBaseResp(_ json: [String: Any]) throws {
        if let base = json["base_resp"] as? [String: Any] {
            let code = (base["status_code"] as? Int) ?? 0
            if code != 0 {
                throw APIError.server("错误 \(code)：\((base["status_msg"] as? String) ?? "未知错误")")
            }
        }
    }

    static func extractError(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(300))
        }
        if let err = json["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = json["error"] as? String { return m }
        if let m = json["message"] as? String { return m }
        if let base = json["base_resp"] as? [String: Any], let m = base["status_msg"] as? String { return m }
        return nil
    }

    // MARK: - 模型列表

    func listModels(baseURL: String, apiKey: String) async throws -> [String] {
        guard let url = Self.endpoint(baseURL, "models") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else { throw APIError.http(status, Self.extractError(text) ?? text) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.decoding(text) }
        let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }
}

/// 解析内容中的 <think> 标签
enum ThinkParser {
    struct Result {
        var reasoning: String
        var content: String
        var isThinking: Bool
    }

    static func split(_ raw: String) -> Result {
        guard raw.contains("<think>") || raw.contains("</think>") else {
            return Result(reasoning: "", content: raw, isThinking: false)
        }
        var reasoning = ""
        var content = ""
        var rest = Substring(raw)
        // 仅有结束标签：之前的内容都是思考
        if !raw.contains("<think>"), let end = rest.range(of: "</think>") {
            reasoning = String(rest[..<end.lowerBound])
            content = String(rest[end.upperBound...])
            return Result(reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
                          content: content.trimmingLeadingNewlines(), isThinking: false)
        }
        var thinking = false
        while !rest.isEmpty {
            if let start = rest.range(of: "<think>") {
                content += rest[..<start.lowerBound]
                let after = rest[start.upperBound...]
                if let end = after.range(of: "</think>") {
                    reasoning += after[..<end.lowerBound]
                    rest = after[end.upperBound...]
                } else {
                    reasoning += after
                    thinking = true
                    rest = ""
                }
            } else {
                content += rest
                rest = ""
            }
        }
        return Result(reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
                      content: content.trimmingLeadingNewlines(), isThinking: thinking)
    }

    static func strip(_ raw: String) -> String {
        split(raw).content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    func trimmingLeadingNewlines() -> String {
        var s = Substring(self)
        while let f = s.first, f == "\n" || f == "\r" || f == " " && s.dropFirst().first == "\n" { s = s.dropFirst() }
        return String(s)
    }
}
