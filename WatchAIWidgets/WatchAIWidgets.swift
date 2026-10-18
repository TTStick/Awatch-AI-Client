import SwiftUI
import WidgetKit

@main
struct WatchAIWidgets: WidgetBundle {
    var body: some Widget {
        QuickAskWidget()
        AgentGlanceWidget()
    }
}

/// 深度链接，交给 App 的 Router.handleDeepLink
enum WidgetLink {
    static let new = URL(string: "watchai://new")!
    static let timers = URL(string: "watchai://timers")!
    static let todos = URL(string: "watchai://todos")!
}

// MARK: - 问 AI

struct QuickAskEntry: TimelineEntry {
    let date: Date
}

struct QuickAskProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAskEntry { QuickAskEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (QuickAskEntry) -> Void) {
        completion(QuickAskEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAskEntry>) -> Void) {
        completion(Timeline(entries: [QuickAskEntry(date: Date())], policy: .never))
    }
}

/// 表盘一键进入新对话
struct QuickAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchAIQuickAsk", provider: QuickAskProvider()) { _ in
            QuickAskView()
        }
        .configurationDisplayName("问 AI")
        .description("从表盘一键开始新对话。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct QuickAskView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetLink.new)
            .containerBackground(Color.accentColor.opacity(0.3), for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .widgetAccentable()
                .widgetLabel("问 AI")
        case .accessoryInline:
            Label("问 AI", systemImage: "sparkles")
        default:
            QuickAskBadge()
        }
    }
}

/// 圆形「问 AI」图标，空状态的计时待办小组件也复用
struct QuickAskBadge: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .widgetAccentable()
                Text("问 AI")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
    }
}
