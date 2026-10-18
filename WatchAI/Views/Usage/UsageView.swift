import SwiftUI
import Charts

struct UsageView: View {
    @Environment(AppModel.self) private var app
    @State private var period: UsagePeriod = .today
    @State private var confirmReset = false
    @State private var showTokensChart = false

    var body: some View {
        let settings = app.settings
        let cur = settings.budgetCurrency
        let summary = app.usage.summary(period)
        List {
            Picker("周期", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.navigationLink)

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("费用").font(.caption2).foregroundStyle(.secondary)
                        Text(Fmt.money(summary.unifiedCost(in: cur, usdToCny: settings.usdToCny), cur))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                        if summary.costByCurrency.count > 1 {
                            Text(Fmt.moneyMap(summary.costByCurrency)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        StatTile(title: "请求", value: "\(summary.requests)", tint: .primary)
                        StatTile(title: "总 Tokens", value: TokenEstimator.format(summary.totalTokens), tint: .primary)
                    }
                    HStack(spacing: 4) {
                        StatTile(title: "输入", value: TokenEstimator.format(summary.promptTokens), tint: .blue)
                        StatTile(title: "输出", value: TokenEstimator.format(summary.completionTokens), tint: .orange)
                    }
                    if summary.cachedTokens > 0 {
                        let rate = summary.promptTokens > 0 ? Double(summary.cachedTokens) / Double(summary.promptTokens) : 0
                        Text("缓存命中 \(TokenEstimator.format(summary.cachedTokens))（\(Int(rate * 100))%）")
                            .font(.caption2).foregroundStyle(.teal)
                    }
                    if summary.estimatedCount > 0 {
                        Text("其中 \(summary.estimatedCount) 次为本地估算（接口未返回用量）").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .listRowBackground(Color.clear)
            }

            if settings.monthlyBudget > 0 {
                Section("本月预算") {
                    let spent = app.usage.monthCost(currency: cur, usdToCny: settings.usdToCny)
                    let ratio = spent / settings.monthlyBudget
                    Gauge(value: min(ratio, 1)) {
                        Text("预算")
                    } currentValueLabel: {
                        Text("\(Int(ratio * 100))%")
                    }
                    .gaugeStyle(.accessoryLinear)
                    .tint(ratio > 0.9 ? .red : ratio > 0.7 ? .orange : .green)
                    Text("\(Fmt.money(spent, cur)) / \(Fmt.money(settings.monthlyBudget, cur))")
                        .font(.caption2)
                    if ratio >= 1 {
                        Label("已超出本月预算", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    }
                }
            }

            Section {
                let days = period == .month || period == .all ? 30 : 7
                let data = app.usage.daily(days: days, currency: cur, usdToCny: settings.usdToCny)
                Chart(data) { d in
                    if showTokensChart {
                        BarMark(x: .value("日期", d.day, unit: .day), y: .value("Tokens", d.tokens))
                            .foregroundStyle(.blue.gradient)
                    } else {
                        BarMark(x: .value("日期", d.day, unit: .day), y: .value("费用", d.cost))
                            .foregroundStyle(.green.gradient)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days > 7 ? 7 : 2)) { _ in
                        AxisValueLabel(format: .dateTime.day(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 90)
                Button(showTokensChart ? "显示费用" : "显示 Tokens") { showTokensChart.toggle() }
                    .font(.caption2)
            } header: {
                Text(period == .month || period == .all ? "近 30 天" : "近 7 天")
            }

            let models = app.usage.byModel(period)
            if !models.isEmpty {
                Section("按模型") {
                    ForEach(models, id: \.model) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.model).font(.footnote).lineLimit(1)
                            Text("\(item.summary.requests) 次 · \(TokenEstimator.format(item.summary.totalTokens)) · \(Fmt.moneyMap(item.summary.costByCurrency))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let kinds = app.usage.byKind(period)
            if kinds.count > 1 {
                Section("按用途") {
                    ForEach(kinds, id: \.kind) { item in
                        HStack {
                            Text(item.kind.title).font(.footnote)
                            Spacer()
                            Text("\(TokenEstimator.format(item.summary.totalTokens)) · \(Fmt.moneyMap(item.summary.costByCurrency))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let convs = app.usage.byConversation(period).prefix(8)
            if !convs.isEmpty {
                Section("消耗最多的对话") {
                    ForEach(Array(convs), id: \.id) { item in
                        if let c = app.conversations.conversation(item.id) {
                            NavigationLink(value: Route.chat(c.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title).font(.footnote).lineLimit(1)
                                    Text("\(TokenEstimator.format(item.summary.totalTokens)) · \(Fmt.moneyMap(item.summary.costByCurrency))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("最近请求") {
                let recent = app.usage.records(in: period).suffix(30).reversed()
                if recent.isEmpty { Text("暂无记录").font(.caption2).foregroundStyle(.secondary) }
                ForEach(Array(recent)) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(r.model).font(.caption).lineLimit(1)
                            Spacer()
                            Text(Fmt.money(r.cost, r.currency)).font(.caption2.monospacedDigit())
                        }
                        Text("\(r.kind.title) · ↑\(r.promptTokens) ↓\(r.completionTokens)\(r.estimated ? "≈" : "") · \(Fmt.relative(r.date))")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }

            Section("计费设置") {
                NavigationLink {
                    BillingSettingsView()
                } label: {
                    Label("预算与汇率", systemImage: "yensign.circle")
                }
                NavigationLink(value: Route.providers) {
                    Label("模型单价", systemImage: "tag")
                }
                Button("清空统计数据", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("用量与计费")
        .confirmationDialog("清空全部用量记录？", isPresented: $confirmReset) {
            Button("清空", role: .destructive) { app.usage.reset() }
        }
    }
}

struct BillingSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = Binding(get: { app.settings }, set: { app.settings = $0 })
        List {
            Section {
                Picker("结算币种", selection: s.budgetCurrency) {
                    Text("人民币 ¥").tag("CNY")
                    Text("美元 $").tag("USD")
                }
                Stepper(value: s.monthlyBudget, in: 0...10000, step: app.settings.monthlyBudget < 50 ? 5 : 50) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("月预算").font(.caption2).foregroundStyle(.secondary)
                        Text(app.settings.monthlyBudget == 0 ? "未设置" : Fmt.money(app.settings.monthlyBudget, app.settings.budgetCurrency))
                            .font(.footnote)
                    }
                }
            } footer: {
                Text("设置后在用量页显示预算进度。")
            }
            Section {
                Stepper(value: s.usdToCny, in: 1...20, step: 0.05) {
                    Text(String(format: "1 USD = %.2f CNY", app.settings.usdToCny)).font(.footnote)
                }
            } header: {
                Text("汇率")
            } footer: {
                Text("用于把不同币种的费用合并显示。")
            }
        }
        .navigationTitle("预算与汇率")
    }
}
