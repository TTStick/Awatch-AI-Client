import SwiftUI

struct QAPair: Identifiable, Hashable {
    var id: UUID { questionID }
    var conversationID: UUID
    var conversationTitle: String
    var questionID: UUID
    var question: String
    var answer: String
    var answerID: UUID?
    var date: Date
    var imageCount: Int
    var isFavorite: Bool
    var cost: Double
    var currency: String
}

/// 所有问答的快速预览：卡片翻页 / 紧凑列表
struct QAPreviewView: View {
    @Environment(AppModel.self) private var app
    @State private var pairs: [QAPair] = []
    @State private var loading = true
    @State private var cardMode = true
    @State private var favoritesOnly = false
    @State private var includeArchived = false
    @State private var query = ""
    @State private var detail: QAPair?
    @State private var showFilters = false

    private var filtered: [QAPair] {
        var list = pairs
        if favoritesOnly { list = list.filter(\.isFavorite) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.question.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
        }
        return list
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("加载问答…")
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.secondary)
                    Text(pairs.isEmpty ? "还没有问答记录" : "没有符合条件的问答").font(.footnote).foregroundStyle(.secondary)
                    if favoritesOnly || !query.isEmpty {
                        Button("清除筛选") { favoritesOnly = false; query = "" }
                    }
                }
            } else if cardMode {
                TabView {
                    ForEach(Array(filtered.prefix(200).enumerated()), id: \.element.id) { index, pair in
                        QACard(pair: pair, index: index + 1, total: min(filtered.count, 200)) {
                            detail = pair
                        }
                    }
                }
                .tabViewStyle(.verticalPage)
            } else {
                List {
                    ForEach(filtered) { pair in
                        Button { detail = pair } label: { QARow(pair: pair) }
                    }
                }
            }
        }
        .navigationTitle("问答速览")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilters) {
            List {
                Toggle("卡片模式", isOn: $cardMode)
                Toggle("只看收藏", isOn: $favoritesOnly)
                Toggle("包含归档", isOn: $includeArchived)
                    .onChange(of: includeArchived) { _, _ in Task { await load() } }
                Text("共 \(pairs.count) 组问答，筛选后 \(filtered.count) 组").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "筛选问答")
        .sheet(item: $detail) { pair in
            NavigationStack { QADetailView(pair: pair) }
        }
        .task { await load() }
    }

    private func load() async {
        loading = pairs.isEmpty
        let snapshot = await app.conversations.allMessagesSnapshot(includeArchived: includeArchived)
        let titles = Dictionary(uniqueKeysWithValues: app.conversations.conversations.map { ($0.id, $0.title) })
        pairs = await Task.detached(priority: .userInitiated) {
            Self.buildPairs(snapshot, titles: titles)
        }.value
        loading = false
    }

    nonisolated static func buildPairs(_ snapshot: [UUID: [ChatMessage]], titles: [UUID: String]) -> [QAPair] {
        var out: [QAPair] = []
        for (cid, list) in snapshot {
            var i = 0
            while i < list.count {
                let q = list[i]
                guard q.role == .user else { i += 1; continue }
                var answer = ""
                var answerID: UUID?
                var fav = q.isFavorite
                var cost = 0.0
                var currency = "CNY"
                var j = i + 1
                while j < list.count, list[j].role != .user {
                    let m = list[j]
                    if m.role == .assistant {
                        if !m.content.isEmpty {
                            answer = m.content
                            answerID = m.id
                        }
                        if m.isFavorite { fav = true }
                        if let u = m.usage { cost += u.cost; currency = u.currency }
                    }
                    j += 1
                }
                out.append(QAPair(conversationID: cid, conversationTitle: titles[cid] ?? "对话", questionID: q.id,
                                  question: q.content, answer: answer, answerID: answerID, date: q.createdAt,
                                  imageCount: q.images.count, isFavorite: fav, cost: cost, currency: currency))
                i = j
            }
        }
        return out.sorted { $0.date > $1.date }
    }
}

struct QACard: View {
    let pair: QAPair
    let index: Int
    let total: Int
    let onOpen: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("\(index)/\(total)").monospacedDigit()
                    if pair.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    Spacer()
                    Text(Fmt.relative(pair.date))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 5) {
                    Text("Q").font(.caption.bold()).foregroundStyle(Palette.userBubble)
                    Text(pair.question).font(.footnote.weight(.semibold)).lineLimit(4)
                }
                if pair.imageCount > 0 {
                    Label("\(pair.imageCount) 张图片", systemImage: "photo").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top, spacing: 5) {
                    Text("A").font(.caption.bold()).foregroundStyle(.green)
                    if pair.answer.isEmpty {
                        Text("（无回答）").font(.caption).foregroundStyle(.secondary)
                    } else {
                        MarkdownView(String(pair.answer.prefix(500)) + (pair.answer.count > 500 ? "…" : ""), compact: true)
                            .font(.caption)
                    }
                }
                Button(action: onOpen) {
                    Label("查看全文", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(pair.conversationTitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct QARow: View {
    let pair: QAPair

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if pair.isFavorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                Text(pair.question).font(.footnote.weight(.semibold)).lineLimit(2)
            }
            Text(ConversationStore.plainSnippet(pair.answer, limit: 70))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Text("\(pair.conversationTitle) · \(Fmt.relative(pair.date))")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

struct QADetailView: View {
    let pair: QAPair
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(pair.question)
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.userBubble.opacity(0.35)))
                MarkdownView(pair.answer)
                HStack {
                    if pair.cost > 0 { Text(Fmt.money(pair.cost, pair.currency)) }
                    Text(Fmt.dateTime(pair.date))
                }
                .font(.caption2).foregroundStyle(.secondary)
                Button {
                    dismiss()
                    app.router.path.append(.chat(pair.conversationID))
                } label: {
                    Label("进入对话", systemImage: "bubble.left.and.bubble.right")
                }
                if let aid = pair.answerID {
                    Button {
                        app.conversations.toggleFavoriteMessage(pair.conversationID, aid)
                    } label: {
                        let fav = app.conversations.message(pair.conversationID, aid)?.isFavorite ?? false
                        Label(fav ? "取消收藏回答" : "收藏回答", systemImage: fav ? "star.slash" : "star")
                    }
                }
                ShareLink(item: "Q: \(pair.question)\n\nA: \(pair.answer)") {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(pair.conversationTitle)
        .modifier(InlineWebLinks())
    }
}
