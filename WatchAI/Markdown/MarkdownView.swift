import SwiftUI

struct MarkdownView: View {
    let blocks: [MDBlock]
    var compact: Bool = false

    init(_ text: String, streaming: Bool = false, compact: Bool = false) {
        self.blocks = streaming ? MarkdownParser.parse(text) : MarkdownParser.parseCached(text)
        self.compact = compact
    }

    init(blocks: [MDBlock], compact: Bool = false) {
        self.blocks = blocks
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MDBlockView(block: block, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MDBlockView: View {
    let block: MDBlock
    var compact: Bool

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(InlineRenderer.render(text))
                .font(headingFont(level))
                .foregroundStyle(level <= 2 ? .primary : .secondary)
                .padding(.top, level <= 2 ? 3 : 1)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(InlineRenderer.render(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .code(lang, code, closed):
            CodeBlockView(lang: lang, code: code, closed: closed, compact: compact)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Palette.quoteBar)
                    .frame(width: 3)
                MarkdownView(blocks: inner, compact: true)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ListItemRow(item: item)
                }
            }
        case let .table(header, aligns, rows):
            TableBlockView(header: header, aligns: aligns, rows: rows)
        case .rule:
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1).padding(.vertical, 2)
        case let .image(alt, url):
            MarkdownImageView(alt: alt, url: url)
        case .math(let tex):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(LaTeX.toUnicode(tex))
                    .font(.system(.footnote, design: .serif))
                    .italic()
                    .fixedSize()
                    .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.codeBackground))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        case 3: return .subheadline.bold()
        default: return .footnote.bold()
        }
    }
}

struct ListItemRow: View {
    let item: MDListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            marker
                .frame(minWidth: item.ordered ? 16 : 9, alignment: .trailing)
            Text(InlineRenderer.render(item.text))
                .strikethrough(item.checked == true, color: .secondary)
                .foregroundStyle(item.checked == true ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.level) * 10)
    }

    @ViewBuilder
    private var marker: some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.caption2)
                .foregroundStyle(checked ? .green : .secondary)
        } else if item.ordered {
            Text("\(item.number).")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text(["•", "◦", "▪︎"][min(item.level, 2)])
                .foregroundStyle(.secondary)
        }
    }
}

struct TableBlockView: View {
    let header: [String]
    let aligns: [MDAlign]
    let rows: [[String]]
    @State private var asCards = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if asCards {
                cards
            } else {
                grid
            }
            Button {
                withAnimation { asCards.toggle() }
            } label: {
                Label(asCards ? "表格视图" : "卡片视图", systemImage: asCards ? "tablecells" : "rectangle.grid.1x2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func align(_ i: Int) -> Alignment {
        guard i < aligns.count else { return .leading }
        switch aligns[i] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { i, h in
                        cell(h, bold: true, index: i)
                            .background(Palette.tableHeader)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, c in
                            cell(c, bold: false, index: i)
                                .background(r % 2 == 1 ? Color.white.opacity(0.04) : Color.clear)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.tableBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cell(_ text: String, bold: Bool, index: Int) -> some View {
        Text(InlineRenderer.render(text))
            .font(bold ? .caption.bold() : .caption)
            .frame(minWidth: 44, maxWidth: 150, alignment: align(index))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .border(Palette.tableBorder.opacity(0.5), width: 0.5)
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, c in
                        if i == 0 {
                            Text(InlineRenderer.render(c)).font(.footnote.bold())
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(i < header.count ? header[i] : "").font(.caption2).foregroundStyle(.secondary)
                                Text(InlineRenderer.render(c)).font(.caption)
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
            }
        }
    }
}

struct MarkdownImageView: View {
    let alt: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let u = URL(string: url), u.scheme?.hasPrefix("http") == true {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                    case .failure:
                        Label(alt.isEmpty ? "图片加载失败" : alt, systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
                    default:
                        ProgressView().frame(height: 40)
                    }
                }
            } else if url.hasPrefix("data:image"), let comma = url.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                      let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Label(alt.isEmpty ? url : alt, systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
            }
            if !alt.isEmpty {
                Text(alt).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
