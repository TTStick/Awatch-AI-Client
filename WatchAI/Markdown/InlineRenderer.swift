import SwiftUI

enum Palette {
    static let codeBackground = Color(white: 0.13)
    static let inlineCode = Color(red: 1.0, green: 0.62, blue: 0.45)
    static let link = Color(red: 0.42, green: 0.72, blue: 1.0)
    static let userBubble = Color(red: 0.16, green: 0.42, blue: 0.95)
    static let quoteBar = Color(white: 0.45)
    static let tableHeader = Color(white: 0.2)
    static let tableBorder = Color(white: 0.28)
    static let toolCard = Color(red: 0.15, green: 0.2, blue: 0.17)
    static let reasoning = Color(white: 0.6)
}

/// 行内 Markdown → AttributedString
enum InlineRenderer {
    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 600
        return c
    }()

    static func render(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = build(text)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    private static func build(_ source: String) -> AttributedString {
        let text = LaTeX.convertInline(source)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in attr.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attr[run.range].font = .system(.footnote, design: .monospaced)
                attr[run.range].foregroundColor = Palette.inlineCode
                attr[run.range].backgroundColor = Color.white.opacity(0.1)
            }
            if run.link != nil {
                attr[run.range].foregroundColor = Palette.link
                attr[run.range].underlineStyle = .single
            }
        }
        autolink(&attr)
        return attr
    }

    /// 为裸链接添加可点击属性
    private static func autolink(_ attr: inout AttributedString) {
        let plain = String(attr.characters)
        guard plain.contains("http"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let ns = plain as NSString
        for m in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http"),
                  let range = Range(m.range, in: attr) else { continue }
            if attr[range].runs.contains(where: { $0.link != nil || ($0.inlinePresentationIntent?.contains(.code) ?? false) }) { continue }
            attr[range].link = url
            attr[range].foregroundColor = Palette.link
            attr[range].underlineStyle = .single
        }
    }
}

/// 极简 LaTeX → Unicode 转换，让公式在手表上可读
enum LaTeX {
    private static let symbols: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\epsilon": "ε", "\\varepsilon": "ε",
        "\\zeta": "ζ", "\\eta": "η", "\\theta": "θ", "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν", "\\xi": "ξ",
        "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ", "\\tau": "τ", "\\phi": "φ", "\\varphi": "φ", "\\chi": "χ",
        "\\psi": "ψ", "\\omega": "ω", "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
        "\\Pi": "Π", "\\Sigma": "Σ", "\\Phi": "Φ", "\\Omega": "Ω",
        "\\times": "×", "\\cdot": "·", "\\div": "÷", "\\pm": "±", "\\mp": "∓", "\\leq": "≤", "\\le": "≤",
        "\\geq": "≥", "\\ge": "≥", "\\neq": "≠", "\\ne": "≠", "\\approx": "≈", "\\equiv": "≡", "\\sim": "∼",
        "\\infty": "∞", "\\partial": "∂", "\\nabla": "∇", "\\sum": "∑", "\\prod": "∏", "\\int": "∫",
        "\\oint": "∮", "\\iint": "∬", "\\rightarrow": "→", "\\to": "→", "\\leftarrow": "←", "\\Rightarrow": "⇒",
        "\\Leftarrow": "⇐", "\\leftrightarrow": "↔", "\\Leftrightarrow": "⇔", "\\implies": "⇒", "\\iff": "⇔",
        "\\in": "∈", "\\notin": "∉", "\\subset": "⊂", "\\subseteq": "⊆", "\\supset": "⊃", "\\cup": "∪",
        "\\cap": "∩", "\\emptyset": "∅", "\\forall": "∀", "\\exists": "∃", "\\neg": "¬", "\\land": "∧",
        "\\lor": "∨", "\\angle": "∠", "\\degree": "°", "\\circ": "∘", "\\ldots": "…", "\\cdots": "⋯",
        "\\dots": "…", "\\quad": "  ", "\\qquad": "    ", "\\,": " ", "\\;": " ", "\\!": "", "\\left": "",
        "\\right": "", "\\big": "", "\\Big": "", "\\displaystyle": "", "\\mathrm": "", "\\mathbf": "",
        "\\text": "", "\\operatorname": "", "\\lim": "lim", "\\log": "log", "\\ln": "ln", "\\sin": "sin",
        "\\cos": "cos", "\\tan": "tan", "\\max": "max", "\\min": "min", "\\exp": "exp", "\\{": "{", "\\}": "}",
        "\\%": "%", "\\langle": "⟨", "\\rangle": "⟩", "\\|": "‖", "\\mid": "|", "\\perp": "⊥", "\\parallel": "∥"
    ]
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ",
        "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ", "T": "ᵀ"
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "n": "ₙ", "m": "ₘ", "o": "ₒ", "x": "ₓ", "t": "ₜ"
    ]

    static func toUnicode(_ src: String) -> String {
        var s = src
        // \frac{a}{b} → (a)/(b)
        for _ in 0..<4 {
            s = s.replacingOccurrences(of: "\\\\[dt]?frac\\{([^{}]*)\\}\\{([^{}]*)\\}", with: "($1)/($2)", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "\\\\sqrt\\[([^\\]]*)\\]\\{([^{}]*)\\}", with: "$1√($2)", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\sqrt\\{([^{}]*)\\}", with: "√($1)", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\(?:vec|overrightarrow)\\{([^{}]*)\\}", with: "$1⃗", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\(?:bar|overline)\\{([^{}]*)\\}", with: "$1̄", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\hat\\{([^{}]*)\\}", with: "$1̂", options: .regularExpression)
        for (k, v) in symbols.sorted(by: { $0.key.count > $1.key.count }) {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = script(s, marker: "^", map: superscripts)
        s = script(s, marker: "_", map: subscripts)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s
    }

    private static func script(_ s: String, marker: Character, map: [Character: Character]) -> String {
        var out = ""
        var chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == marker, i + 1 < chars.count {
                var group: [Character] = []
                var j = i + 1
                if chars[j] == "{" {
                    j += 1
                    while j < chars.count, chars[j] != "}" { group.append(chars[j]); j += 1 }
                    j += 1
                } else {
                    group = [chars[j]]
                    j += 1
                }
                if group.allSatisfy({ map[$0] != nil }) {
                    out += String(group.compactMap { map[$0] })
                } else {
                    out += String(marker) + "(" + String(group) + ")"
                }
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        chars.removeAll()
        return out
    }

    /// 行内公式 \( … \) 与 $…$
    static func convertInline(_ text: String) -> String {
        guard text.contains("\\(") || text.contains("$") else { return text }
        var s = text
        if s.contains("\\(") {
            s = replace(s, pattern: "\\\\\\((.+?)\\\\\\)")
        }
        if s.contains("$") {
            s = replace(s, pattern: "(?<![\\\\$\\w])\\$([^$\\n]*?[\\\\^_{][^$\\n]*?)\\$(?!\\$)")
        }
        return s
    }

    private static func replace(_ s: String, pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let inner = ns.substring(with: m.range(at: 1))
            out += "`" + toUnicode(inner).replacingOccurrences(of: "`", with: "") + "`"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
