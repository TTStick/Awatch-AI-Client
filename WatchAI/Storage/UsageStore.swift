import Foundation
import Observation

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "今日"
        case .week: return "7 天"
        case .month: return "本月"
        case .all: return "全部"
        }
    }

    var startDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))
        case .month: return cal.date(from: cal.dateComponents([.year, .month], from: now))
        case .all: return nil
        }
    }
}

struct UsageSummary {
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
    var cachedTokens = 0
    var costByCurrency: [String: Double] = [:]
    var estimatedCount = 0

    var totalTokens: Int { promptTokens + completionTokens }

    mutating func add(_ r: UsageRecord) {
        requests += 1
        promptTokens += r.promptTokens
        completionTokens += r.completionTokens
        cachedTokens += r.cachedTokens
        costByCurrency[r.currency, default: 0] += r.cost
        if r.estimated { estimatedCount += 1 }
    }

    func unifiedCost(in currency: String, usdToCny: Double) -> Double {
        costByCurrency.reduce(0) { acc, kv in
            acc + UsageStore.convert(kv.value, from: kv.key, to: currency, usdToCny: usdToCny)
        }
    }
}

struct DailyCost: Identifiable {
    var day: Date
    var cost: Double
    var tokens: Int
    var id: Date { day }
}

@MainActor
@Observable
final class UsageStore {
    private(set) var records: [UsageRecord] = []
    private let file = "usage.json"
    @ObservationIgnored private var saveScheduled = false

    init() {
        records = FileStore.load([UsageRecord].self, from: file) ?? []
    }

    func add(_ record: UsageRecord) {
        records.append(record)
        scheduleSave()
    }

    func reset() {
        records = []
        FileStore.save(records, to: file)
    }

    func records(in period: UsagePeriod) -> [UsageRecord] {
        guard let start = period.startDate else { return records }
        return records.filter { $0.date >= start }
    }

    func summary(_ period: UsagePeriod) -> UsageSummary {
        var s = UsageSummary()
        for r in records(in: period) { s.add(r) }
        return s
    }

    func summary(conversation id: UUID) -> UsageSummary {
        var s = UsageSummary()
        for r in records where r.conversationID == id { s.add(r) }
        return s
    }

    func byModel(_ period: UsagePeriod) -> [(model: String, summary: UsageSummary)] {
        var dict: [String: UsageSummary] = [:]
        for r in records(in: period) { dict[r.model, default: UsageSummary()].add(r) }
        return dict.map { ($0.key, $0.value) }.sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    func byKind(_ period: UsagePeriod) -> [(kind: UsageKind, summary: UsageSummary)] {
        var dict: [UsageKind: UsageSummary] = [:]
        for r in records(in: period) { dict[r.kind, default: UsageSummary()].add(r) }
        return dict.map { ($0.key, $0.value) }.sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    func byConversation(_ period: UsagePeriod) -> [(id: UUID, summary: UsageSummary)] {
        var dict: [UUID: UsageSummary] = [:]
        for r in records(in: period) {
            guard let cid = r.conversationID else { continue }
            dict[cid, default: UsageSummary()].add(r)
        }
        return dict.map { ($0.key, $0.value) }.sorted { $0.summary.totalTokens > $1.summary.totalTokens }
    }

    func daily(days: Int, currency: String, usdToCny: Double) -> [DailyCost] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets: [Date: (Double, Int)] = [:]
        for i in 0..<days {
            if let d = cal.date(byAdding: .day, value: -i, to: today) { buckets[d] = (0, 0) }
        }
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        for r in records where r.date >= start {
            let d = cal.startOfDay(for: r.date)
            let c = Self.convert(r.cost, from: r.currency, to: currency, usdToCny: usdToCny)
            let cur = buckets[d] ?? (0, 0)
            buckets[d] = (cur.0 + c, cur.1 + r.totalTokens)
        }
        return buckets.map { DailyCost(day: $0.key, cost: $0.value.0, tokens: $0.value.1) }.sorted { $0.day < $1.day }
    }

    func monthCost(currency: String, usdToCny: Double) -> Double {
        summary(.month).unifiedCost(in: currency, usdToCny: usdToCny)
    }

    nonisolated static func convert(_ value: Double, from: String, to: String, usdToCny: Double) -> Double {
        if from == to { return value }
        if from == "USD" && to == "CNY" { return value * usdToCny }
        if from == "CNY" && to == "USD" { return usdToCny > 0 ? value / usdToCny : value }
        return value
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            FileStore.save(self.records, to: self.file)
        }
    }

    func saveNow() { FileStore.save(records, to: file) }
}
