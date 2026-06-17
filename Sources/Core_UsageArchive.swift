import Foundation

// MARK: - Local usage archive — pure core
//
// A durable, monotonic, per-day aggregate of usage facts kept by the app so
// history survives Claude Code's transcript cleanup. Claude Code prunes
// ~/.claude/projects/**/*.jsonl on startup (cleanupPeriodDays, default 30) and
// the app re-derives everything from those transcripts each refresh — so once a
// day's sessions are pruned it silently drops out of Cost/Tokens and the Time
// year-heatmap. This archive accumulates the daily aggregates the app already
// computes (per-model token counts + the script-computed cost, plus active
// time) and serves them back for historical views even after the source is
// gone.
//
// CORRECTNESS INVARIANT (the whole reason this is a deliberate store and not
// "just keep the snapshots"): a PAST day's usage only ever GROWS as more of its
// sessions are discovered, and never shrinks — the only thing that lowers a
// recompute is pruning. So every merge is MONOTONIC: an incoming day/model
// observation replaces the stored one only when it is at least as complete
// (≥ tokens; ≥ active seconds for time). A partial scan, a failed scan, or the
// first scan after a cleanup can therefore never lower archived history — which
// is exactly what stops a post-cleanup recompute from clobbering the archive.
//
// Pure & Foundation-only (part of the CCCostCore test target): file I/O,
// threading, and the on/off preference live in the app-side `UsageArchive`.
// These statics are exercised directly by unit tests with synthetic fixtures.

/// One model class's token + cost aggregate for a single day.
struct ArchivedModel: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheRead: Int
    var cacheWrite: Int
    var messages: Int
    /// Cost as computed by the script at observation time. Carried alongside the
    /// tokens (rather than re-derived in Swift) so the archive needs no price
    /// table; kept consistent with the tokens by the "adopt the more-complete
    /// observation wholesale" merge rule below.
    var cost: Double
    var totalTokens: Int { inputTokens + outputTokens + cacheRead + cacheWrite }
}

/// All archived facts for one local day ("yyyy-MM-dd").
struct ArchivedDay: Codable, Equatable {
    /// Per model-class aggregate, keyed by `ModelClass.rawValue`.
    var models: [String: ArchivedModel]
    /// Largest active-second total ever observed for the day (a year scan
    /// yields seconds only; a month/range scan yields seconds + intervals).
    var timeSeconds: Int
    /// Gap-merged wall-clock intervals, present when a month/range scan observed
    /// them. nil = seconds are known but no interval detail (a year-scan-only
    /// day) — the heatmap (seconds) is still correct; the Week/Month interval
    /// charts simply have nothing to draw for that day.
    var timeIntervals: [ActiveInterval]?

    init(models: [String: ArchivedModel] = [:], timeSeconds: Int = 0,
         timeIntervals: [ActiveInterval]? = nil) {
        self.models = models
        self.timeSeconds = timeSeconds
        self.timeIntervals = timeIntervals
    }

    var totalCost: Double { models.values.reduce(0) { $0 + $1.cost } }
    var totalTokens: Int { models.values.reduce(0) { $0 + $1.totalTokens } }
}

/// The whole archive: schema version (for forward-compatible reads) + days.
struct UsageArchiveData: Codable, Equatable {
    static let currentSchema = 1
    var schemaVersion: Int
    var days: [String: ArchivedDay]

    init(schemaVersion: Int = UsageArchiveData.currentSchema,
         days: [String: ArchivedDay] = [:]) {
        self.schemaVersion = schemaVersion
        self.days = days
    }
}

/// Stateless merge + read transforms over `UsageArchiveData`. All merges are
/// monotonic and idempotent: re-merging the same observation is a no-op, and a
/// smaller observation never lowers a stored value.
enum UsageArchiveLogic {

    // MARK: Merges (monotonic)

    /// Adopt `incoming` over `stored` only when it is at least as complete.
    /// Token counts grow monotonically as a day's streamed/partial sessions are
    /// fully scanned, so "more tokens" == "more complete", and adopting the
    /// observation wholesale keeps cost/messages consistent with the tokens.
    /// `≥` (not `>`) so an equal-token re-scan can still pick up a re-priced
    /// cost without ever regressing the counts.
    private static func adopt(_ incoming: ArchivedModel, over stored: ArchivedModel?) -> ArchivedModel {
        guard let stored = stored else { return incoming }
        return incoming.totalTokens >= stored.totalTokens ? incoming : stored
    }

    /// Merge one day's per-model token/cost breakdown. Returns true if the
    /// archive changed (so callers can avoid needless disk writes).
    @discardableResult
    static func mergeDay(_ day: DailyUsage, into data: inout UsageArchiveData) -> Bool {
        var stored = data.days[day.dateString] ?? ArchivedDay()
        var changed = false
        for m in day.models {
            let incoming = ArchivedModel(
                inputTokens: m.inputTokens, outputTokens: m.outputTokens,
                cacheRead: m.cacheRead, cacheWrite: m.cacheWrite,
                messages: m.messages, cost: m.cost)
            // Don't create empty entries for all-zero classes.
            if incoming.totalTokens == 0 && incoming.messages == 0 && incoming.cost == 0
                && stored.models[m.id] == nil { continue }
            let merged = adopt(incoming, over: stored.models[m.id])
            if merged != stored.models[m.id] {
                stored.models[m.id] = merged
                changed = true
            }
        }
        if changed { data.days[day.dateString] = stored }
        return changed
    }

    /// Returns the set of day keys ("yyyy-MM-dd") whose archived value changed,
    /// so the caller can rewrite only the affected month shards. Empty = no-op.
    @discardableResult
    static func mergeDaily(_ daily: [DailyUsage]?, into data: inout UsageArchiveData) -> Set<String> {
        guard let daily = daily else { return [] }
        var changed: Set<String> = []
        for day in daily where mergeDay(day, into: &data) { changed.insert(day.dateString) }
        return changed
    }

    /// Merge full active-time days (seconds + intervals). A day's active
    /// coverage only grows, so adopt the larger-seconds observation along with
    /// its intervals. Returns the changed day keys.
    @discardableResult
    static func mergeTime(_ time: TimeData?, into data: inout UsageArchiveData) -> Set<String> {
        guard let time = time else { return [] }
        var changed: Set<String> = []
        for (key, dtu) in time.days {
            // The script emits empty days across the whole scan range for the
            // heatmap grid; don't archive no-activity days (the heatmap renders
            // missing keys as level 0 anyway).
            if dtu.totalSeconds == 0 && dtu.intervals.isEmpty { continue }
            var stored = data.days[key] ?? ArchivedDay()
            if dtu.totalSeconds >= stored.timeSeconds {
                let newIntervals = dtu.intervals
                if stored.timeSeconds != dtu.totalSeconds || stored.timeIntervals != newIntervals {
                    stored.timeSeconds = dtu.totalSeconds
                    stored.timeIntervals = newIntervals
                    data.days[key] = stored
                    changed.insert(key)
                }
            }
        }
        return changed
    }

    /// Merge per-day active seconds only (the `--time-year` payload, which has
    /// no interval detail). Bumps `timeSeconds` monotonically; leaves any
    /// existing intervals untouched. Returns the changed day keys.
    @discardableResult
    static func mergeYearSeconds(_ days: [String: Int], into data: inout UsageArchiveData) -> Set<String> {
        var changed: Set<String> = []
        for (key, seconds) in days where seconds > 0 {
            var stored = data.days[key] ?? ArchivedDay()
            if seconds > stored.timeSeconds {
                stored.timeSeconds = seconds
                data.days[key] = stored
                changed.insert(key)
            }
        }
        return changed
    }

    // MARK: Reads (overlay sources)

    /// Reconstruct a month's `[DailyUsage]` from the archive (sorted by day).
    /// `yearMonth` is the "yyyy-MM" prefix. Empty if the archive holds no
    /// token data for the month.
    static func dailyBreakdown(_ data: UsageArchiveData, yearMonth: String) -> [DailyUsage] {
        var result: [DailyUsage] = []
        for dateStr in data.days.keys.sorted() where dateStr.hasPrefix(yearMonth) {
            guard let day = data.days[dateStr], !day.models.isEmpty else { continue }
            var models: [ModelUsage] = []
            var totalTokens = 0
            var totalCost = 0.0
            for cls in ModelClass.allCases {
                guard let a = day.models[cls.rawValue] else { continue }
                if a.totalTokens == 0 && a.messages == 0 && a.cost == 0 { continue }
                models.append(ModelUsage(
                    id: cls.rawValue, name: cls.displayName,
                    cost: a.cost, messages: a.messages,
                    inputTokens: a.inputTokens, outputTokens: a.outputTokens,
                    cacheRead: a.cacheRead, cacheWrite: a.cacheWrite))
                totalTokens += a.totalTokens
                totalCost += a.cost
            }
            guard !models.isEmpty else { continue }
            let dayNum = Int(dateStr.suffix(2)) ?? 1
            result.append(DailyUsage(dateString: dateStr, day: dayNum,
                                     cost: totalCost, totalTokens: totalTokens, models: models))
        }
        return result
    }

    /// Reconstruct a month's active-time days from the archive. Days with no
    /// recorded time are omitted; year-scan-only days surface with empty
    /// intervals but a truthful `totalSeconds`.
    static func timeDays(_ data: UsageArchiveData, yearMonth: String) -> [String: DayTimeUsage] {
        var days: [String: DayTimeUsage] = [:]
        for (key, day) in data.days where key.hasPrefix(yearMonth) {
            let intervals = day.timeIntervals ?? []
            guard day.timeSeconds > 0 || !intervals.isEmpty else { continue }
            days[key] = DayTimeUsage(intervals: intervals, totalSeconds: day.timeSeconds)
        }
        return days
    }

    /// Per-day active seconds for a whole year (the year-heatmap overlay
    /// source). Only days with recorded time appear.
    static func yearSeconds(_ data: UsageArchiveData, year: Int) -> [String: Int] {
        let prefix = String(format: "%04d-", year)
        var days: [String: Int] = [:]
        for (key, day) in data.days where key.hasPrefix(prefix) && day.timeSeconds > 0 {
            days[key] = day.timeSeconds
        }
        return days
    }
}
