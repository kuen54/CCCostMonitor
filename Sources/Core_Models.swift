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
    /// Active-time intervals for the snapshot's days (additive "time" section of
    /// the script JSON, plus cross-week extra-scan days when the week spans a
    /// month boundary). Optional so caches written by older versions still decode.
    var time: TimeData?
}

// MARK: - Active time ("Time" tab)

/// One gap-merged active interval within a single local day, stored as
/// wall-clock seconds-of-day. `endSec` may be 86400 (next-midnight sentinel for
/// intervals split at a day boundary); `startSec == endSec` is a truthful
/// zero-duration interval (isolated single event) — the renderer pads it.
struct ActiveInterval: Codable, Equatable {
    let startSec: Int
    let endSec: Int
    /// Dominant model class for the interval ("fable"/"opus"/"sonnet"/"haiku"/
    /// "other"). nil = no model-tagged event in the interval (user-only) or a
    /// pre-attribution payload. Cosmetic only — never affects durations.
    let model: String?
    var durationSeconds: Int { endSec - startSec }

    init(startSec: Int, endSec: Int, model: String? = nil) {
        self.startSec = startSec
        self.endSec = endSec
        self.model = model
    }

    // Codable form mirrors the script's compact array [start, end, model|null]
    // so the snapshot cache and the wire JSON stay one shape. A 2-element
    // array decodes as model = nil — robustness against a stale bundled
    // script still emitting the pre-attribution pairs.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        startSec = try container.decode(Int.self)
        endSec = try container.decode(Int.self)
        model = container.isAtEnd ? nil : try container.decodeIfPresent(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(startSec)
        try container.encode(endSec)
        try container.encode(model)
    }
}

struct DayTimeUsage: Codable, Equatable {
    let intervals: [ActiveInterval]
    let totalSeconds: Int
}

/// Decoded `"time"` section of the script's month JSON: per-day gap-merged
/// active intervals. Keys are "yyyy-MM-dd" local day keys.
struct TimeData: Codable, Equatable {
    let gapMinutes: Int
    var days: [String: DayTimeUsage]
}
