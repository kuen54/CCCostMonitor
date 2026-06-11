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
