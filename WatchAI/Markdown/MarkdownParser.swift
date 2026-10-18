import Foundation

enum MDAlign: Hashable {
    case left, center, right
}

struct MDListItem: Hashable {
    var level: Int
    var ordered: Bool
    var number: Int
    var checked: Bool?
    var text: String
}

indirect enum MDBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String, code: String, closed: Bool)
    case quote([MDBlock])
    case list([MDListItem])
    case table(header: [String], aligns: [MDAlign], rows: [[String]])
    case rule
    case image(alt: String, url: String)
    case math(String)
}

/// 轻量 Markdown 块级解析器（面向 LLM 输出）
enum MarkdownParser {
    private final class Box { let blocks: [MDBlock]; init(_ b: [MDBlock]) { blocks = b } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 200
        return c
    }()

    static func parseCached(_ text: String) -> [MDBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var p = Parser(lines: lines)
        return p.parseBlocks()
    }

    private struct Parser {
        let lines: [String]
        var i = 0
        var blocks: [MDBlock] = []
        var para: [String] = []

        init(lines: [String]) { self.lines = lines }

        mutating func flushPara() {
            guard !para.isEmpty else { return }
            let text = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            para = []
        }

        mutating func parseBlocks() -> [MDBlock] {
            while i < lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // 代码块
                if let fence = MarkdownParser.fenceStart(trimmed) {
                    flushPara()
                    let indent = MarkdownParser.indentWidth(line)
                    var code: [String] = []
                    var closed = false
                    i += 1
                    while i < lines.count {
                        let l = lines[i]
                        let t = l.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix(fence.marker) && t.trimmingCharacters(in: CharacterSet(charactersIn: String(fence.marker.first!))).isEmpty {
                            closed = true
                            i += 1
                            break
                        }
                        code.append(MarkdownParser.dropIndent(l, indent))
                        i += 1
                    }
                    blocks.append(.code(lang: fence.lang, code: code.joined(separator: "\n"), closed: closed))
                    continue
                }

                // 公式块
                if trimmed.hasPrefix("$$") || trimmed == "\\[" {
                    flushPara()
                    let closer = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                    var body = trimmed.hasPrefix("$$") ? String(trimmed.dropFirst(2)) : ""
                    if closer == "$$", body.hasSuffix("$$"), body.count >= 2 {
                        blocks.append(.math(String(body.dropLast(2)).trimmingCharacters(in: .whitespaces)))
                        i += 1
                        continue
                    }
                    i += 1
                    var parts: [String] = body.isEmpty ? [] : [body]
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.hasSuffix(closer) {
                            let rest = String(t.dropLast(closer.count))
                            if !rest.isEmpty { parts.append(rest) }
                            i += 1
                            break
                        }
                        parts.append(t)
                        i += 1
                    }
                    body = parts.joined(separator: "\n")
                    blocks.append(.math(body))
                    continue
                }

                if trimmed.isEmpty {
                    flushPara()
                    i += 1
                    continue
                }

                // 标题
                if let h = MarkdownParser.heading(trimmed) {
                    flushPara()
                    blocks.append(.heading(level: h.0, text: h.1))
                    i += 1
                    continue
                }

                // Setext 标题 / 分隔线
                if !para.isEmpty, trimmed.allSatisfy({ $0 == "=" }) && trimmed.count >= 2 {
                    let text = para.joined(separator: " ")
                    para = []
                    blocks.append(.heading(level: 1, text: text))
                    i += 1
                    continue
                }
                if MarkdownParser.isRule(trimmed) {
                    if !para.isEmpty && trimmed.allSatisfy({ $0 == "-" }) {
                        let text = para.joined(separator: " ")
                        para = []
                        blocks.append(.heading(level: 2, text: text))
                    } else {
                        flushPara()
                        blocks.append(.rule)
                    }
                    i += 1
                    continue
                }

                // 表格
                if trimmed.contains("|"), i + 1 < lines.count, MarkdownParser.isTableSeparator(lines[i + 1]) {
                    flushPara()
                    let header = MarkdownParser.splitRow(trimmed)
                    let aligns = MarkdownParser.splitRow(lines[i + 1]).map { cell -> MDAlign in
                        let c = cell.trimmingCharacters(in: .whitespaces)
                        if c.hasPrefix(":") && c.hasSuffix(":") { return .center }
                        if c.hasSuffix(":") { return .right }
                        return .left
                    }
                    i += 2
                    var rows: [[String]] = []
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || !t.contains("|") { break }
                        var row = MarkdownParser.splitRow(t)
                        if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                        rows.append(Array(row.prefix(max(header.count, 1))))
                        i += 1
                    }
                    blocks.append(.table(header: header, aligns: aligns, rows: rows))
                    continue
                }

                // 引用
                if trimmed.hasPrefix(">") {
                    flushPara()
                    var inner: [String] = []
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        guard t.hasPrefix(">") else { break }
                        var rest = String(t.dropFirst())
                        if rest.hasPrefix(" ") { rest.removeFirst() }
                        inner.append(rest)
                        i += 1
                    }
                    blocks.append(.quote(MarkdownParser.parse(inner.joined(separator: "\n"))))
                    continue
                }

                // 列表
                if MarkdownParser.listMarker(line) != nil {
                    flushPara()
                    blocks.append(.list(parseList()))
                    continue
                }

                // 独立图片
                if let img = MarkdownParser.standaloneImage(trimmed) {
                    flushPara()
                    blocks.append(.image(alt: img.0, url: img.1))
                    i += 1
                    continue
                }

                para.append(line.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            flushPara()
            return blocks
        }

        mutating func parseList() -> [MDListItem] {
            var items: [MDListItem] = []
            var indentStack: [Int] = []
            func level(for indent: Int) -> Int {
                while let last = indentStack.last, indent < last { indentStack.removeLast() }
                if indentStack.isEmpty || indent > (indentStack.last ?? 0) + 1 { indentStack.append(indent) }
                return max(0, indentStack.count - 1)
            }
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if let m = MarkdownParser.listMarker(l) {
                    var text = m.content
                    var checked: Bool?
                    if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { checked = true; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    items.append(MDListItem(level: level(for: m.indent), ordered: m.ordered, number: m.number, checked: checked, text: text))
                    i += 1
                } else if t.isEmpty {
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, MarkdownParser.listMarker(lines[j]) != nil {
                        i = j
                        continue
                    }
                    if j < lines.count, MarkdownParser.indentWidth(lines[j]) >= 2,
                       MarkdownParser.fenceStart(lines[j].trimmingCharacters(in: .whitespaces)) == nil, !items.isEmpty {
                        items[items.count - 1].text += "\n" + lines[j].trimmingCharacters(in: .whitespaces)
                        i = j + 1
                        continue
                    }
                    break
                } else if MarkdownParser.indentWidth(l) >= 2, !items.isEmpty {
                    if MarkdownParser.fenceStart(t) != nil || MarkdownParser.isTableSeparator(lines[min(i + 1, lines.count - 1)]) { break }
                    items[items.count - 1].text += "\n" + t
                    i += 1
                } else if !items.isEmpty, !MarkdownParser.isBlockStart(t), i > 0, !lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    // 惰性续行
                    items[items.count - 1].text += "\n" + t
                    i += 1
                } else {
                    break
                }
            }
            return items
        }
    }

    // MARK: - 辅助

    static func indentWidth(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func dropIndent(_ line: String, _ n: Int) -> String {
        guard n > 0 else { return line }
        var count = 0
        var idx = line.startIndex
        while idx < line.endIndex, count < n, line[idx] == " " {
            idx = line.index(after: idx)
            count += 1
        }
        return String(line[idx...])
    }

    static func fenceStart(_ trimmed: String) -> (marker: String, lang: String)? {
        for ch in ["`", "~"] {
            let three = String(repeating: ch, count: 3)
            if trimmed.hasPrefix(three) {
                var count = 0
                for c in trimmed { if String(c) == ch { count += 1 } else { break } }
                let marker = String(repeating: ch, count: count)
                let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                if ch == "`" && info.contains("`") { return nil }
                let lang = info.split(separator: " ").first.map(String.init) ?? ""
                return (marker, lang)
            }
        }
        return nil
    }

    static func heading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for c in trimmed { if c == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let s = trimmed.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let f = s.first, "-*_".contains(f) else { return false }
        return s.allSatisfy { $0 == f }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        let cells = splitRow(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            return c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
        }
    }

    static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var prev: Character = " "
        var inCode = false
        for ch in t {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && prev != "\\" && !inCode {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                if ch == "|" && prev == "\\" { cur.removeLast() }
                cur.append(ch)
            }
            prev = ch
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, number: Int, content: String)? {
        let indent = indentWidth(line)
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return nil }
        if "-*+•".contains(f) {
            let rest = t.dropFirst()
            guard rest.hasPrefix(" ") else { return nil }
            if isRule(t) { return nil }
            return (indent, false, 0, rest.trimmingCharacters(in: .whitespaces))
        }
        if f.isNumber {
            var digits = ""
            var idx = t.startIndex
            while idx < t.endIndex, t[idx].isNumber, digits.count < 9 {
                digits.append(t[idx])
                idx = t.index(after: idx)
            }
            guard idx < t.endIndex, t[idx] == "." || t[idx] == ")" || t[idx] == "、" else { return nil }
            let after = t[t.index(after: idx)...]
            guard after.hasPrefix(" ") || (t[idx] == "、" && !after.isEmpty) else { return nil }
            return (indent, true, Int(digits) ?? 1, after.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func isBlockStart(_ trimmed: String) -> Bool {
        heading(trimmed) != nil || fenceStart(trimmed) != nil || trimmed.hasPrefix(">") || isRule(trimmed) || trimmed.hasPrefix("$$")
    }

    static func standaloneImage(_ trimmed: String) -> (String, String)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let close = trimmed.range(of: "]("), close.lowerBound > trimmed.index(trimmed.startIndex, offsetBy: 1) else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
        var url = String(trimmed[close.upperBound..<trimmed.index(before: trimmed.endIndex)])
        if let sp = url.firstIndex(of: " ") { url = String(url[..<sp]) }
        guard !url.isEmpty, !alt.contains("]") else { return nil }
        return (alt, url)
    }

    /// 提取文本中的所有链接（用于小屏链接列表）
    static func extractLinks(_ text: String, limit: Int = 6) -> [(title: String, url: URL)] {
        var out: [(String, URL)] = []
        var seen = Set<String>()
        let mdLink = try? NSRegularExpression(pattern: "(?<!!)\\[([^\\]\\n]{1,80})\\]\\((https?://[^)\\s]+)\\)")
        let ns = text as NSString
        mdLink?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, out.count < limit else { return }
            let title = ns.substring(with: m.range(at: 1))
            let u = ns.substring(with: m.range(at: 2))
            if !seen.contains(u), let url = URL(string: u) {
                seen.insert(u)
                out.append((title, url))
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, let url = m.url, out.count < limit else { return }
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
                let key = url.absoluteString
                if !seen.contains(key) && !seen.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) }) {
                    seen.insert(key)
                    out.append((url.host ?? key, url))
                }
            }
        }
        return out
    }
}
