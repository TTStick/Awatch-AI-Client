import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route)
                }
        }
        .sheet(item: $router.web) { item in
            NavigationStack {
                WebReaderView(source: item.source)
            }
        }
        .alert("⏰ 倒计时结束", isPresented: Binding(
            get: { app.agent.finishedTimer != nil },
            set: { if !$0 { app.agent.finishedTimer = nil } })
        ) {
            Button("好的", role: .cancel) { app.agent.finishedTimer = nil }
            Button("再来一次") {
                if let t = app.agent.finishedTimer { app.agent.restartTimer(t.id) }
                app.agent.finishedTimer = nil
            }
        } message: {
            Text(app.agent.finishedTimer?.label ?? "")
        }
        #if DEBUG
        .task { app.applyDebugLaunchArguments() }
        #endif
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .chat(let id): ChatView(conversationID: id)
        case .conversations(let filter): ConversationListView(filter: filter)
        case .folders: FolderListView()
        case .favorites: FavoritesView()
        case .qa: QAPreviewView()
        case .search: GlobalSearchView()
        case .toolbox: ToolboxView()
        case .memos: MemoListView()
        case .memo(let id): MemoDetailView(memoID: id)
        case .todos: TodoListView()
        case .timers: TimerListView()
        case .memory: MemoryView()
        case .usage: UsageView()
        case .providers: ProviderListView()
        case .provider(let id): ProviderEditView(providerID: id)
        case .settings: SettingsView()
        case .personas: PersonaListView()
        }
    }
}
