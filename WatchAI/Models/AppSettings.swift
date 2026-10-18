import SwiftUI

enum FontScale: String, Codable, CaseIterable, Identifiable {
    case system, small, medium, large, xLarge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .small: return "小"
        case .medium: return "标准"
        case .large: return "大"
        case .xLarge: return "特大"
        }
    }
    var dynamicType: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .small: return .small
        case .medium: return .large
        case .large: return .xLarge
        case .xLarge: return .xxLarge
        }
    }
}

enum ReasoningDisplay: String, Codable, CaseIterable, Identifiable {
    case collapsed, expanded, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .collapsed: return "折叠"
        case .expanded: return "展开"
        case .hidden: return "隐藏"
        }
    }
}

enum ScrollBehavior: String, Codable, CaseIterable, Identifiable {
    case toQuestion, follow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toQuestion: return "从问题开始读"
        case .follow: return "跟随输出"
        }
    }
}

struct AppSettings: Codable, Equatable {
    // 模型
    var defaultProviderID: UUID?
    var defaultModelName: String?
    var auxProviderID: UUID?
    var auxModelName: String?
    var streamEnabled = true
    var temperature: Double?
    var globalSystemPrompt = ""
    var conciseMode = true
    var defaultContextLimit = 20
    var maxImagesInContext = 2

    // 显示与交互
    var fontScale: FontScale = .system
    var reasoningDisplay: ReasoningDisplay = .collapsed
    var scrollBehavior: ScrollBehavior = .toQuestion
    var showMessageMeta = true
    var showQuickReplies = true
    var hapticsEnabled = true
    var autoReadAloud = false
    var notifyOnBackgroundReply = true
    var quickPrompts: [String] = ["继续", "详细说说", "举个例子", "总结要点", "用更简单的话说", "翻译成英文"]

    // 对话管理
    var autoTitle = true
    var autoArchiveDays = 0

    // Agent 工具
    var agentEnabled = true
    var toolMemo = true
    var toolTodo = true
    var toolTimer = true
    var toolWeb = true
    var toolSearch = true
    var maxToolRounds = 6

    // 反思记忆
    var memoryEnabled = true
    var memoryAutoReflect = true
    var memoryAllowAIWrite = true
    var memoryInjectLimit = 30
    var reflectMinNewMessages = 4

    // 计费
    var monthlyBudget: Double = 0
    var budgetCurrency = "CNY"
    var usdToCny: Double = 7.1

    // 图片
    var imageMaxDimension = 1024
    var imageQuality: Double = 0.7

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? def
        }
        defaultProviderID = try? c.decodeIfPresent(UUID.self, forKey: .defaultProviderID)
        defaultModelName = try? c.decodeIfPresent(String.self, forKey: .defaultModelName)
        auxProviderID = try? c.decodeIfPresent(UUID.self, forKey: .auxProviderID)
        auxModelName = try? c.decodeIfPresent(String.self, forKey: .auxModelName)
        temperature = try? c.decodeIfPresent(Double.self, forKey: .temperature)
        streamEnabled = v(.streamEnabled, d.streamEnabled)
        globalSystemPrompt = v(.globalSystemPrompt, d.globalSystemPrompt)
        conciseMode = v(.conciseMode, d.conciseMode)
        defaultContextLimit = v(.defaultContextLimit, d.defaultContextLimit)
        maxImagesInContext = v(.maxImagesInContext, d.maxImagesInContext)
        fontScale = v(.fontScale, d.fontScale)
        reasoningDisplay = v(.reasoningDisplay, d.reasoningDisplay)
        scrollBehavior = v(.scrollBehavior, d.scrollBehavior)
        showMessageMeta = v(.showMessageMeta, d.showMessageMeta)
        showQuickReplies = v(.showQuickReplies, d.showQuickReplies)
        hapticsEnabled = v(.hapticsEnabled, d.hapticsEnabled)
        autoReadAloud = v(.autoReadAloud, d.autoReadAloud)
        notifyOnBackgroundReply = v(.notifyOnBackgroundReply, d.notifyOnBackgroundReply)
        quickPrompts = v(.quickPrompts, d.quickPrompts)
        autoTitle = v(.autoTitle, d.autoTitle)
        autoArchiveDays = v(.autoArchiveDays, d.autoArchiveDays)
        agentEnabled = v(.agentEnabled, d.agentEnabled)
        toolMemo = v(.toolMemo, d.toolMemo)
        toolTodo = v(.toolTodo, d.toolTodo)
        toolTimer = v(.toolTimer, d.toolTimer)
        toolWeb = v(.toolWeb, d.toolWeb)
        toolSearch = v(.toolSearch, d.toolSearch)
        maxToolRounds = v(.maxToolRounds, d.maxToolRounds)
        memoryEnabled = v(.memoryEnabled, d.memoryEnabled)
        memoryAutoReflect = v(.memoryAutoReflect, d.memoryAutoReflect)
        memoryAllowAIWrite = v(.memoryAllowAIWrite, d.memoryAllowAIWrite)
        memoryInjectLimit = v(.memoryInjectLimit, d.memoryInjectLimit)
        reflectMinNewMessages = v(.reflectMinNewMessages, d.reflectMinNewMessages)
        monthlyBudget = v(.monthlyBudget, d.monthlyBudget)
        budgetCurrency = v(.budgetCurrency, d.budgetCurrency)
        usdToCny = v(.usdToCny, d.usdToCny)
        imageMaxDimension = v(.imageMaxDimension, d.imageMaxDimension)
        imageQuality = v(.imageQuality, d.imageQuality)
    }
}
