import Foundation

/// 多轮对话中如何回传模型的思考内容
enum ThinkingReplay: String, Codable, CaseIterable, Identifiable {
    case none
    case toolTurns
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "不回传"
        case .toolTurns: return "仅工具调用轮"
        case .all: return "全部回传"
        }
    }
}

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 接口中使用的模型 ID
    var name: String
    var displayName: String = ""
    /// 每百万 tokens 价格（按服务商币种）
    var inputPrice: Double = 0
    var outputPrice: Double = 0
    var cachedPrice: Double = 0
    var contextWindow: Int = 128_000
    var maxOutputTokens: Int = 0
    var supportsVision: Bool = false
    var supportsTools: Bool = true
    /// 额外请求参数（JSON 对象），会合并进请求体
    var extraParams: String = ""

    var label: String { displayName.isEmpty ? name : displayName }
    var hasPricing: Bool { inputPrice > 0 || outputPrice > 0 }

    func cost(prompt: Int, completion: Int, cached: Int) -> Double {
        let uncached = max(0, prompt - cached)
        let cachedRate = cachedPrice > 0 ? cachedPrice : inputPrice
        return (Double(uncached) * inputPrice + Double(cached) * cachedRate + Double(completion) * outputPrice) / 1_000_000
    }
}

struct APIProvider: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var currency: String = "CNY"
    var models: [ModelConfig] = []
    var defaultModelID: UUID?
    var thinkingReplay: ThinkingReplay = .none
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var presetKey: String?

    var keychainKey: String { "apikey.\(id.uuidString)" }

    var defaultModel: ModelConfig? {
        models.first(where: { $0.id == defaultModelID }) ?? models.first
    }

    func model(named name: String?) -> ModelConfig? {
        guard let name else { return defaultModel }
        return models.first(where: { $0.name == name }) ?? defaultModel
    }

    var host: String { URL(string: baseURL)?.host ?? baseURL }
}

struct ProviderPreset: Identifiable {
    let key: String
    let name: String
    let baseURL: String
    let currency: String
    let thinkingReplay: ThinkingReplay
    let models: [ModelConfig]
    let note: String
    var id: String { key }

    func makeProvider() -> APIProvider {
        var p = APIProvider(name: name, baseURL: baseURL, currency: currency, models: models, thinkingReplay: thinkingReplay)
        p.defaultModelID = models.first?.id
        p.presetKey = key
        return p
    }

    private static func minimaxModels(cny: Bool) -> [ModelConfig] {
        let (i, o, c3, c2): (Double, Double, Double, Double) = cny ? (2.1, 8.4, 0.42, 0.21) : (0.3, 1.2, 0.06, 0.03)
        return [
            ModelConfig(name: "MiniMax-M3", displayName: "M3", inputPrice: i, outputPrice: o, cachedPrice: c3,
                        contextWindow: 1_000_000, supportsVision: true, supportsTools: true),
            ModelConfig(name: "MiniMax-M2.7", displayName: "M2.7", inputPrice: i, outputPrice: o, cachedPrice: c3,
                        contextWindow: 204_800, supportsVision: false, supportsTools: true),
            ModelConfig(name: "MiniMax-M2.7-highspeed", displayName: "M2.7 极速", inputPrice: i * 2, outputPrice: o * 2, cachedPrice: c3,
                        contextWindow: 204_800, supportsVision: false, supportsTools: true),
            ModelConfig(name: "MiniMax-M2.5", displayName: "M2.5", inputPrice: i, outputPrice: o, cachedPrice: c2,
                        contextWindow: 204_800, supportsVision: false, supportsTools: true)
        ]
    }

    static let all: [ProviderPreset] = [
        ProviderPreset(key: "minimax-cn", name: "MiniMax 国内", baseURL: "https://api.minimax.cn/v1", currency: "CNY",
                       thinkingReplay: .toolTurns, models: minimaxModels(cny: true),
                       note: "platform.minimax.cn 的 API Key；M3 支持图片"),
        ProviderPreset(key: "minimax-intl", name: "MiniMax 国际", baseURL: "https://api.minimax.io/v1", currency: "USD",
                       thinkingReplay: .toolTurns, models: minimaxModels(cny: false),
                       note: "platform.minimax.io 的 API Key"),
        ProviderPreset(key: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", currency: "USD",
                       thinkingReplay: .none,
                       models: [ModelConfig(name: "gpt-4o-mini", contextWindow: 128_000, supportsVision: true)],
                       note: "可在编辑页“获取模型列表”"),
        ProviderPreset(key: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", currency: "CNY",
                       thinkingReplay: .none,
                       models: [ModelConfig(name: "deepseek-chat", contextWindow: 128_000)],
                       note: "价格请按官网填写"),
        ProviderPreset(key: "moonshot", name: "Kimi 月之暗面", baseURL: "https://api.moonshot.cn/v1", currency: "CNY",
                       thinkingReplay: .none, models: [], note: "使用“获取模型列表”添加模型"),
        ProviderPreset(key: "dashscope", name: "阿里云百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", currency: "CNY",
                       thinkingReplay: .none,
                       models: [ModelConfig(name: "qwen-plus", contextWindow: 128_000)],
                       note: "通义千问 OpenAI 兼容模式"),
        ProviderPreset(key: "zhipu", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", currency: "CNY",
                       thinkingReplay: .none, models: [], note: "使用“获取模型列表”添加模型"),
        ProviderPreset(key: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", currency: "CNY",
                       thinkingReplay: .none, models: [], note: "使用“获取模型列表”添加模型"),
        ProviderPreset(key: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", currency: "USD",
                       thinkingReplay: .none, models: [], note: "使用“获取模型列表”添加模型"),
        ProviderPreset(key: "custom", name: "自定义", baseURL: "https://", currency: "CNY",
                       thinkingReplay: .none, models: [], note: "任意 OpenAI 兼容接口")
    ]
}

enum UsageKind: String, Codable, CaseIterable, Identifiable {
    case chat, title, reflection, summary, organize, test

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return "对话"
        case .title: return "标题"
        case .reflection: return "反思"
        case .summary: return "摘要/压缩"
        case .organize: return "整理"
        case .test: return "测试"
        }
    }
}

struct UsageRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var providerID: UUID?
    var providerName: String
    var model: String
    var kind: UsageKind
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int
    var cost: Double
    var currency: String
    var estimated: Bool
    var conversationID: UUID?
    var latency: Double?

    var totalTokens: Int { promptTokens + completionTokens }
}
