import Foundation

// MARK: - Data Models — pure core
//
// Foundation-only on purpose: these structs are part of the pure testable core
// (consumed by Core_UsageParser / Core_DateLogic and the SPM test target).
// UI concerns (ModelUsage.color / .icon) live in a Views.swift extension.
// App-only models (OAuth quota, DisplayTab) stay in Models.swift.

struct ModelUsage: Identifiable, Codable {
    let id: String
    let name: String
    let cost: Double
    let messages: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cacheWrite: Int
    var totalTokens: Int { inputTokens + outputTokens + cacheRead + cacheWrite }
}

struct PeriodUsage: Codable {
    let cost: Double
    let models: [ModelUsage]
    let totalMessages: Int
    let totalTokens: Int

    var totalInput: Int { models.reduce(0) { $0 + $1.inputTokens } }
    var totalOutput: Int { models.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheRead: Int { models.reduce(0) { $0 + $1.cacheRead } }
    var totalCacheWrite: Int { models.reduce(0) { $0 + $1.cacheWrite } }
}

struct DailyUsage: Codable, Identifiable {
    var id: String { dateString }
    let dateString: String   // "2026-04-01"
    let day: Int             // 1..31
    let cost: Double
    let totalTokens: Int
    let models: [ModelUsage]
}

struct MonthlySnapshot: Codable {
    let year: Int
    let month: Int
    let data: PeriodUsage
    let lastUpdated: Date
    var dailyBreakdown: [DailyUsage]?
    /// Cross-month-safe "This Week" totals persisted alongside the month data:
    /// when the week's Monday falls in the previous month, the month scan
    /// (1st..today) can't cover those days, so the derived week would undercount.
    /// Optional so caches written by older versions still decode.
    var week: PeriodUsage?
    /// "yyyy-MM-dd" Monday of the week `week` covers — staleness check on restore.
    var weekStart: String?
}
