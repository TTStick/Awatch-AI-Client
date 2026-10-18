import SwiftUI

/// 本地阅读模式浏览器：抓取网页并原生渲染
struct WebReaderView: View {
    let source: WebSource
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var parentOpenURL
    @State private var page: WebPage?
    @State private var error: String?
    @State private var loading = true
    @State private var next: URL?
    @State private var maxBlocks = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if loading {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text(sourceLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("加载失败", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                        systemOpenButton
                    }
                } else if let page {
                    header(page)
                    let blocks = MarkdownParser.parseCached(page.markdown)
                    if blocks.isEmpty {
                        Text("页面没有可读的正文内容").font(.footnote).foregroundStyle(.secondary)
                    }
                    MarkdownView(blocks: Array(blocks.prefix(maxBlocks)))
                    if blocks.count > maxBlocks {
                        Button("继续加载（剩余 \(blocks.count - maxBlocks) 段）") { maxBlocks += 80 }
                            .font(.footnote)
                    }
                    footer(page)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle(page?.title.isEmpty == false ? page!.title : "网页")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { url in
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                next = url
                return .handled
            }
            return .systemAction
        })
        .navigationDestination(item: $next) { url in
            WebReaderView(source: .url(url))
        }
        .task { await load() }
    }

    private var sourceLabel: String {
        switch source {
        case .url(let u): return u.absoluteString
        case .html: return "正在渲染 HTML…"
        }
    }

    private var sourceURL: URL? {
        switch source {
        case .url(let u): return page?.url ?? u
        case .html(_, let base): return base
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            page = try await WebReader.load(source)
        } catch {
            self.error = ChatEngine.describe(error)
        }
        loading = false
    }

    @ViewBuilder
    private func header(_ page: WebPage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !page.title.isEmpty {
                Text(page.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let host = page.url?.host {
                Label(host, systemImage: "globe").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        Divider()
    }

    @ViewBuilder
    private func footer(_ page: WebPage) -> some View {
        Divider().padding(.top, 6)
        VStack(spacing: 6) {
            Button {
                askAI(page)
            } label: {
                Label("让 AI 总结此页", systemImage: "sparkles")
            }
            systemOpenButton
            if let url = sourceURL {
                ShareLink(item: url) { Label("分享链接", systemImage: "square.and.arrow.up") }
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var systemOpenButton: some View {
        if let url = sourceURL {
            Button {
                app.router.systemBypass.insert(url)
                parentOpenURL(url)
            } label: {
                Label("用系统网页视图打开", systemImage: "safari")
            }
        }
    }

    private func askAI(_ page: WebPage) {
        let c = app.conversations.create()
        let content = String(page.markdown.prefix(8000))
        let prompt = "请总结这个网页的要点：\(page.title)\n\(page.url?.absoluteString ?? "")\n\n---\n\(content)"
        app.conversations.update(c.id) {
            $0.title = "🌐 " + (page.title.isEmpty ? "网页总结" : String(page.title.prefix(16)))
            $0.titleGenerated = true
        }
        app.engine.send(prompt, to: c.id)
        app.router.web = nil
        app.router.path.append(.chat(c.id))
    }
}
