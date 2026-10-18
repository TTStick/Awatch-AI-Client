import SwiftUI
import Observation

enum ConversationFilter: Hashable {
    case all
    case favorites
    case archived
    case folder(UUID)
    case unfiled
    case tag(String)

    var title: String {
        switch self {
        case .all: return "全部对话"
        case .favorites: return "收藏"
        case .archived: return "归档"
        case .folder: return "文件夹"
        case .unfiled: return "未分类"
        case .tag(let t): return "#\(t)"
        }
    }
}

enum Route: Hashable {
    case chat(UUID)
    case conversations(ConversationFilter)
    case folders
    case favorites
    case qa
    case search
    case toolbox
    case memos
    case memo(UUID)
    case todos
    case timers
    case memory
    case usage
    case providers
    case provider(UUID)
    case settings
    case personas
}

struct WebItem: Identifiable, Hashable {
    let id = UUID()
    let source: WebSource
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []
    var web: WebItem?
    /// 需要交给系统打开的链接
    @ObservationIgnored var systemBypass: Set<URL> = []

    func open(_ route: Route) { path.append(route) }

    func popToRoot() { path.removeAll() }

    func handle(_ url: URL) -> OpenURLAction.Result {
        if systemBypass.remove(url) != nil { return .systemAction }
        guard let scheme = url.scheme?.lowercased() else { return .discarded }
        if scheme == "http" || scheme == "https" {
            web = WebItem(source: .url(url))
            return .handled
        }
        if scheme == "watchai" {
            handleDeepLink(url)
            return .handled
        }
        return .systemAction
    }

    /// 深度链接：watchai://new | ask?q= | chat/<id> | timers | todos | memos | qa | usage | memory | settings | providers | search
    @ObservationIgnored var onAsk: ((String) -> Void)?
    @ObservationIgnored var onNew: (() -> Void)?

    func handleDeepLink(_ url: URL) {
        let host = url.host ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first(where: { $0.name == name })?.value }
        switch host {
        case "new": onNew?()
        case "ask":
            // 不带问题（如表盘「问 AI」）时打开新对话等待输入
            if let text = q("q"), !text.isEmpty { onAsk?(text) } else { onNew?() }
        case "chat":
            if let id = UUID(uuidString: url.lastPathComponent) { path = [.chat(id)] }
        case "timers": path = [.toolbox, .timers]
        case "todos": path = [.toolbox, .todos]
        case "memos": path = [.toolbox, .memos]
        case "toolbox": path = [.toolbox]
        case "qa": path = [.qa]
        case "usage": path = [.usage]
        case "memory": path = [.memory]
        case "settings": path = [.settings]
        case "providers": path = [.providers]
        case "search": path = [.search]
        case "favorites": path = [.favorites]
        case "folders": path = [.folders]
        case "home": path = []
        default: break
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let settingsStore = SettingsStore()
    let conversations = ConversationStore()
    let providers = ProviderStore()
    let usage = UsageStore()
    let agent = AgentStore()
    let memory = MemoryStore()
    let router = Router()
    let engine: ChatEngine
    /// 从首页选图后，带入新对话的待发送图片
    var pendingImages: [UUID: [ImageAttachment]] = [:]

    init() {
        engine = ChatEngine(conversations: conversations, providers: providers, settingsStore: settingsStore,
                            usage: usage, agent: agent, memory: memory)
        conversations.autoArchive(olderThanDays: settingsStore.settings.autoArchiveDays)
        router.onAsk = { [weak self] text in self?.quickAsk(text) }
        router.onNew = { [weak self] in
            guard let self else { return }
            let id = self.newConversation()
            self.router.path = [.chat(id)]
        }
    }

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    func newConversation(persona: Persona? = nil) -> UUID {
        let c = conversations.create(persona: persona)
        return c.id
    }

    /// 一步提问：创建对话并立即发送
    func quickAsk(_ text: String, images: [ImageAttachment] = []) {
        let id = newConversation()
        router.path = [.chat(id)]
        engine.send(text, images: images, to: id)
    }

    #if DEBUG
    /// 调试：通过启动参数驱动界面，例如 -WAIRoute qa  -WAIAsk "你好"  -WAIChat 0
    func applyDebugLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            if let i = args.firstIndex(of: "-" + key), i + 1 < args.count { return args[i + 1] }
            return env[key] ?? UserDefaults.standard.string(forKey: key)
        }
        NSLog("[WatchAI] launch args: %@ env: %@", args.dropFirst().joined(separator: " "), env["WAIAsk"] ?? "-")
        if let route = value("WAIRoute"), let url = URL(string: "watchai://" + route) {
            router.handleDeepLink(url)
        }
        if let index = value("WAIChat").flatMap(Int.init) {
            let list = conversations.active.filter { $0.messageCount > 0 }
            if index < list.count { router.path = [.chat(list[index].id)] }
        }
        if let path = value("WAIImage"), let data = FileManager.default.contents(atPath: path),
           let img = AttachmentStore.importImage(data: data, maxDimension: settings.imageMaxDimension, quality: settings.imageQuality) {
            quickAsk(value("WAIAsk") ?? "", images: [img])
            return
        }
        if let q = value("WAIAsk"), !q.isEmpty {
            quickAsk(q)
        }
        if let w = value("WAIWeb"), let url = URL(string: w) {
            router.web = WebItem(source: .url(url))
        }
        if let index = value("WAIReflect").flatMap(Int.init) {
            let list = conversations.active.filter { $0.messageCount > 0 }
            if index < list.count {
                let id = list[index].id
                router.path = [.memory]
                Task { _ = try? await engine.reflect(id, manual: true) }
            }
        }
    }
    #endif

    func flush() {
        conversations.saveNow(including: Array(engine.phases.keys))
        usage.saveNow()
        FileStore.flush()
    }
}
