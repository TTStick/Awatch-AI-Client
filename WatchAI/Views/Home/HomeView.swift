import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showPersonas = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        List {
            Section {
                quickAsk
                HStack(spacing: 6) {
                    Button {
                        let id = app.newConversation()
                        app.router.open(.chat(id))
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showPersonas = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 44)
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                        Image(systemName: importing ? "hourglass" : "photo")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 44)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            if app.providers.providers.isEmpty {
                Section {
                    NavigationLink(value: Route.providers) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("配置 API", systemImage: "key.fill").font(.headline).foregroundStyle(.orange)
                            Text("添加 MiniMax 或其他 OpenAI 兼容服务，填写 API Key 后即可对话。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !app.agent.activeTimers.isEmpty {
                Section("计时中") {
                    ForEach(app.agent.activeTimers) { t in
                        NavigationLink(value: Route.timers) {
                            TimerMiniRow(timer: t)
                        }
                    }
                }
            }

            let pinned = app.conversations.pinned
            if !pinned.isEmpty {
                Section("置顶") {
                    ForEach(pinned) { c in
                        NavigationLink(value: Route.chat(c.id)) { ConversationRow(conversation: c) }
                    }
                }
            }

            let recent = app.conversations.recent
            Section("最近") {
                if recent.isEmpty && pinned.isEmpty {
                    Text("还没有对话，点上方麦克风直接提问").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(recent.prefix(6)) { c in
                    NavigationLink(value: Route.chat(c.id)) { ConversationRow(conversation: c) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { app.conversations.delete(c.id) } label: { Image(systemName: "trash") }
                            Button { app.conversations.update(c.id) { $0.isArchived = true } } label: { Image(systemName: "archivebox") }
                                .tint(.indigo)
                        }
                        .swipeActions(edge: .leading) {
                            Button { app.conversations.update(c.id) { $0.isPinned.toggle() } } label: { Image(systemName: "pin") }
                                .tint(.orange)
                        }
                }
                NavigationLink(value: Route.conversations(.all)) {
                    Label("全部对话（\(app.conversations.active.count)）", systemImage: "bubble.left.and.bubble.right")
                }
            }

            Section("浏览") {
                NavigationLink(value: Route.qa) { Label("问答速览", systemImage: "rectangle.stack") }
                NavigationLink(value: Route.search) { Label("全文搜索", systemImage: "magnifyingglass") }
                NavigationLink(value: Route.favorites) { Label("收藏", systemImage: "star") }
                NavigationLink(value: Route.folders) { Label("文件夹与整理", systemImage: "folder") }
                NavigationLink(value: Route.conversations(.archived)) {
                    Label("归档（\(app.conversations.archived.count)）", systemImage: "archivebox")
                }
            }

            Section("助理") {
                NavigationLink(value: Route.toolbox) {
                    HStack {
                        Label("备忘·待办·计时", systemImage: "square.grid.2x2")
                        Spacer()
                        let pending = app.agent.pendingTodos.count
                        if pending > 0 { Text("\(pending)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                NavigationLink(value: Route.memory) {
                    HStack {
                        Label("反思记忆", systemImage: "brain.head.profile")
                        Spacer()
                        Image(systemName: app.settings.memoryEnabled ? "circle.fill" : "circle")
                            .font(.system(size: 7))
                            .foregroundStyle(app.settings.memoryEnabled ? .green : .secondary)
                    }
                }
            }

            Section("管理") {
                NavigationLink(value: Route.usage) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("用量与计费", systemImage: "chart.bar.xaxis")
                        let today = app.usage.summary(.today)
                        Text("今日 \(TokenEstimator.format(today.totalTokens)) tokens · \(Fmt.moneyMap(today.costByCurrency))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                NavigationLink(value: Route.providers) { Label("API 管理", systemImage: "key") }
                NavigationLink(value: Route.settings) { Label("设置", systemImage: "gearshape") }
            }
        }
        .navigationTitle("Watch AI")
        .sheet(isPresented: $showPersonas) {
            PersonaPickerSheet { persona in
                showPersonas = false
                let id = app.newConversation(persona: persona)
                app.router.open(.chat(id))
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                let images = await ImageImporter.load(items, settings: app.settings)
                photoItems = []
                importing = false
                guard !images.isEmpty else { return }
                let id = app.newConversation()
                app.pendingImages[id] = images
                app.router.open(.chat(id))
            }
        }
    }

    @ViewBuilder
    private var quickAsk: some View {
        let field = TextFieldLink(prompt: Text("问点什么…")) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text("直接提问").font(.headline)
                    Text("语音 / 涂写 / 键盘").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        } onSubmit: { text in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            app.quickAsk(text)
        }
        .buttonStyle(.plain)
        if #available(watchOS 11.0, *) {
            field.handGestureShortcut(.primaryAction)
        } else {
            field
        }
    }
}

struct TimerMiniRow: View {
    let timer: CountdownTimer

    var body: some View {
        HStack {
            Image(systemName: timer.state == .paused ? "pause.circle" : "timer")
                .foregroundStyle(timer.state == .paused ? Color.secondary : Color.orange)
            Text(timer.label).font(.footnote).lineLimit(1)
            Spacer()
            if timer.state == .running, let end = timer.endDate {
                Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                    .font(.system(.footnote, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70, alignment: .trailing)
            } else {
                Text(AgentStore.clock(timer.remaining()))
                    .font(.system(.footnote, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PersonaPickerSheet: View {
    let onPick: (Persona) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.settingsStore.personas) { p in
                    Button { onPick(p) } label: {
                        HStack {
                            Text(p.emoji).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.footnote.weight(.semibold))
                                if !p.systemPrompt.isEmpty {
                                    Text(p.systemPrompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                NavigationLink(value: Route.personas) {
                    Label("管理助手", systemImage: "slider.horizontal.3")
                }
            }
            .navigationTitle("选择助手")
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}
