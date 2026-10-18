import Foundation

struct WebPage: Hashable {
    var title: String
    var url: URL?
    var markdown: String
    var siteName: String?
}

enum WebSource: Hashable {
    case url(URL)
    case html(String, base: URL?)
}

/// 在手表本地抓取并解析网页为可读的 Markdown（阅读模式）
enum WebReader {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func fetch(_ url: URL) async throws -> WebPage {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 30
        let (data, response) = try await OpenAIClient.shared.session.data(for: req)
        let http = response as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<400).contains(code) {
            throw APIError.http(code, HTTPURLResponse.localizedString(forStatusCode: code))
        }
        let finalURL = response.url ?? url
        let mime = (response.mimeType ?? "").lowercased()
        let limited = data.count > 3_000_000 ? data.prefix(3_000_000) : data
        let text = decode(Data(limited), encodingName: response.textEncodingName)

        if mime.contains("json") {
            return WebPage(title: finalURL.lastPathComponent, url: finalURL, markdown: "```json\n" + text.prefix(20000) + "\n```")
        }
        if mime.hasPrefix("text/plain") || finalURL.pathExtension.lowercased() == "md" {
            let isMarkdown = finalURL.pathExtension.lowercased() == "md"
            return WebPage(title: finalURL.lastPathComponent, url: finalURL, markdown: isMarkdown ? text : "```\n" + text.prefix(30000) + "\n```")
        }
        if mime.hasPrefix("image/") {
            return WebPage(title: finalURL.lastPathComponent, url: finalURL, markdown: "![](\(finalURL.absoluteString))")
        }
        return await Task.detached(priority: .userInitiated) {
            HTMLConverter.convert(text, baseURL: finalURL)
        }.value
    }

    static func load(_ source: WebSource) async throws -> WebPage {
        switch source {
        case .url(let u): return try await fetch(u)
        case let .html(html, base):
            return await Task.detached { HTMLConverter.convert(html, baseURL: base) }.value
        }
    }

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName ?? sniffCharset(data) {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sniffCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let r = head.range(of: "charset=") else { return nil }
        var name = ""
        for ch in head[r.upperBound...] {
            if ch == "\"" || ch == "'" { if name.isEmpty { continue } else { break } }
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { name.append(ch) } else { break }
        }
        return name.isEmpty ? nil : name
    }
}

// MARK: - HTML → Markdown

enum HTMLConverter {
    private enum Token {
        case text(String)
        case start(String, [String: String], selfClosing: Bool)
        case end(String)
    }

    private static let skipTags: Set<String> = ["script", "style", "noscript", "svg", "template", "iframe", "form",
                                                "button", "select", "nav", "footer", "aside", "canvas", "object",
                                                "video", "audio", "map", "head", "dialog", "input", "textarea"]
    private static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "header", "figure",
                                                 "figcaption", "dl", "dt", "dd", "address", "details", "summary",
                                                 "center", "hgroup", "body", "html", "caption"]
    private static let voidTags: Set<String> = ["br", "hr", "img", "meta", "link", "input", "source", "wbr", "area", "base", "col", "embed", "param", "track"]

    static func convert(_ html: String, baseURL: URL?) -> WebPage {
        let tokens = tokenize(html)
        let title = extractTitle(tokens)
        let content = selectMain(tokens)
        var w = Writer(baseURL: baseURL)
        w.run(content)
        var md = w.output()
        if md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count != tokens.count {
            var w2 = Writer(baseURL: baseURL)
            w2.run(tokens)
            md = w2.output()
        }
        return WebPage(title: title, url: baseURL, markdown: md, siteName: baseURL?.host)
    }

    // MARK: 分词

    private static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        let bytes = Array(html.utf8)
        let n = bytes.count
        var i = 0
        var textStart = 0

        func flushText(_ end: Int) {
            if end > textStart {
                let s = String(decoding: bytes[textStart..<end], as: UTF8.self)
                tokens.append(.text(s))
            }
        }
        func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        func isNameChar(_ b: UInt8) -> Bool {
            (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 45 || b == 58 || b == 95
        }
        func find(_ pattern: [UInt8], from: Int, caseInsensitive: Bool = false) -> Int? {
            guard pattern.count > 0, from < n else { return nil }
            var j = from
            while j + pattern.count <= n {
                var ok = true
                for k in 0..<pattern.count {
                    let a = caseInsensitive ? lower(bytes[j + k]) : bytes[j + k]
                    if a != pattern[k] { ok = false; break }
                }
                if ok { return j }
                j += 1
            }
            return nil
        }

        while i < n {
            guard bytes[i] == 60 /* < */ else { i += 1; continue }
            let next = i + 1 < n ? bytes[i + 1] : 0
            if next == 33 /* ! */ {
                flushText(i)
                if i + 3 < n, bytes[i + 2] == 45, bytes[i + 3] == 45 {
                    let end = find(Array("-->".utf8), from: i + 4) ?? n
                    i = min(n, end + 3)
                } else {
                    let end = find([62], from: i) ?? n
                    i = min(n, end + 1)
                }
                textStart = i
                continue
            }
            if next == 47 /* / */ {
                var j = i + 2
                var name: [UInt8] = []
                while j < n, isNameChar(bytes[j]) { name.append(lower(bytes[j])); j += 1 }
                guard !name.isEmpty else { i += 1; continue }
                flushText(i)
                let end = find([62], from: j) ?? n
                tokens.append(.end(String(decoding: name, as: UTF8.self)))
                i = min(n, end + 1)
                textStart = i
                continue
            }
            guard (next >= 97 && next <= 122) || (next >= 65 && next <= 90) else { i += 1; continue }
            flushText(i)
            var j = i + 1
            var name: [UInt8] = []
            while j < n, isNameChar(bytes[j]) { name.append(lower(bytes[j])); j += 1 }
            // 属性
            var attrs: [String: String] = [:]
            var selfClosing = false
            while j < n, bytes[j] != 62 {
                let b = bytes[j]
                if b == 47 { selfClosing = true; j += 1; continue }
                if b == 32 || b == 10 || b == 13 || b == 9 { j += 1; continue }
                var key: [UInt8] = []
                while j < n, bytes[j] != 61, bytes[j] != 62, bytes[j] != 32, bytes[j] != 10, bytes[j] != 9, bytes[j] != 47 {
                    key.append(lower(bytes[j])); j += 1
                }
                var value: [UInt8] = []
                while j < n, bytes[j] == 32 { j += 1 }
                if j < n, bytes[j] == 61 {
                    j += 1
                    while j < n, bytes[j] == 32 { j += 1 }
                    if j < n, bytes[j] == 34 || bytes[j] == 39 {
                        let q = bytes[j]
                        j += 1
                        while j < n, bytes[j] != q { value.append(bytes[j]); j += 1 }
                        j += 1
                    } else {
                        while j < n, bytes[j] != 32, bytes[j] != 62, bytes[j] != 10 { value.append(bytes[j]); j += 1 }
                    }
                }
                if !key.isEmpty {
                    attrs[String(decoding: key, as: UTF8.self)] = String(decoding: value, as: UTF8.self)
                } else {
                    j += 1
                }
                selfClosing = false
            }
            let tag = String(decoding: name, as: UTF8.self)
            i = min(n, j + 1)
            tokens.append(.start(tag, attrs, selfClosing: selfClosing || voidTags.contains(tag)))
            // 原始文本元素：直接跳到结束标签
            if ["script", "style", "textarea", "noscript", "svg", "template"].contains(tag), !selfClosing {
                let closer = Array("</\(tag)".utf8)
                let end = find(closer, from: i, caseInsensitive: true) ?? n
                if tag == "textarea" { tokens.append(.text(String(decoding: bytes[i..<end], as: UTF8.self))) }
                let close = find([62], from: end) ?? n
                tokens.append(.end(tag))
                i = min(n, close + 1)
            }
            textStart = i
        }
        flushText(n)
        return tokens
    }

    private static func extractTitle(_ tokens: [Token]) -> String {
        var inTitle = false
        var title = ""
        var ogTitle: String?
        for t in tokens {
            switch t {
            case let .start(name, attrs, _):
                if name == "title" { inTitle = true }
                if name == "meta", (attrs["property"] == "og:title" || attrs["name"] == "twitter:title"), let c = attrs["content"], !c.isEmpty {
                    ogTitle = decodeEntities(c)
                }
            case .end(let name):
                if name == "title" { inTitle = false }
            case .text(let s):
                if inTitle { title += s }
            }
            if !title.isEmpty && !inTitle { break }
        }
        let t = decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (ogTitle ?? "") : t
    }

    /// 优先使用 <article> / <main> 中的内容
    private static func selectMain(_ tokens: [Token]) -> [Token] {
        for target in ["article", "main"] {
            var start: Int?
            var depth = 0
            for (idx, t) in tokens.enumerated() {
                switch t {
                case .start(let name, _, let sc) where name == target && !sc:
                    if start == nil { start = idx }
                    depth += 1
                case .end(let name) where name == target:
                    depth -= 1
                    if depth == 0, let s = start {
                        let slice = Array(tokens[s...idx])
                        let textLen = slice.reduce(0) { acc, tok in
                            if case .text(let s) = tok { return acc + s.count } else { return acc }
                        }
                        if textLen > 300 { return slice }
                        start = nil
                    }
                default: break
                }
            }
        }
        return tokens
    }

    // MARK: 实体

    private static let entities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "hellip": "…",
        "mdash": "—", "ndash": "–", "copy": "©", "reg": "®", "trade": "™", "middot": "·", "laquo": "«",
        "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "times": "×", "divide": "÷",
        "yen": "¥", "euro": "€", "pound": "£", "cent": "¢", "deg": "°", "plusmn": "±", "bull": "•",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "ensp": " ", "emsp": " ", "thinsp": " ", "zwj": "", "zwnj": ""
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                if let v = entities[name] {
                    out += v
                    i = s.index(after: semi)
                    continue
                }
                if name.hasPrefix("#") {
                    let num = name.dropFirst()
                    let code: UInt32? = num.hasPrefix("x") || num.hasPrefix("X") ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
                    if let code, let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    // MARK: 写出

    private struct Writer {
        let baseURL: URL?
        var stack: [String] = [""]
        var skipDepth = 0
        var preDepth = 0
        var listStack: [(ordered: Bool, counter: Int)] = []
        var quoteDepth = 0
        var linkStack: [String?] = []
        var table: [[String]]? = nil
        var row: [String]? = nil
        var cellDepth = 0
        var imageCount = 0

        init(baseURL: URL?) { self.baseURL = baseURL }

        mutating func run(_ tokens: [Token]) {
            for t in tokens { handle(t) }
        }

        func output() -> String {
            var s = stack.first ?? ""
            s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var current: String {
            get { stack[stack.count - 1] }
            set { stack[stack.count - 1] = newValue }
        }

        private mutating func append(_ s: String) {
            if quoteDepth > 0 && stack.count == 1 && s.contains("\n") {
                let prefix = String(repeating: "> ", count: quoteDepth)
                current += s.replacingOccurrences(of: "\n", with: "\n" + prefix)
            } else {
                current += s
            }
        }

        private mutating func blockBreak() {
            guard stack.count == 1 || cellDepth == 0 else { return }
            let c = current
            if c.isEmpty || c.hasSuffix("\n\n") { return }
            append(c.hasSuffix("\n") ? "\n" : "\n\n")
        }

        private mutating func lineBreak() {
            if current.isEmpty || current.hasSuffix("\n") { return }
            append("\n")
        }

        private func resolve(_ href: String?) -> URL? {
            guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else { return nil }
            let decoded = HTMLConverter.decodeEntities(href)
            if decoded.hasPrefix("javascript:") || decoded.hasPrefix("#") || decoded.hasPrefix("mailto:") { return nil }
            if decoded.hasPrefix("//") { return URL(string: "https:" + decoded) }
            return URL(string: decoded, relativeTo: baseURL)?.absoluteURL
                ?? URL(string: decoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "", relativeTo: baseURL)?.absoluteURL
        }

        private func escape(_ s: String) -> String {
            var out = ""
            for ch in s {
                if "*_`[]\\".contains(ch) { out.append("\\") }
                out.append(ch)
            }
            return out
        }

        mutating func handle(_ t: Token) {
            switch t {
            case let .start(name, attrs, selfClosing):
                if HTMLConverter.skipTags.contains(name) {
                    if !selfClosing { skipDepth += 1 }
                    return
                }
                if skipDepth > 0 { return }
                if attrs["hidden"] != nil || (attrs["aria-hidden"] == "true" && name != "img") || (attrs["style"]?.replacingOccurrences(of: " ", with: "").contains("display:none") ?? false) {
                    if !selfClosing && !HTMLConverter.voidTags.contains(name) { skipDepth += 1 }
                    return
                }
                open(name, attrs)
            case .end(let name):
                if HTMLConverter.skipTags.contains(name) {
                    skipDepth = max(0, skipDepth - 1)
                    return
                }
                if skipDepth > 0 { return }
                close(name)
            case .text(let raw):
                if skipDepth > 0 { return }
                let decoded = HTMLConverter.decodeEntities(raw)
                if preDepth > 0 {
                    append(decoded)
                    return
                }
                var collapsed = decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if current.isEmpty || current.hasSuffix("\n") || current.hasSuffix(" ") {
                    while collapsed.hasPrefix(" ") { collapsed.removeFirst() }
                }
                if collapsed.isEmpty { return }
                append(escape(collapsed))
            }
        }

        private mutating func open(_ name: String, _ attrs: [String: String]) {
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blockBreak()
                let level = Int(String(name.last!)) ?? 2
                append(String(repeating: "#", count: min(level, 4)) + " ")
            case "br":
                if preDepth > 0 { append("\n") } else { append("  \n") }
            case "hr":
                blockBreak(); append("---"); blockBreak()
            case "ul", "ol":
                if listStack.isEmpty { blockBreak() } else { lineBreak() }
                listStack.append((name == "ol", Int(attrs["start"] ?? "") ?? 1))
            case "li":
                lineBreak()
                let depth = max(0, listStack.count - 1)
                let indent = String(repeating: "  ", count: depth)
                if var top = listStack.last, top.ordered {
                    append("\(indent)\(top.counter). ")
                    top.counter += 1
                    listStack[listStack.count - 1] = top
                } else {
                    append("\(indent)- ")
                }
            case "pre":
                blockBreak()
                let lang = (attrs["class"] ?? "").components(separatedBy: " ").first(where: { $0.hasPrefix("language-") || $0.hasPrefix("lang-") })
                    .map { $0.replacingOccurrences(of: "language-", with: "").replacingOccurrences(of: "lang-", with: "") } ?? ""
                append("```\(lang)\n")
                preDepth += 1
            case "code":
                if preDepth == 0 { append("`") }
            case "strong", "b":
                if preDepth == 0 { stack.append("") }
            case "em", "i":
                if preDepth == 0 { stack.append("") }
            case "del", "s", "strike":
                if preDepth == 0 { stack.append("") }
            case "a":
                linkStack.append(attrs["href"])
                stack.append("")
            case "img":
                guard imageCount < 30 else { return }
                let src = attrs["data-src"] ?? attrs["data-original"] ?? attrs["src"]
                guard let url = resolve(src), url.scheme?.hasPrefix("http") == true else { return }
                if let w = Int(attrs["width"] ?? ""), w <= 4 { return }
                if url.pathExtension.lowercased() == "svg" { return }
                imageCount += 1
                let alt = (attrs["alt"] ?? "").replacingOccurrences(of: "]", with: "")
                lineBreak()
                append("![\(alt)](\(url.absoluteString))")
                lineBreak()
            case "blockquote":
                blockBreak()
                quoteDepth += 1
                append("> ")
            case "table":
                blockBreak()
                table = []
            case "tr":
                if table != nil { row = [] }
            case "td", "th":
                if row != nil {
                    cellDepth += 1
                    stack.append("")
                }
            default:
                if HTMLConverter.blockTags.contains(name) { blockBreak() }
            }
        }

        private mutating func close(_ name: String) {
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "section", "article", "header", "main", "figure", "figcaption", "dl", "details", "summary":
                blockBreak()
            case "dt", "dd":
                lineBreak()
            case "ul", "ol":
                if !listStack.isEmpty { listStack.removeLast() }
                if listStack.isEmpty { blockBreak() }
            case "li":
                lineBreak()
            case "pre":
                if preDepth > 0 {
                    preDepth -= 1
                    lineBreak()
                    append("```")
                    blockBreak()
                }
            case "code":
                if preDepth == 0 { append("`") }
            case "strong", "b":
                if preDepth == 0 { wrapTop("**") }
            case "em", "i":
                if preDepth == 0 { wrapTop("*") }
            case "del", "s", "strike":
                if preDepth == 0 { wrapTop("~~") }
            case "a":
                guard stack.count > 1, !linkStack.isEmpty else { return }
                let text = stack.removeLast().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                let href = linkStack.removeLast()
                if let url = resolve(href), !text.isEmpty, url.scheme?.hasPrefix("http") == true {
                    if text.hasPrefix("![") {
                        append(text)
                    } else {
                        append("[\(text)](\(url.absoluteString.replacingOccurrences(of: ")", with: "%29")))")
                    }
                } else {
                    append(text)
                }
            case "blockquote":
                quoteDepth = max(0, quoteDepth - 1)
                blockBreak()
            case "td", "th":
                if row != nil, cellDepth > 0, stack.count > 1 {
                    cellDepth -= 1
                    let text = stack.removeLast().replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|").trimmingCharacters(in: .whitespaces)
                    row?.append(text)
                }
            case "tr":
                if let r = row, !r.isEmpty { table?.append(r) }
                row = nil
            case "table":
                if let t = table, !t.isEmpty {
                    let cols = t.map(\.count).max() ?? 0
                    if cols <= 1 {
                        for r in t { append(r.joined(separator: " ")); lineBreak() }
                    } else {
                        let rows = t.map { $0 + Array(repeating: "", count: cols - $0.count) }
                        append("| " + rows[0].joined(separator: " | ") + " |\n")
                        append("|" + Array(repeating: " --- |", count: cols).joined() + "\n")
                        for r in rows.dropFirst() { append("| " + r.joined(separator: " | ") + " |\n") }
                    }
                    blockBreak()
                }
                table = nil
            default:
                break
            }
        }

        private mutating func wrapTop(_ marker: String) {
            guard stack.count > 1 else { return }
            let inner = stack.removeLast()
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                append(inner)
            } else {
                append(marker + trimmed + marker + (inner.hasSuffix(" ") ? " " : ""))
            }
        }
    }
}
