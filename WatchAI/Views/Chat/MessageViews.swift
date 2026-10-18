import SwiftUI

// MARK: - 用户消息

struct UserBubble: View, Equatable {
    static func == (a: UserBubble, b: UserBubble) -> Bool {
        a.message == b.message && a.outOfContext == b.outOfContext
    }

    let message: ChatMessage
    var outOfContext: Bool = false
    var onActions: () -> Void
    @State private var expanded = false
    @State private var viewing: ImageAttachment?

    private var isLong: Bool { message.content.count > 280 }

    var body: some View {
        HStack {
            Spacer(minLength: 18)
            VStack(alignment: .trailing, spacing: 4) {
                if !message.images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.images) { img in
                            AttachmentThumb(attachment: img, size: message.images.count == 1 ? 96 : 54)
                                .onTapGesture { viewing = img }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(InlineRenderer.render(isLong && !expanded ? String(message.content.prefix(260)) + "…" : message.content))
                        .font(.body)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLong {
                        Button(expanded ? "收起" : "展开全文") { withAnimation { expanded.toggle() } }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.userBubble))
                .contentShape(Rectangle())
                .onTapGesture { onActions() }
                HStack(spacing: 3) {
                    if message.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if message.excludedFromContext { Image(systemName: "eye.slash") }
                    else if outOfContext { Image(systemName: "scissors") }
                    Text(Fmt.relative(message.createdAt))
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
        .opacity(message.excludedFromContext || outOfContext ? 0.55 : 1)
        .sheet(item: $viewing) { ImageViewer(attachment: $0) }
    }
}

// MARK: - 助手消息

struct AssistantMessageView: View, Equatable {
    static func == (a: AssistantMessageView, b: AssistantMessageView) -> Bool {
        a.message == b.message && a.outOfContext == b.outOfContext && a.conversationID == b.conversationID
    }

    let message: ChatMessage
    let conversationID: UUID
    var outOfContext: Bool = false
    var onActions: () -> Void
    @Environment(AppModel.self) private var app

    private var isStreaming: Bool { message.status == .streaming }

    var body: some View {
        let settings = app.settings
        // 仅包含工具调用的中间消息只显示思考
        let toolOnly = message.content.isEmpty && !message.toolCalls.isEmpty
        VStack(alignment: .leading, spacing: 5) {
            if let r = message.reasoning, !r.isEmpty, settings.reasoningDisplay != .hidden {
                ReasoningView(text: r, live: isStreaming && message.content.isEmpty,
                              defaultExpanded: settings.reasoningDisplay == .expanded)
            }
            if !message.content.isEmpty {
                MarkdownView(message.content, streaming: isStreaming)
            }
            if let err = message.errorText {
                VStack(alignment: .leading, spacing: 4) {
                    Label(err, systemImage: message.status == .error ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption2)
                        .foregroundStyle(message.status == .error ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if message.status == .error {
                        HStack {
                            Button {
                                app.engine.regenerate(conversationID, from: message.id)
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise")
                            }
                            if err.contains("API") || err.contains("模型") || err.contains("Key") {
                                NavigationLink(value: Route.providers) { Image(systemName: "key") }
                            }
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(message.status == .error ? 0.12 : 0.06)))
            }
            if message.status == .interrupted {
                Label("已停止生成", systemImage: "stop.circle").font(.caption2).foregroundStyle(.secondary)
            }
            if message.status == .complete, !message.content.isEmpty {
                let links = MarkdownParser.extractLinks(message.content, limit: 4)
                if !links.isEmpty { LinkChips(links: links) }
            }
            if !toolOnly, !isStreaming, app.settings.showMessageMeta || message.isFavorite {
                metaRow
            }
        }
        .opacity(message.excludedFromContext || outOfContext ? 0.55 : 1)
        .onLongPressGesture(minimumDuration: 0.45) { onActions() }
    }

    private var metaRow: some View {
        HStack(spacing: 4) {
            if message.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            if message.excludedFromContext { Image(systemName: "eye.slash") }
            if app.settings.showMessageMeta {
                if let m = message.modelName { Text(m).lineLimit(1) }
                if let u = message.usage {
                    Text("·\(TokenEstimator.format(u.totalTokens))\(u.estimated ? "≈" : "")")
                    if u.cost > 0 { Text("·" + Fmt.money(u.cost, u.currency)) }
                }
                if let d = message.duration { Text("·" + Fmt.seconds(d)) }
            }
            Spacer(minLength: 0)
            Button(action: onActions) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 20)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }
}

struct ReasoningView: View {
    let text: String
    let live: Bool
    let defaultExpanded: Bool
    @State private var expanded: Bool?

    var body: some View {
        let isOpen = expanded ?? defaultExpanded
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = !isOpen }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: live ? "brain" : "brain.head.profile")
                        .symbolEffect(.pulse, isActive: live)
                    Text(live ? "思考中…" : "思考过程")
                    Text("\(text.count) 字").foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                }
                .font(.caption2)
                .foregroundStyle(Palette.reasoning)
            }
            .buttonStyle(.plain)
            if isOpen {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(Palette.reasoning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if live {
                // 实时显示最后两行思考
                Text(lastLines)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.reasoning.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private var lastLines: String {
        let lines = text.split(separator: "\n").suffix(2).joined(separator: " ")
        return String(lines.suffix(120))
    }
}

struct LinkChips: View {
    let links: [(title: String, url: URL)]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Button {
                    openURL(link.url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        Text(link.title).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(link.url.host ?? "").foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.link)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.link.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 工具结果

struct ToolResultRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        let ok = message.status != .error
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: ToolRegistry.symbol(message.toolName ?? ""))
                        .foregroundStyle(ok ? .green : .orange)
                        .frame(width: 16)
                    Text(message.displayText ?? ToolRegistry.displayName(message.toolName ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(expanded ? nil : 2)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(CodePreviewView.prettyJSON(message.content))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(30)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(ok ? Palette.toolCard : Color.orange.opacity(0.15)))
    }
}

struct ContextDividerRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.teal.opacity(0.5)).frame(height: 1)
            Text("上下文已清除").font(.system(size: 10)).foregroundStyle(.teal).fixedSize()
            Rectangle().fill(Color.teal.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 图片

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for a: ImageAttachment) -> UIImage? {
        let key = a.fileName as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let img = AttachmentStore.image(for: a) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

struct AttachmentThumb: View {
    let attachment: ImageAttachment
    var size: CGFloat = 54

    var body: some View {
        Group {
            if let img = ThumbCache.shared.image(for: attachment) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ImageViewer: View {
    let attachment: ImageAttachment
    @State private var scale: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let img = ThumbCache.shared.image(for: attachment) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(DragGesture()
                        .onChanged { v in offset = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height) }
                        .onEnded { _ in dragStart = offset })
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5; offset = .zero; dragStart = .zero }
                    }
            }
        }
        .focusable()
        .digitalCrownRotation($scale, from: 1, through: 5, by: 0.1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .overlay(alignment: .bottom) {
            Text("\(attachment.width)×\(attachment.height) · \(Fmt.bytes(Int64(attachment.byteSize)))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(3)
                .background(Capsule().fill(.black.opacity(0.5)))
        }
        .ignoresSafeArea()
    }
}

// MARK: - 消息操作

enum MessageAction {
    case favorite, speak, regenerate, edit, toggleContext, branch, delete, clearContextHere
}

struct MessageActionsView: View {
    let conversationID: UUID
    let message: ChatMessage
    let onAction: (MessageAction) -> Void
    @Environment(AppModel.self) private var app
    @State private var confirmDelete = false

    var body: some View {
        let generating = app.engine.isGenerating(conversationID)
        List {
            if message.role != .divider {
                Section {
                    Button { onAction(.favorite) } label: {
                        Label(message.isFavorite ? "取消收藏" : "收藏", systemImage: message.isFavorite ? "star.slash" : "star")
                    }
                    if !message.content.isEmpty {
                        Button { onAction(.speak) } label: {
                            Label(SpeechService.shared.speakingID == message.id ? "停止朗读" : "朗读", systemImage: "speaker.wave.2")
                        }
                        ShareLink(item: message.content) { Label("分享 / 发送", systemImage: "square.and.arrow.up") }
                        NavigationLink {
                            MessageDetailView(conversationID: conversationID, message: message)
                        } label: {
                            Label("全屏阅读 / 详情", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
                Section {
                    if message.role == .assistant {
                        Button { onAction(.regenerate) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                            .disabled(generating)
                    }
                    if message.role == .user {
                        Button { onAction(.edit) } label: { Label("编辑并重发", systemImage: "pencil") }
                            .disabled(generating)
                    }
                    Button { onAction(.toggleContext) } label: {
                        Label(message.excludedFromContext ? "加入上下文" : "从上下文排除", systemImage: message.excludedFromContext ? "eye" : "eye.slash")
                    }
                    Button { onAction(.branch) } label: { Label("从这里分叉新对话", systemImage: "arrow.triangle.branch") }
                    Button { onAction(.clearContextHere) } label: { Label("在末尾清除上下文", systemImage: "scissors") }
                        .disabled(generating)
                }
            }
            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
            }
        }
        .confirmationDialog("删除这条消息？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { onAction(.delete) }
        }
    }
}

/// 在当前导航栈内用阅读模式打开网页链接
struct InlineWebLinks: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var target: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if app.router.systemBypass.remove(url) != nil { return .systemAction }
                if let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                    target = url
                    return .handled
                }
                return .systemAction
            })
            .navigationDestination(item: $target) { url in
                WebReaderView(source: .url(url))
            }
    }
}

struct MessageDetailView: View {
    let conversationID: UUID
    let message: ChatMessage
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if message.role == .user {
                    Text(message.content).fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownView(message.content)
                }
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    row("时间", Fmt.dateTime(message.createdAt))
                    if let m = message.modelName { row("模型", m) }
                    if let u = message.usage {
                        row("输入", "\(u.promptTokens) tokens\(u.cachedTokens > 0 ? "（缓存 \(u.cachedTokens)）" : "")")
                        row("输出", "\(u.completionTokens) tokens\(u.reasoningTokens > 0 ? "（思考 \(u.reasoningTokens)）" : "")")
                        row("费用", Fmt.money(u.cost, u.currency) + (u.estimated ? "（估算）" : ""))
                    }
                    if let f = message.firstTokenLatency { row("首字延迟", Fmt.seconds(f)) }
                    if let d = message.duration { row("总耗时", Fmt.seconds(d)) }
                    row("字数", "\(message.content.count)")
                }
                .font(.caption2)
            }
        }
        .navigationTitle(message.role == .user ? "提问" : "回答")
        .modifier(InlineWebLinks())
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(v)
        }
    }
}
