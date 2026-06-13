import Foundation

// MARK: - Usage JSON parsing & merging — pure core
//
// Stateless statics over the analyze_usage.py `--json` output dictionary.
// No process spawning, no file I/O, no Date() — fully testable with synthetic
// JSON fixtures. UsageStore owns orchestration/caching and calls into these.
enum UsageParser {

    /// Parse PeriodUsage from JSON (extracted from fetchPeriod for reuse)
    static func parsePeriod(_ json: [String: Any]) -> PeriodUsage? {
        let grandTotal = json["grand_total_cost"] as? Double ?? 0
        var models: [ModelUsage] = []
        var totalMessages = 0, totalTokens = 0

        if let totals = json["totals_by_model"] as? [String: Any] {
            for cls in ModelClass.allCases {
                guard let data = totals[cls.rawValue] as? [String: Any] else { continue }
                let inp  = data["input_tokens"] as? Int ?? 0
                let out  = data["output_tokens"] as? Int ?? 0
                let cr   = data["cache_read"] as? Int ?? 0
                let cw   = data["cache_write"] as? Int ?? 0
                let msgs = data["messages"] as? Int ?? 0
                let cost = data["cost"] as? Double ?? 0
                models.append(ModelUsage(
                    id: cls.rawValue, name: cls.displayName,
                    cost: cost, messages: msgs,
                    inputTokens: inp, outputTokens: out,
                    cacheRead: cr, cacheWrite: cw
                ))
                totalMessages += msgs
                totalTokens += inp + out + cr + cw
            }
        }
        return PeriodUsage(cost: grandTotal, models: models,
                           totalMessages: totalMessages, totalTokens: totalTokens)
    }

    /// Parse daily_breakdown from JSON (uses message-level timestamps from script)
    /// yearMonth: "YYYY-MM" prefix to filter (e.g. "2026-04")
    static func parseDailyBreakdown(_ json: [String: Any], yearMonth: String) -> [DailyUsage]? {
        guard let breakdown = json["daily_breakdown"] as? [String: Any], !breakdown.isEmpty else {
            return nil
        }
        var result: [DailyUsage] = []
        for dateStr in breakdown.keys.sorted() {
            guard dateStr.hasPrefix(yearMonth),
                  let dayData = breakdown[dateStr] as? [String: Any] else { continue }
            let dayCost = dayData["total_cost"] as? Double ?? 0
            var models: [ModelUsage] = []
            var totalTokens = 0
            if let modelsDict = dayData["models"] as? [String: Any] {
                for cls in ModelClass.allCases {
                    guard let data = modelsDict[cls.rawValue] as? [String: Any] else { continue }
                    let inp  = data["input_tokens"] as? Int ?? 0
                    let out  = data["output_tokens"] as? Int ?? 0
                    let cr   = data["cache_read"] as? Int ?? 0
                    let cw   = data["cache_write"] as? Int ?? 0
                    let msgs = data["messages"] as? Int ?? 0
                    let cost = data["cost"] as? Double ?? 0
                    models.append(ModelUsage(
                        id: cls.rawValue, name: cls.displayName,
                        cost: cost, messages: msgs,
                        inputTokens: inp, outputTokens: out,
                        cacheRead: cr, cacheWrite: cw
                    ))
                    totalTokens += inp + out + cr + cw
                }
            }
            let dayNum = Int(dateStr.suffix(2)) ?? 1
            result.append(DailyUsage(
                dateString: dateStr, day: dayNum,
                cost: dayCost, totalTokens: totalTokens, models: models
            ))
        }
        return result.isEmpty ? nil : result
    }

    /// Merge multiple DailyUsage entries into a single PeriodUsage
    static func mergeDailyUsages(_ days: [DailyUsage]) -> PeriodUsage {
        guard !days.isEmpty else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        var totalCost = 0.0
        var accum: [String: (inp: Int, out: Int, cr: Int, cw: Int, msgs: Int, cost: Double)] = [:]
        for day in days {
            totalCost += day.cost
            for m in day.models {
                let prev = accum[m.id] ?? (0, 0, 0, 0, 0, 0.0)
                accum[m.id] = (
                    inp: prev.inp + m.inputTokens, out: prev.out + m.outputTokens,
                    cr: prev.cr + m.cacheRead, cw: prev.cw + m.cacheWrite,
                    msgs: prev.msgs + m.messages, cost: prev.cost + m.cost
                )
            }
        }
        var models: [ModelUsage] = []
        var totalTokens = 0
        for cls in ModelClass.allCases {
            guard let a = accum[cls.rawValue] else { continue }
            models.append(ModelUsage(id: cls.rawValue, name: cls.displayName,
                                     cost: a.cost, messages: a.msgs,
                                     inputTokens: a.inp, outputTokens: a.out,
                                     cacheRead: a.cr, cacheWrite: a.cw))
            totalTokens += a.inp + a.out + a.cr + a.cw
        }
        return PeriodUsage(cost: totalCost, models: models,
                           totalMessages: models.reduce(0) { $0 + $1.messages },
                           totalTokens: totalTokens)
    }

    // MARK: Active time ("time" section / --time-year output)

    /// Parse the ADDITIVE top-level `"time"` section of a month/range scan:
    ///   {"gap_minutes": G, "days": {"yyyy-MM-dd": {"intervals": [[s,e,model|null],...],
    ///                                              "total_seconds": N}, ...}}
    /// Returns nil when the section is absent (old script / old cached JSON —
    /// the UI shows an empty state) or its top-level shape is wrong. Malformed
    /// individual days/entries are skipped, matching parseDailyBreakdown's
    /// lenient per-entry policy. A 2-element entry (stale bundled script) is
    /// accepted as model = nil; a non-string third element degrades to nil
    /// too — model is cosmetic, the duration is the truth worth keeping.
    static func parseTimeSection(_ json: [String: Any]) -> TimeData? {
        guard let section = json["time"] as? [String: Any],
              let gap = section["gap_minutes"] as? Int,
              let daysRaw = section["days"] as? [String: Any] else { return nil }
        var days: [String: DayTimeUsage] = [:]
        for (dayKey, value) in daysRaw {
            guard let dayDict = value as? [String: Any],
                  let entriesRaw = dayDict["intervals"] as? [Any],
                  let total = dayDict["total_seconds"] as? Int else { continue }
            var intervals: [ActiveInterval] = []
            for entryAny in entriesRaw {
                guard let entry = entryAny as? [Any], (2...3).contains(entry.count),
                      let s = entry[0] as? Int, let e = entry[1] as? Int,
                      s >= 0, s <= e, e <= 86400 else { continue }
                let model = entry.count == 3 ? entry[2] as? String : nil
                intervals.append(ActiveInterval(startSec: s, endSec: e, model: model))
            }
            days[dayKey] = DayTimeUsage(intervals: intervals, totalSeconds: total)
        }
        return TimeData(gapMinutes: gap, days: days)
    }

    /// Parse `--time-year YYYY` output:
    ///   {"year": YYYY, "gap_minutes": G, "days": {"yyyy-MM-dd": total_seconds}}
    /// Non-Int day values are skipped (lenient per-entry policy).
    static func parseYearTime(_ json: [String: Any]) -> (year: Int, gapMinutes: Int, days: [String: Int])? {
        guard let year = json["year"] as? Int,
              let gap = json["gap_minutes"] as? Int,
              let daysRaw = json["days"] as? [String: Any] else { return nil }
        var days: [String: Int] = [:]
        for (dayKey, value) in daysRaw {
            guard let seconds = value as? Int else { continue }
            days[dayKey] = seconds
        }
        return (year: year, gapMinutes: gap, days: days)
    }

    /// Merge the month scan's time days with the cross-week extra scan's:
    /// override days REPLACE base days. The cross-week scan's file set includes
    /// prev-month files pruned out of the month scan, so its per-day intervals
    /// for Monday..today are strictly more complete (a session bridging the
    /// month-start midnight shows up as a truthful [0, …] interval only there).
    /// gapMinutes is taken from base (both scans run with the same gap).
    static func mergeTimeData(base: TimeData?, override: TimeData?) -> TimeData? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        var merged = base
        merged.days.merge(override.days) { _, overrideDay in overrideDay }
        return merged
    }

    // MARK: Cache snapshot codec (pure — UsageStore owns the file I/O)

    /// Encode a MonthlySnapshot exactly like the on-disk cache format
    /// (~/.claude/cache/cc-monitor/YYYY-MM.json): JSONEncoder + ISO-8601 dates.
    static func encodeSnapshot(_ snapshot: MonthlySnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    /// Decode a MonthlySnapshot from the on-disk cache format.
    static func decodeSnapshot(_ data: Data) -> MonthlySnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MonthlySnapshot.self, from: data)
    }
}
