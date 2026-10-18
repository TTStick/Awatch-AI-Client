import SwiftUI

struct CodeBlockView: View {
    let lang: String
    let code: String
    var closed: Bool = true
    var compact: Bool = false
    @State private var expanded = false

    private let collapsedLines = 14

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }

    private var displayLang: String {
        lang.isEmpty ? "code" : lang.lowercased()
    }

    var previewKind: CodePreviewKind? { CodePreviewKind(lang: lang) }

    var body: some View {
        let lineCount = lines.count
        let needsCollapse = lineCount > collapsedLines && closed
        let shown = needsCollapse && !expanded ? lines.prefix(collapsedLines).joined(separator: "\n") : code

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(displayLang)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !closed {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                }
                Spacer(minLength: 0)
                if let kind = previewKind, closed {
                    NavigationLink {
                        CodePreviewView(kind: kind, code: code)
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.link)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    CodeDetailView(lang: lang, code: code)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(shown, lang: lang))
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(7)
            }

            if needsCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        Text(expanded ? "收起" : "展开全部 \(lineCount) 行")
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.link)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.04))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.codeBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

enum CodePreviewKind {
    case html, markdown, svg, json

    init?(lang: String) {
        switch lang.lowercased() {
        case "html", "htm", "xhtml": self = .html
        case "markdown", "md": self = .markdown
        case "svg": self = .svg
        case "json": self = .json
        default: return nil
        }
    }
}

/// 全屏代码查看：支持换行切换与字号调节
struct CodeDetailView: View {
    let lang: String
    let code: String
    @State private var wrap = false
    @State private var fontSize: CGFloat = 12
    @State private var showLineNumbers = true

    private var numbered: String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let width = String(lines.count).count
        return lines.enumerated().map { i, l in
            String(repeating: " ", count: width - String(i + 1).count) + "\(i + 1)│" + l
        }.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { fontSize = max(9, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { fontSize = min(18, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                    Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
                    Button { showLineNumbers.toggle() } label: { Image(systemName: "list.number") }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.caption)

                Group {
                    let text = SyntaxHighlighter.highlight(showLineNumbers ? numbered : code, lang: lang)
                    if wrap {
                        Text(text)
                            .font(.system(size: fontSize, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(text)
                                .font(.system(size: fontSize, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.codeBackground))

                ShareLink(item: code) {
                    Label("分享代码", systemImage: "square.and.arrow.up")
                }
                Text("\(code.split(separator: "\n", omittingEmptySubsequences: false).count) 行 · \(code.count) 字符")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(lang.isEmpty ? "代码" : lang)
    }
}

/// 在本地渲染 AI 生成的 HTML / Markdown / JSON
struct CodePreviewView: View {
    let kind: CodePreviewKind
    let code: String

    var body: some View {
        switch kind {
        case .html, .svg:
            WebReaderView(source: .html(code, base: nil))
        case .markdown:
            ScrollView { MarkdownView(code).padding(.horizontal, 2) }
                .navigationTitle("预览")
        case .json:
            ScrollView {
                Text(SyntaxHighlighter.highlight(Self.prettyJSON(code), lang: "json"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("JSON")
        }
    }

    static func prettyJSON(_ s: String) -> String {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: p, encoding: .utf8) else { return s }
        return str
    }
}
