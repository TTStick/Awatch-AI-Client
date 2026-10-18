import Foundation

enum ChatRole: String, Codable {
    case system, user, assistant, tool
    /// 上下文分隔线：此前的消息不再发送给模型
    case divider
}

enum MessageStatus: String, Codable {
    case complete, streaming, error, interrupted
}

struct ImageAttachment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var width: Int
    var height: Int
    var byteSize: Int

    var fileURL: URL { AttachmentStore.directory.appendingPathComponent(fileName) }
}

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}

struct TokenUsage: Codable, Hashable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var cachedTokens: Int = 0
    var reasoningTokens: Int = 0
    var cost: Double = 0
    var currency: String = "CNY"
    var estimated: Bool = false

    var totalTokens: Int { promptTokens + completionTokens }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        var r = lhs
        r.promptTokens += rhs.promptTokens
        r.completionTokens += rhs.completionTokens
        r.cachedTokens += rhs.cachedTokens
        r.reasoningTokens += rhs.reasoningTokens
        r.cost += rhs.cost
        r.estimated = lhs.estimated || rhs.estimated
        return r
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String
    var reasoning: String?
    var images: [ImageAttachment] = []
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    var toolName: String?
    /// 工具结果在界面上的简短描述
    var displayText: String?
    var createdAt: Date = Date()
    var modelName: String?
    var usage: TokenUsage?
    var status: MessageStatus = .complete
    var errorText: String?
    var isFavorite: Bool = false
    var excludedFromContext: Bool = false
    var firstTokenLatency: Double?
    var duration: Double?

    init(role: ChatRole, content: String, images: [ImageAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    var isEmptyAssistant: Bool {
        role == .assistant && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPinned: Bool = false
    var isFavorite: Bool = false
    var isArchived: Bool = false
    var folderID: UUID?
    var tags: [String] = []
    var personaID: UUID?
    var providerID: UUID?
    var modelName: String?
    var systemPrompt: String = ""
    var temperature: Double?
    var maxTokens: Int?
    /// nil 表示使用全局设置；0 表示不限制
    var contextLimit: Int?
    var toolsEnabled: Bool = true
    var memoryEnabled: Bool = true
    /// AI 生成的对话摘要（用于整理与速览）
    var summary: String?
    /// 压缩后的上下文摘要
    var contextSummary: String?
    var contextSummaryUntil: UUID?
    var reflectedMessageCount: Int = 0
    var messageCount: Int = 0
    var preview: String = ""
    var lastQuestion: String = ""
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var costCurrency: String = "CNY"
    var titleGenerated: Bool = false
}

struct Folder: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var emoji: String = "📁"
    var createdAt: Date = Date()
}

struct Persona: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var emoji: String
    var systemPrompt: String
    var providerID: UUID?
    var modelName: String?
    var temperature: Double?

    static let defaults: [Persona] = [
        Persona(name: "通用助手", emoji: "🤖", systemPrompt: ""),
        Persona(name: "翻译官", emoji: "🌐", systemPrompt: "你是专业翻译。用户输入中文时翻译成地道的英文，输入其他语言时翻译成简体中文。只输出译文，必要时在末尾用一行给出关键词注释。"),
        Persona(name: "代码助手", emoji: "💻", systemPrompt: "你是资深软件工程师。回答以可运行的代码为主，代码放在带语言标注的代码块中，解释保持简短。"),
        Persona(name: "写作润色", emoji: "✍️", systemPrompt: "你是中文写作编辑。帮助用户润色、改写和扩写文字，保持原意，语言自然流畅，并简要说明主要修改。"),
        Persona(name: "百科速答", emoji: "📚", systemPrompt: "你是百科知识助手。先用一句话给出结论，再用不超过 3 个要点补充关键事实。")
    ]
}

/// 收藏的消息索引
struct FavoriteMessageRef: Codable, Identifiable, Hashable {
    var id: UUID { messageID }
    var conversationID: UUID
    var messageID: UUID
    var role: ChatRole
    var snippet: String
    var date: Date
}
