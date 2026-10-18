import SwiftUI

/// 基于词法扫描的轻量语法高亮
enum SyntaxHighlighter {
    static let keywordColor = Color(red: 0.99, green: 0.37, blue: 0.64)
    static let stringColor = Color(red: 0.99, green: 0.42, blue: 0.36)
    static let commentColor = Color(red: 0.45, green: 0.52, blue: 0.47)
    static let numberColor = Color(red: 0.82, green: 0.75, blue: 0.45)
    static let typeColor = Color(red: 0.37, green: 0.82, blue: 0.86)
    static let tagColor = Color(red: 0.99, green: 0.55, blue: 0.35)
    static let plainColor = Color(white: 0.92)

    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 80
        return c
    }()

    private static let common: Set<String> = [
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default", "in",
        "true", "false", "null", "nil", "none", "None", "True", "False", "import", "from", "as", "class", "struct",
        "enum", "func", "function", "def", "let", "var", "const", "static", "public", "private", "protected",
        "internal", "new", "this", "self", "super", "try", "catch", "throw", "throws", "finally", "async", "await",
        "yield", "lambda", "with", "pass", "raise", "except", "elif", "not", "and", "or", "is", "interface",
        "extends", "implements", "package", "void", "int", "float", "double", "bool", "boolean", "string", "char",
        "long", "short", "byte", "unsigned", "signed", "auto", "typedef", "namespace", "using", "template",
        "typename", "virtual", "override", "final", "abstract", "fn", "mut", "pub", "impl", "trait", "match",
        "loop", "mod", "use", "crate", "where", "type", "go", "chan", "select", "defer", "map", "range", "fallthrough",
        "guard", "protocol", "extension", "init", "deinit", "inout", "some", "any", "export", "undefined",
        "typeof", "instanceof", "delete", "of", "goto", "sizeof", "volatile", "extern", "register", "union",
        "echo", "fi", "then", "done", "esac", "local", "readonly", "val", "object", "companion", "when", "fun",
        "data", "sealed", "open", "lateinit", "suspend", "elseif", "end", "begin", "module", "require", "puts",
        "unless", "until", "foreach", "global", "nonlocal", "assert", "del", "print", "println", "printf"
    ]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
        "drop", "alter", "add", "index", "primary", "key", "foreign", "references", "join", "left", "right",
        "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not",
        "null", "is", "in", "like", "between", "distinct", "count", "sum", "avg", "max", "min", "union", "all",
        "case", "when", "then", "else", "end", "exists", "default", "unique", "view", "with", "desc", "asc"
    ]

    private enum Family { case cLike, hash, sql, markup, css, plain }

    private static func family(_ lang: String) -> Family {
        switch lang.lowercased() {
        case "py", "python", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml", "r", "perl", "pl", "dockerfile", "makefile", "ini", "conf", "properties", "powershell", "ps1":
            return .hash
        case "sql", "mysql", "postgresql", "sqlite", "lua", "haskell", "hs":
            return .sql
        case "html", "xml", "svg", "vue", "plist", "xhtml":
            return .markup
        case "css", "scss", "less":
            return .css
        case "", "text", "txt", "plaintext", "markdown", "md", "log", "diff":
            return .plain
        default:
            return .cLike
        }
    }

    static func highlight(_ code: String, lang: String) -> AttributedString {
        let key = (lang + "\u{1}" + code) as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let result: AttributedString
        if code.count > 12_000 {
            var a = AttributedString(code)
            a.foregroundColor = plainColor
            result = a
        } else {
            result = tokenize(code, family: family(lang), lang: lang.lowercased())
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }

    private static func tokenize(_ code: String, family: Family, lang: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(code)
        var i = 0
        var plainBuffer = ""

        func flushPlain() {
            guard !plainBuffer.isEmpty else { return }
            var a = AttributedString(plainBuffer)
            a.foregroundColor = plainColor
            out += a
            plainBuffer = ""
        }
        func emit(_ s: String, _ color: Color) {
            flushPlain()
            var a = AttributedString(s)
            a.foregroundColor = color
            out += a
        }
        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        if family == .plain {
            if lang == "diff" {
                for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                    let color: Color = line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? typeColor : plainColor
                    emit(String(line) + "\n", color)
                }
                return out
            }
            plainBuffer = code
            flushPlain()
            return out
        }

        while i < chars.count {
            let c = chars[i]
            // 注释
            if family == .markup, c == "<", peek(1) == "!", peek(2) == "-", peek(3) == "-" {
                var s = ""
                while i < chars.count {
                    s.append(chars[i])
                    if s.hasSuffix("-->") { i += 1; break }
                    i += 1
                }
                emit(s, commentColor)
                continue
            }
            if (family == .cLike || family == .css) && c == "/" && peek(1) == "*" {
                var s = "/*"
                i += 2
                while i < chars.count {
                    s.append(chars[i])
                    if chars[i] == "/" && s.hasSuffix("*/") && s.count > 3 { i += 1; break }
                    i += 1
                }
                emit(s, commentColor)
                continue
            }
            let lineComment = (family == .cLike && c == "/" && peek(1) == "/")
                || (family == .hash && c == "#")
                || (family == .sql && c == "-" && peek(1) == "-")
            if lineComment {
                var s = ""
                while i < chars.count, chars[i] != "\n" { s.append(chars[i]); i += 1 }
                emit(s, commentColor)
                continue
            }
            // 标签
            if family == .markup, c == "<" {
                var s = ""
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\"" || ch == "'" {
                        emit(s, tagColor); s = ""
                        var str = String(ch)
                        i += 1
                        while i < chars.count, chars[i] != ch { str.append(chars[i]); i += 1 }
                        if i < chars.count { str.append(chars[i]); i += 1 }
                        emit(str, stringColor)
                        continue
                    }
                    s.append(ch)
                    i += 1
                    if ch == ">" { break }
                }
                emit(s, tagColor)
                continue
            }
            // 字符串
            if (c == "\"" || c == "'" || c == "`") && family != .markup {
                let quote = c
                var s = String(c)
                i += 1
                while i < chars.count {
                    let ch = chars[i]
                    s.append(ch)
                    i += 1
                    if ch == "\\", i < chars.count { s.append(chars[i]); i += 1; continue }
                    if ch == quote { break }
                    if ch == "\n" && quote != "`" { break }
                }
                emit(s, stringColor)
                continue
            }
            // 数字
            if c.isASCII, c.isNumber, !(plainBuffer.last.map { $0.isLetter || $0 == "_" } ?? false) {
                var s = String(c)
                i += 1
                while i < chars.count, chars[i].isASCII, chars[i].isHexDigit || chars[i] == "." || chars[i] == "x" || chars[i] == "_" {
                    s.append(chars[i]); i += 1
                }
                emit(s, numberColor)
                continue
            }
            // 标识符
            if c.isLetter || c == "_" || c == "@" || (c == "$" && family != .sql) {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || (s.isEmpty && (chars[i] == "@" || chars[i] == "$")) {
                    s.append(chars[i]); i += 1
                }
                let isKeyword = family == .sql ? sqlKeywords.contains(s.lowercased()) : common.contains(s)
                if isKeyword {
                    emit(s, keywordColor)
                } else if s.hasPrefix("@") {
                    emit(s, typeColor)
                } else if let f = s.first, f.isUppercase, s.count > 1, family != .css {
                    emit(s, typeColor)
                } else if family == .css, i < chars.count, chars[i] == ":" {
                    emit(s, typeColor)
                } else {
                    plainBuffer += s
                }
                continue
            }
            plainBuffer.append(c)
            i += 1
        }
        flushPlain()
        return out
    }
}
