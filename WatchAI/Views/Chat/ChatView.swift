import SwiftUI
import PhotosUI

struct ChatView: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app
    @State private var pendingImages: [ImageAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var actionTarget: ChatMessage?
    @State private var editTarget: ChatMessage?
    @State private var showOptions = false
    @State private var showOutline = false
    @State private var showQuickPrompts = false
    @State private var showSummary = false
    @State private var scrollTarget: UUID?

    private var conversation: Conversation? { app.conversations.conversation(conversationID) }
    private var settings: AppSettings { app.settings }

    var body: some View {
        let messages = app.conversations.messages(conversationID)
        let phase = app.engine.phases[conversationID]
        let generating = phase != nil
        // 生成过程中跳过上下文估算，减少每次刷新的开销
        let estimate = generating ? nil : conversation.map { ContextBuilder.quickEstimate(conversation: $0, history: messages, settings: settings) }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        EmptyChatView(conversation: conversation) { send($0) }
                    }
                    ForEach(messages) { m in
                        messageRow(m, estimate: estimate)
                            .id(m.id)
                        if m.id == conversation?.contextSummaryUntil, conversation?.contextSummary != nil,
                           estimate?.usesSummary == true {
                            summaryMarker
                        }
                    }
                    if let phase, shouldShowPhase(messages) {
                        PhaseIndicator(phase: phase).padding(.leading, 2)
                    }
                    footer(messages: messages, generating: generating, estimate: estimate)
                        .id("footer")
                    Color.clear.frame(height: 44)
                }
                .padding(.horizontal, 1)
            }
            .modifier(InitialBottomAnchor())
            .onAppear {
                if generating, settings.scrollBehavior == .toQuestion, let q = messages.last(where: { $0.role == .user }) {
                    // 从首页直接提问进入：定位到问题，便于从头阅读回答
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        proxy.scrollTo(q.id, anchor: .top)
                    }
                } else if #unavailable(watchOS 11.0) {
                    proxy.scrollTo("footer", anchor: .bottom)
                }
                #if DEBUG
                if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-WAIScroll"), i + 1 < ProcessInfo.processInfo.arguments.count {
                    let v = ProcessInfo.processInfo.arguments[i + 1]
                    let target: UUID? = v == "top" ? messages.first?.id : Int(v).flatMap { $0 < messages.count ? messages[$0].id : nil }
                    if let target { scrollTarget = target }
                }
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-WAIOptions") { showOptions = true }
                if args.contains("-WAIOutline") { showOutline = true }
                if args.contains("-WAIActions") { actionTarget = messages.last(where: { $0.role == .assistant }) }
                if let i = args.firstIndex(of: "-WAISend"), i + 1 < args.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { send(args[i + 1]) }
                }
                #endif
            }
            .onChange(of: messages.count) { old, new in
                guard new > old, let last = messages.last else { return }
                if last.role == .user {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation { proxy.scrollTo(last.id, anchor: settings.scrollBehavior == .toQuestion ? .top : .bottom) }
                    }
                } else if settings.scrollBehavior == .follow {
                    withAnimation { proxy.scrollTo("footer", anchor: .bottom) }
                }
            }
            .onChange(of: messages.last?.content.count ?? 0) { _, _ in
                guard settings.scrollBehavior == .follow, generating else { return }
                proxy.scrollTo("footer", anchor: .bottom)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
        }
        .navigationTitle(conversation?.title ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showOptions = true } label: { Image(systemName: "ellipsis") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { showOutline = true } label: { Image(systemName: "list.bullet.indent") }
                    .disabled(messages.isEmpty)
                inputButton(generating: generating)
                PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: importing ? "hourglass" : "photo.badge.plus")
                }
            }
        }
        .modifier(FontScaleModifier(scale: settings.fontScale))
        .modifier(InlineWebLinks())
        .sheet(item: $actionTarget) { m in
            NavigationStack {
                MessageActionsView(conversationID: conversationID, message: m) { action in
                    handle(action, m)
                }
            }
        }
        .sheet(item: $editTarget) { m in
            EditMessageSheet(original: m.content) { text in
                app.engine.resend(conversationID, userMessageID: m.id, newText: text)
            }
        }
        .sheet(isPresented: $showOptions) {
            ChatOptionsView(conversationID: conversationID) { target in
                showOptions = false
                scrollTarget = target
            }
        }
        .sheet(isPresented: $showOutline) {
            OutlineSheet(conversationID: conversationID) { target in
                showOutline = false
                scrollTarget = target
            }
        }
        .sheet(isPresented: $showQuickPrompts) {
            QuickPromptSheet { text in
                showQuickPrompts = false
                send(text)
            }
        }
        .sheet(isPresented: $showSummary) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Label("上下文摘要", systemImage: "archivebox").font(.headline)
                    MarkdownView(conversation?.contextSummary ?? "")
                    Button("取消压缩（恢复完整上下文）", role: .destructive) {
                        app.engine.clearContextSummary(conversationID)
                        showSummary = false
                    }
                    .font(.footnote)
                }
            }
        }
        .onAppear {
            if let imgs = app.pendingImages.removeValue(forKey: conversationID) {
                pendingImages += imgs
            }
        }
        .onDisappear {
            // 仅在返回（出栈）时清理空对话并触发反思；进入子页面时保留
            guard !app.router.path.contains(.chat(conversationID)) else { return }
            if pendingImages.isEmpty { app.conversations.discardIfEmpty(conversationID) }
            app.engine.maybeAutoReflect(conversationID)
            if SpeechService.shared.isSpeaking { SpeechService.shared.stop() }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                let imgs = await ImageImporter.load(items, settings: settings)
                pendingImages += imgs
                photoItems = []
                importing = false
            }
        }
    }

    // MARK: - 输入

    @ViewBuilder
    private func inputButton(generating: Bool) -> some View {
        if generating {
            Button {
                app.engine.stop(conversationID)
            } label: {
                Image(systemName: "stop.fill").foregroundStyle(.red)
            }
        } else {
            let link = TextFieldLink(prompt: Text(pendingImages.isEmpty ? "输入消息" : "描述图片或直接发送")) {
                Image(systemName: "mic.fill")
            } onSubmit: { text in
                send(text)
            }
            if #available(watchOS 11.0, *) {
                link.handGestureShortcut(.primaryAction)
            } else {
                link
            }
        }
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !pendingImages.isEmpty else { return }
        app.engine.send(t, images: pendingImages, to: conversationID)
        pendingImages = []
    }

    private func shouldShowPhase(_ messages: [ChatMessage]) -> Bool {
        guard let last = messages.last else { return true }
        if last.role == .assistant && last.status == .streaming {
            return last.content.isEmpty && (last.reasoning ?? "").isEmpty
        }
        return true
    }

    // MARK: - 行

    @ViewBuilder
    private func messageRow(_ m: ChatMessage, estimate: ContextBuilder.Estimate?) -> some View {
        let outOfContext = !(estimate?.includedIDs.contains(m.id) ?? true) && m.status != .streaming
        switch m.role {
        case .user:
            UserBubble(message: m, outOfContext: outOfContext) { actionTarget = m }
                .equatable()
        case .assistant:
            AssistantMessageView(message: m, conversationID: conversationID, outOfContext: outOfContext) {
                actionTarget = m
            }
            .equatable()
        case .tool:
            ToolResultRow(message: m)
        case .divider:
            ContextDividerRow()
                .onLongPressGesture { actionTarget = m }
        case .system:
            EmptyView()
        }
    }

    private var summaryMarker: some View {
        Button { showSummary = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "archivebox.fill")
                Text("以上内容已压缩为摘要 · 查看")
            }
            .font(.caption2)
            .foregroundStyle(.teal)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func footer(messages: [ChatMessage], generating: Bool, estimate: ContextBuilder.Estimate?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingImages.isEmpty {
                PendingImagesStrip(images: $pendingImages)
                if let c = conversation, let resolved = app.providers.resolve(providerID: c.providerID, modelName: c.modelName, settings: settings),
                   !resolved.1.supportsVision {
                    InlineNotice(text: "当前模型「\(resolved.1.label)」不支持图片，请在 ⋯ 中切换到支持视觉的模型（如 MiniMax-M3）。",
                                 systemImage: "exclamationmark.triangle", tint: .orange)
                }
                Button {
                    send("")
                } label: {
                    Label("发送图片", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .tint(.accentColor)
                .disabled(generating)
            }

            if !generating, settings.showQuickReplies, let last = messages.last, last.role == .assistant, last.status == .complete, !last.content.isEmpty {
                QuickReplyChips(prompts: Array(settings.quickPrompts.prefix(4))) { send($0) } more: { showQuickPrompts = true }
            }

            if !messages.isEmpty, let estimate, let c = conversation {
                Button { showOptions = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                        Text("上下文 \(estimate.messages) 条 · ≈\(TokenEstimator.format(estimate.tokens))")
                        if estimate.limited { Image(systemName: "scissors") }
                        Spacer(minLength: 0)
                        if c.totalCost > 0 {
                            Text(Fmt.money(c.totalCost, c.costCurrency))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 操作

    private func handle(_ action: MessageAction, _ m: ChatMessage) {
        actionTarget = nil
        switch action {
        case .favorite:
            app.conversations.toggleFavoriteMessage(conversationID, m.id)
        case .speak:
            if SpeechService.shared.speakingID == m.id { SpeechService.shared.stop() } else { SpeechService.shared.speak(m.content, id: m.id) }
        case .regenerate:
            app.engine.regenerate(conversationID, from: m.id)
        case .edit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editTarget = m }
        case .toggleContext:
            app.conversations.updateMessage(conversationID, m.id, persist: true) { $0.excludedFromContext.toggle() }
        case .branch:
            if let c = app.conversations.branch(conversationID, upTo: m.id) {
                app.router.path.append(.chat(c.id))
            }
        case .delete:
            app.conversations.deleteMessage(conversationID, m.id)
        case .clearContextHere:
            app.engine.insertDivider(conversationID)
        }
    }
}

/// 打开对话时定位到底部，但生成过程中不强制跟随（watchOS 11+）
struct InitialBottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}

struct FontScaleModifier: ViewModifier {
    let scale: FontScale
    func body(content: Content) -> some View {
        if let size = scale.dynamicType {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}

// MARK: - 空状态

struct EmptyChatView: View {
    let conversation: Conversation?
    let onSend: (String) -> Void
    @Environment(AppModel.self) private var app

    private let starters = ["今天适合做什么？", "帮我写一段 Python 快速排序", "用表格对比 iPhone 和安卓", "5 分钟后提醒我喝水", "记一下：明天买牛奶"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = conversation, let resolved = app.providers.resolve(providerID: c.providerID, modelName: c.modelName, settings: app.settings) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text("\(resolved.0.name) · \(resolved.1.label)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if !c.systemPrompt.isEmpty {
                    Text(c.systemPrompt).font(.caption2).foregroundStyle(.tertiary).lineLimit(3)
                }
            } else {
                NavigationLink(value: Route.providers) {
                    Label("先配置 API", systemImage: "key.fill").foregroundStyle(.orange)
                }
            }
            Text("试试这样问").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(starters, id: \.self) { s in
                Button { onSend(s) } label: {
                    Text(s).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct PendingImagesStrip: View {
    @Binding var images: [ImageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { img in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumb(attachment: img, size: 54)
                        Button {
                            AttachmentStore.delete([img])
                            images.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct QuickReplyChips: View {
    let prompts: [String]
    let onTap: (String) -> Void
    var more: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(prompts, id: \.self) { p in
                    Button { onTap(p) } label: {
                        Text(p).font(.caption2).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: more) {
                    Image(systemName: "bolt.fill").font(.caption2)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct QuickPromptSheet: View {
    let onPick: (String) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section("快捷短语") {
                ForEach(app.settings.quickPrompts, id: \.self) { p in
                    Button(p) { onPick(p) }
                }
            }
            Section {
                TextFieldLink(prompt: Text("自定义")) {
                    Label("临时输入", systemImage: "keyboard")
                } onSubmit: { onPick($0) }
            }
        }
    }
}

struct EditMessageSheet: View {
    let original: String
    let onSubmit: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("编辑后将删除其后的回答并重新生成").font(.caption2).foregroundStyle(.secondary)
                TextField("内容", text: $text, axis: .vertical)
                    .lineLimit(2...8)
                Button {
                    onSubmit(text)
                    dismiss()
                } label: {
                    Label("重新发送", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { text = original }
    }
}

struct OutlineSheet: View {
    let conversationID: UUID
    let onSelect: (UUID) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let msgs = app.conversations.messages(conversationID)
        let questions = msgs.filter { $0.role == .user }
        List {
            Section("问答大纲 · \(questions.count) 问") {
                ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                    Button { onSelect(q.id) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.content).font(.footnote).lineLimit(2)
                                if let a = answer(after: q, in: msgs) {
                                    Text(ConversationStore.plainSnippet(a, limit: 50)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if let fav = msgs.filter({ $0.isFavorite }).first {
                    Button { onSelect(fav.id) } label: { Label("跳到收藏的消息", systemImage: "star.fill").foregroundStyle(.yellow) }
                }
            }
        }
    }

    private func answer(after q: ChatMessage, in msgs: [ChatMessage]) -> String? {
        guard let idx = msgs.firstIndex(where: { $0.id == q.id }) else { return nil }
        for m in msgs[(idx + 1)...] {
            if m.role == .user { return nil }
            if m.role == .assistant, !m.content.isEmpty { return m.content }
        }
        return nil
    }
}
