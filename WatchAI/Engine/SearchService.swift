import Foundation

struct SearchHit: Identifiable, Hashable {
    var id: UUID { messageID }
    var conversationID: UUID
    var conversationTitle: String
    var messageID: UUID
    var role: ChatRole
    var snippet: String
    var date: Date
    var score: Double
}

@MainActor
enum SearchService {
    static func search(_ query: String, in store: ConversationStore, includeArchived: Bool, limit: Int, excluding: UUID? = nil) async -> [SearchHit] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "，" || $0 == "," }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let snapshot = await store.allMessagesSnapshot(includeArchived: includeArchived)
        let titles = Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0.title) })
        return await Task.detached(priority: .userInitiated) {
            var hits: [SearchHit] = []
            let now = Date()
            for (cid, list) in snapshot where cid != excluding {
                let title = titles[cid] ?? "对话"
                let titleLower = title.lowercased()
                for m in list where m.role == .user || m.role == .assistant {
                    let text = m.content
                    let lower = text.lowercased()
                    var matched = 0
                    for t in terms where lower.contains(t) || titleLower.contains(t) { matched += 1 }
                    guard matched > 0, terms.count == 1 || matched >= max(1, terms.count - 1) else { continue }
                    guard let firstTerm = terms.first(where: { lower.contains($0) }) else { continue }
                    let snippet = Self.snippet(text, around: firstTerm)
                    let age = now.timeIntervalSince(m.createdAt) / 86400
                    let score = Double(matched) * 10 + (m.role == .user ? 2 : 0) - min(age, 365) / 30
                    hits.append(SearchHit(conversationID: cid, conversationTitle: title, messageID: m.id, role: m.role,
                                          snippet: snippet, date: m.createdAt, score: score))
                }
            }
            return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
        }.value
    }

    nonisolated static func snippet(_ text: String, around term: String, radius: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: term, options: .caseInsensitive) else { return String(flat.prefix(radius * 2)) }
        let start = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var s = String(flat[start..<end])
        if start != flat.startIndex { s = "…" + s }
        if end != flat.endIndex { s += "…" }
        return s
    }
}
