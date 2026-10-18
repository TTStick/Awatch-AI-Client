import SwiftUI

enum Fmt {
    static func relative(_ date: Date) -> String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            df.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            df.dateFormat = "昨天 HH:mm"
        } else if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            df.dateFormat = "M月d日"
        } else {
            df.dateFormat = "yyyy/M/d"
        }
        return df.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 HH:mm"
        return df.string(from: date)
    }

    static func money(_ v: Double, _ currency: String) -> String {
        let symbol = currency == "USD" ? "$" : currency == "CNY" ? "¥" : currency + " "
        if v == 0 { return symbol + "0" }
        if v < 0.01 { return symbol + String(format: "%.4f", v) }
        if v < 1 { return symbol + String(format: "%.3f", v) }
        return symbol + String(format: "%.2f", v)
    }

    static func moneyMap(_ map: [String: Double]) -> String {
        let parts = map.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }
        return parts.isEmpty ? "¥0" : parts.joined(separator: " + ")
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.1fs", s) : String(format: "%.0fs", s)
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if conversation.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
                if conversation.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                Text(conversation.title)
                    .font(.system(.footnote, weight: .semibold))
                    .lineLimit(2)
                if app.engine.isGenerating(conversation.id) {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                }
            }
            if !conversation.preview.isEmpty {
                Text(conversation.preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(Fmt.relative(conversation.updatedAt))
                if let f = app.conversations.folder(conversation.folderID) {
                    Text("\(f.emoji)\(f.name)").lineLimit(1)
                }
                if conversation.messageCount > 0 {
                    Text("· \(conversation.messageCount)")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// 生成中的状态指示
struct PhaseIndicator: View {
    let phase: GenerationPhase
    @State private var animate = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .scaleEffect(animate ? 1 : 0.5)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: animate)
                }
            }
            Text(phase.title).font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { animate = true }
    }
}

struct SectionHint: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }
}

/// 在手表上编辑长文本：先点按进入系统输入
struct TextEditRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String = "点按输入"
    var lineLimit: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...lineLimit)
                .font(.footnote)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .rounded, weight: .semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
    }
}

/// 简单的错误/提示横幅
struct InlineNotice: View {
    let text: String
    var systemImage: String = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
