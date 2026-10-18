import Foundation

struct ToolOutput {
    var result: String
    var display: String
    var ok: Bool = true
}

@MainActor
enum ToolRegistry {
    static func displayName(_ name: String) -> String {
        switch name {
        case "memo": return "备忘录"
        case "todo": return "待办"
        case "timer": return "倒计时"
        case "memory": return "记忆"
        case "web_fetch": return "读取网页"
        case "search_conversations": return "检索对话"
        default: return name
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "memo": return "note.text"
        case "todo": return "checklist"
        case "timer": return "timer"
        case "memory": return "brain.head.profile"
        case "web_fetch": return "globe"
        case "search_conversations": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    // MARK: - 定义

    private static func fn(_ name: String, _ desc: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": desc,
                "parameters": ["type": "object", "properties": props, "required": required]
            ] as [String: Any]
        ]
    }

    private static func str(_ desc: String, enumValues: [String]? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "string", "description": desc]
        if let enumValues { d["enum"] = enumValues }
        return d
    }

    static func definitions(_ s: AppSettings) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        if s.toolMemo {
            tools.append(fn("memo", "管理用户手表上的备忘录。create 新建；list 列出；read 读取全文；update 覆盖标题/正文；append 在末尾追加内容；delete 删除；search 按关键词搜索。", [
                "action": str("操作", enumValues: ["create", "list", "read", "update", "append", "delete", "search"]),
                "id": str("备忘 ID（list/search 返回的短 ID）"),
                "title": str("标题"),
                "content": str("正文，支持 Markdown"),
                "query": str("搜索关键词")
            ], required: ["action"]))
        }
        if s.toolTodo {
            tools.append(fn("todo", "管理用户的待办事项。add 新增；list 列出；complete 标记完成；reopen 重新打开；update 修改；delete 删除；clear_completed 清除已完成。", [
                "action": str("操作", enumValues: ["add", "list", "complete", "reopen", "update", "delete", "clear_completed"]),
                "id": str("待办 ID（list 返回的短 ID）"),
                "title": str("待办内容"),
                "notes": str("备注"),
                "due": str("截止/提醒时间，本地时间，格式 yyyy-MM-dd HH:mm"),
                "due_in_minutes": ["type": "integer", "description": "从现在起多少分钟后提醒（与 due 二选一）"],
                "high_priority": ["type": "boolean", "description": "是否重要"],
                "filter": str("list 时的筛选", enumValues: ["pending", "done", "all"])
            ], required: ["action"]))
        }
        if s.toolTimer {
            tools.append(fn("timer", "管理手表上的倒计时，到点会震动并通知。start 开始；list 列出；pause 暂停；resume 继续；cancel 取消；add_time 延长。", [
                "action": str("操作", enumValues: ["start", "list", "pause", "resume", "cancel", "add_time"]),
                "id": str("计时器 ID（list 返回的短 ID）"),
                "seconds": ["type": "integer", "description": "时长（秒）"],
                "minutes": ["type": "number", "description": "时长（分钟），与 seconds 二选一"],
                "label": str("计时名称，例如“泡茶”")
            ], required: ["action"]))
        }
        if s.memoryEnabled && s.memoryAllowAIWrite {
            tools.append(fn("memory", "维护关于用户的长期记忆（跨对话可用）。仅在用户明确要求记住/忘记，或出现明显的长期偏好与重要事实时使用。save 保存；list 列出；search 搜索；update 修改；delete 删除。", [
                "action": str("操作", enumValues: ["save", "list", "search", "update", "delete"]),
                "id": str("记忆 ID"),
                "content": str("记忆内容，一句话，第三人称，如“用户喜欢简洁的回答”"),
                "category": str("分类", enumValues: MemoryItem.categories),
                "query": str("搜索关键词")
            ], required: ["action"]))
        }
        if s.toolWeb {
            tools.append(fn("web_fetch", "读取网页的正文内容（已转换为 Markdown）。当用户给出链接或需要查看某个网页时使用。", [
                "url": str("http/https 网址"),
                "max_chars": ["type": "integer", "description": "最多返回字符数，默认 6000"]
            ], required: ["url"]))
        }
        if s.toolSearch {
            tools.append(fn("search_conversations", "在用户的历史对话中按关键词检索，返回相关片段。用户提到“之前问过/上次说的”时使用。", [
                "query": str("关键词，多个用空格分隔"),
                "limit": ["type": "integer", "description": "最多返回条数，默认 6"]
            ], required: ["query"]))
        }
        return tools
    }

    // MARK: - 执行

    static func execute(_ call: ToolCall, engine: ChatEngine, conversationID: UUID) async -> ToolOutput {
        let args = Args(call.arguments)
        switch call.name {
        case "memo": return memo(args, engine.agent)
        case "todo": return todo(args, engine.agent)
        case "timer": return timer(args, engine.agent)
        case "memory": return memory(args, engine.memory, conversationID: conversationID)
        case "web_fetch": return await webFetch(args)
        case "search_conversations": return await searchConversations(args, engine.conversations, current: conversationID)
        default:
            return ToolOutput(result: json(["ok": false, "error": "未知工具 \(call.name)"]), display: "未知工具 \(call.name)", ok: false)
        }
    }

    struct Args {
        let dict: [String: Any]
        init(_ raw: String) {
            if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                dict = o
            } else {
                dict = [:]
            }
        }
        func string(_ k: String) -> String? {
            if let s = dict[k] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let n = dict[k] as? NSNumber { return n.stringValue }
            return nil
        }
        func double(_ k: String) -> Double? {
            if let n = dict[k] as? NSNumber { return n.doubleValue }
            if let s = dict[k] as? String { return Double(s) }
            return nil
        }
        func bool(_ k: String) -> Bool? {
            if let b = dict[k] as? Bool { return b }
            if let s = dict[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
            return nil
        }
        var action: String { string("action")?.lowercased() ?? "" }
    }

    static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private static func fail(_ msg: String) -> ToolOutput {
        ToolOutput(result: json(["ok": false, "error": msg]), display: "⚠️ " + msg, ok: false)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy-MM-dd"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) {
                return fmt == "yyyy-MM-dd" ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) : d
            }
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        f.dateFormat = "HH:mm"
        if let t = f.date(from: s) {
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute], from: t)
            if var d = cal.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: Date()) {
                if d < Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
                return d
            }
        }
        return nil
    }

    // MARK: memo

    private static func memoJSON(_ m: Memo, full: Bool) -> [String: Any] {
        var d: [String: Any] = ["id": m.id.short, "title": m.title, "updated": dateFormatter.string(from: m.updatedAt)]
        d["content"] = full ? m.content : String(m.content.prefix(80))
        return d
    }

    private static func memo(_ a: Args, _ store: AgentStore) -> ToolOutput {
        switch a.action {
        case "create":
            guard let content = a.string("content") ?? a.string("title") else { return fail("缺少 content") }
            let m = store.addMemo(title: a.string("title") ?? "", content: content, byAI: true)
            return ToolOutput(result: json(["ok": true, "memo": memoJSON(m, full: false)]), display: "新建备忘「\(m.title)」")
        case "list":
            let list = store.sortedMemos.prefix(30).map { memoJSON($0, full: false) }
            return ToolOutput(result: json(["ok": true, "count": store.memos.count, "memos": Array(list)]), display: "查看了 \(store.memos.count) 条备忘")
        case "search":
            let q = (a.string("query") ?? "").lowercased()
            let hits = store.sortedMemos.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q) }
            return ToolOutput(result: json(["ok": true, "memos": hits.prefix(20).map { memoJSON($0, full: false) }]), display: "搜索备忘「\(q)」：\(hits.count) 条")
        case "read", "update", "append", "delete":
            guard let id = a.string("id"), let idx = store.memos.index(matchingShort: id) else { return fail("找不到该备忘，请先 list 获取 ID") }
            let m = store.memos[idx]
            switch a.action {
            case "read":
                return ToolOutput(result: json(["ok": true, "memo": memoJSON(m, full: true)]), display: "读取备忘「\(m.title)」")
            case "update":
                store.updateMemo(m.id) { x in
                    if let t = a.string("title") { x.title = t }
                    if let c = a.string("content") { x.content = c }
                }
                return ToolOutput(result: json(["ok": true]), display: "更新备忘「\(a.string("title") ?? m.title)」")
            case "append":
                guard let c = a.string("content") else { return fail("缺少 content") }
                store.updateMemo(m.id) { $0.content += ($0.content.isEmpty ? "" : "\n") + c }
                return ToolOutput(result: json(["ok": true]), display: "追加到备忘「\(m.title)」")
            default:
                store.deleteMemo(m.id)
                return ToolOutput(result: json(["ok": true]), display: "删除备忘「\(m.title)」")
            }
        default:
            return fail("不支持的操作 \(a.action)")
        }
    }

    // MARK: todo

    private static func todoJSON(_ t: TodoItem) -> [String: Any] {
        var d: [String: Any] = ["id": t.id.short, "title": t.title, "done": t.isDone]
        if let due = t.dueDate { d["due"] = dateFormatter.string(from: due) }
        if t.isHighPriority { d["high_priority"] = true }
        if !t.notes.isEmpty { d["notes"] = t.notes }
        return d
    }

    private static func dueDate(_ a: Args) -> Date? {
        if let m = a.double("due_in_minutes"), m > 0 { return Date().addingTimeInterval(m * 60) }
        if let s = a.string("due") { return parseDate(s) }
        return nil
    }

    private static func todo(_ a: Args, _ store: AgentStore) -> ToolOutput {
        switch a.action {
        case "add":
            guard let title = a.string("title") else { return fail("缺少 title") }
            let t = store.addTodo(title: title, notes: a.string("notes") ?? "", due: dueDate(a), highPriority: a.bool("high_priority") ?? false, byAI: true)
            var disp = "添加待办「\(t.title)」"
            if let d = t.dueDate { disp += " · \(dateFormatter.string(from: d))" }
            return ToolOutput(result: json(["ok": true, "todo": todoJSON(t)]), display: disp)
        case "list":
            let filter = a.string("filter") ?? "pending"
            let list: [TodoItem]
            switch filter {
            case "done": list = store.doneTodos
            case "all": list = store.pendingTodos + store.doneTodos
            default: list = store.pendingTodos
            }
            return ToolOutput(result: json(["ok": true, "todos": list.prefix(40).map(todoJSON)]), display: "查看待办（\(list.count) 项）")
        case "clear_completed":
            let n = store.doneTodos.count
            store.clearCompletedTodos()
            return ToolOutput(result: json(["ok": true, "cleared": n]), display: "清除了 \(n) 项已完成待办")
        case "complete", "reopen", "update", "delete":
            guard let id = a.string("id"), let idx = store.todos.index(matchingShort: id) else { return fail("找不到该待办，请先 list 获取 ID") }
            let t = store.todos[idx]
            switch a.action {
            case "complete":
                store.updateTodo(t.id) { $0.isDone = true }
                return ToolOutput(result: json(["ok": true]), display: "完成待办「\(t.title)」")
            case "reopen":
                store.updateTodo(t.id) { $0.isDone = false }
                return ToolOutput(result: json(["ok": true]), display: "重新打开「\(t.title)」")
            case "update":
                let due = dueDate(a)
                store.updateTodo(t.id) { x in
                    if let v = a.string("title") { x.title = v }
                    if let v = a.string("notes") { x.notes = v }
                    if let due { x.dueDate = due }
                    if let p = a.bool("high_priority") { x.isHighPriority = p }
                }
                return ToolOutput(result: json(["ok": true]), display: "修改待办「\(a.string("title") ?? t.title)」")
            default:
                store.deleteTodo(t.id)
                return ToolOutput(result: json(["ok": true]), display: "删除待办「\(t.title)」")
            }
        default:
            return fail("不支持的操作 \(a.action)")
        }
    }

    // MARK: timer

    private static func timerJSON(_ t: CountdownTimer) -> [String: Any] {
        ["id": t.id.short, "label": t.label, "state": t.state.rawValue,
         "remaining_seconds": Int(t.remaining().rounded()), "duration_seconds": Int(t.duration)]
    }

    private static func timer(_ a: Args, _ store: AgentStore) -> ToolOutput {
        func seconds() -> Double? {
            if let s = a.double("seconds"), s > 0 { return s }
            if let m = a.double("minutes"), m > 0 { return m * 60 }
            return nil
        }
        switch a.action {
        case "start":
            guard let secs = seconds() else { return fail("缺少时长 seconds 或 minutes") }
            let t = store.startTimer(seconds: secs, label: a.string("label") ?? "", byAI: true)
            return ToolOutput(result: json(["ok": true, "timer": timerJSON(t)]), display: "开始倒计时 \(AgentStore.formatDuration(secs))「\(t.label)」")
        case "list":
            let list = store.activeTimers
            return ToolOutput(result: json(["ok": true, "timers": list.map(timerJSON)]), display: "查看计时（\(list.count) 个）")
        case "pause", "resume", "cancel", "add_time":
            let active = store.activeTimers
            let idx: Int?
            if let id = a.string("id") { idx = store.timers.index(matchingShort: id) }
            else if active.count == 1 { idx = store.timers.firstIndex(where: { $0.id == active[0].id }) }
            else { idx = nil }
            guard let idx else { return fail("找不到该计时器，请先 list 获取 ID") }
            let t = store.timers[idx]
            switch a.action {
            case "pause":
                store.pauseTimer(t.id)
                return ToolOutput(result: json(["ok": true]), display: "暂停计时「\(t.label)」")
            case "resume":
                store.resumeTimer(t.id)
                return ToolOutput(result: json(["ok": true]), display: "继续计时「\(t.label)」")
            case "add_time":
                guard let secs = seconds() else { return fail("缺少时长") }
                store.addTime(t.id, seconds: secs)
                return ToolOutput(result: json(["ok": true]), display: "计时「\(t.label)」延长 \(AgentStore.formatDuration(secs))")
            default:
                store.cancelTimer(t.id)
                return ToolOutput(result: json(["ok": true]), display: "取消计时「\(t.label)」")
            }
        default:
            return fail("不支持的操作 \(a.action)")
        }
    }

    // MARK: memory

    private static func memory(_ a: Args, _ store: MemoryStore, conversationID: UUID) -> ToolOutput {
        func j(_ m: MemoryItem) -> [String: Any] { ["id": m.id.short, "content": m.content, "category": m.category, "enabled": m.isEnabled] }
        switch a.action {
        case "save":
            guard let c = a.string("content") else { return fail("缺少 content") }
            guard let m = store.add(c, category: a.string("category") ?? "其他", source: .tool, conversationID: conversationID) else { return fail("内容为空") }
            return ToolOutput(result: json(["ok": true, "memory": j(m)]), display: "记住：\(m.content)")
        case "list":
            let list = store.sorted.prefix(50).map(j)
            return ToolOutput(result: json(["ok": true, "memories": Array(list)]), display: "查看记忆（\(store.memories.count) 条）")
        case "search":
            let hits = store.search(a.string("query") ?? "")
            return ToolOutput(result: json(["ok": true, "memories": hits.prefix(20).map(j)]), display: "搜索记忆：\(hits.count) 条")
        case "update", "delete":
            guard let id = a.string("id"), let idx = store.memories.index(matchingShort: id) else { return fail("找不到该记忆") }
            let m = store.memories[idx]
            if a.action == "delete" {
                store.delete(m.id)
                return ToolOutput(result: json(["ok": true]), display: "忘记：\(m.content)")
            }
            store.update(m.id) { x in
                if let c = a.string("content") { x.content = c }
                if let c = a.string("category"), MemoryItem.categories.contains(c) { x.category = c }
            }
            return ToolOutput(result: json(["ok": true]), display: "更新记忆：\(a.string("content") ?? m.content)")
        default:
            return fail("不支持的操作 \(a.action)")
        }
    }

    // MARK: web

    private static func webFetch(_ a: Args) async -> ToolOutput {
        guard let s = a.string("url"), let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            return fail("无效网址")
        }
        let maxChars = Int(a.double("max_chars") ?? 6000)
        do {
            let page = try await WebReader.fetch(url)
            var text = page.markdown
            let truncated = text.count > maxChars
            if truncated { text = String(text.prefix(maxChars)) }
            return ToolOutput(result: json(["ok": true, "title": page.title, "url": page.url?.absoluteString ?? s,
                                            "truncated": truncated, "content": text]),
                              display: "读取网页「\(page.title.isEmpty ? (url.host ?? s) : page.title)」")
        } catch {
            return fail("网页读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: search

    private static func searchConversations(_ a: Args, _ store: ConversationStore, current: UUID) async -> ToolOutput {
        guard let q = a.string("query") else { return fail("缺少 query") }
        let limit = Int(a.double("limit") ?? 6)
        let hits = await SearchService.search(q, in: store, includeArchived: true, limit: limit, excluding: current)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let list = hits.map { h -> [String: Any] in
            ["conversation": h.conversationTitle, "date": df.string(from: h.date), "role": h.role == .user ? "用户" : "助手", "snippet": h.snippet]
        }
        return ToolOutput(result: json(["ok": true, "results": list]), display: "检索历史对话「\(q)」：\(hits.count) 条")
    }
}
