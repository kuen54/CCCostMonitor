import Foundation
import Testing
@testable import CCCostCore

@Suite struct UsageArchiveTests {

    // MARK: Fixtures

    private func model(_ cls: ModelClass, input: Int = 0, output: Int = 0,
                       cacheRead: Int = 0, cacheWrite: Int = 0,
                       messages: Int = 0, cost: Double = 0) -> ModelUsage {
        ModelUsage(id: cls.rawValue, name: cls.displayName, cost: cost, messages: messages,
                   inputTokens: input, outputTokens: output,
                   cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    private func day(_ date: String, _ models: [ModelUsage]) -> DailyUsage {
        let tokens = models.reduce(0) { $0 + $1.totalTokens }
        let cost = models.reduce(0.0) { $0 + $1.cost }
        let dayNum = Int(date.suffix(2)) ?? 1
        return DailyUsage(dateString: date, day: dayNum, cost: cost,
                          totalTokens: tokens, models: models)
    }

    private func timeData(_ days: [String: (Int, [(Int, Int)])]) -> TimeData {
        var out: [String: DayTimeUsage] = [:]
        for (k, v) in days {
            let intervals = v.1.map { ActiveInterval(startSec: $0.0, endSec: $0.1, model: nil) }
            out[k] = DayTimeUsage(intervals: intervals, totalSeconds: v.0)
        }
        return TimeData(gapMinutes: 10, days: out)
    }

    // MARK: Token merge — monotonic

    @Test func mergeIsMonotonicAndIdempotent() {
        var data = UsageArchiveData()
        let full = day("2026-05-01", [model(.opus, input: 1000, output: 200, messages: 5, cost: 5.0)])

        // The changed-key set drives which month shards get rewritten.
        #expect(UsageArchiveLogic.mergeDaily([full], into: &data) == ["2026-05-01"])
        // Re-merging the identical observation changes nothing.
        #expect(UsageArchiveLogic.mergeDaily([full], into: &data).isEmpty)

        // THE CLOBBER CASE: a post-cleanup recompute sees almost nothing for the
        // day. Monotonic merge must NOT lower the archived value.
        let pruned = day("2026-05-01", [model(.opus, input: 10, output: 2, messages: 1, cost: 0.05)])
        #expect(UsageArchiveLogic.mergeDaily([pruned], into: &data).isEmpty)
        let stored = data.days["2026-05-01"]?.models["opus"]
        #expect(stored?.inputTokens == 1000)
        #expect(stored?.cost == 5.0)

        // A MORE complete observation (more tokens) is adopted.
        let grown = day("2026-05-01", [model(.opus, input: 2000, output: 400, messages: 9, cost: 11.0)])
        #expect(UsageArchiveLogic.mergeDaily([grown], into: &data) == ["2026-05-01"])
        #expect(data.days["2026-05-01"]?.models["opus"]?.inputTokens == 2000)
        #expect(data.days["2026-05-01"]?.models["opus"]?.cost == 11.0)
    }

    @Test func modelClassesMergeIndependently() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeDaily([day("2026-05-02", [model(.opus, input: 1000, cost: 4)])], into: &data)
        // A later scan reports only Sonnet for the same day, plus a zeroed Opus
        // (e.g. a partial recompute). Opus must be preserved; Sonnet added.
        UsageArchiveLogic.mergeDaily([day("2026-05-02", [
            model(.opus, input: 0, cost: 0),
            model(.sonnet, input: 500, cost: 1),
        ])], into: &data)
        #expect(data.days["2026-05-02"]?.models["opus"]?.inputTokens == 1000)
        #expect(data.days["2026-05-02"]?.models["sonnet"]?.inputTokens == 500)
    }

    @Test func equalTokensAdoptsNewerCost() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeDaily([day("2026-05-03", [model(.haiku, input: 100, cost: 1.0)])], into: &data)
        // Same tokens, re-priced (LiteLLM updated). `>=` lets the newer cost in.
        let changed = UsageArchiveLogic.mergeDaily(
            [day("2026-05-03", [model(.haiku, input: 100, cost: 1.25)])], into: &data)
        #expect(changed == ["2026-05-03"])
        #expect(data.days["2026-05-03"]?.models["haiku"]?.cost == 1.25)
    }

    // MARK: Time merge — monotonic

    @Test func timeMergeKeepsLargestCoverage() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeTime(timeData(["2026-05-10": (3600, [(0, 3600)])]), into: &data)
        // Pruned recompute: fewer seconds → preserved (intervals intact).
        UsageArchiveLogic.mergeTime(timeData(["2026-05-10": (100, [(0, 100)])]), into: &data)
        #expect(data.days["2026-05-10"]?.timeSeconds == 3600)
        #expect(data.days["2026-05-10"]?.timeIntervals?.count == 1)
        #expect(data.days["2026-05-10"]?.timeIntervals?.first?.endSec == 3600)
        // More coverage → adopted with its intervals.
        UsageArchiveLogic.mergeTime(timeData(["2026-05-10": (7200, [(0, 7200)])]), into: &data)
        #expect(data.days["2026-05-10"]?.timeSeconds == 7200)
        #expect(data.days["2026-05-10"]?.timeIntervals?.first?.endSec == 7200)
    }

    @Test func yearSecondsMergeBumpsSecondsOnly() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeTime(timeData(["2026-05-11": (3600, [(0, 3600)])]), into: &data)
        // Year scan reports fewer seconds (pruned) → no change.
        #expect(UsageArchiveLogic.mergeYearSeconds(["2026-05-11": 100], into: &data).isEmpty)
        #expect(data.days["2026-05-11"]?.timeSeconds == 3600)
        // A day known ONLY from the year scan: seconds set, no intervals.
        #expect(UsageArchiveLogic.mergeYearSeconds(["2026-05-12": 1800], into: &data) == ["2026-05-12"])
        #expect(data.days["2026-05-12"]?.timeSeconds == 1800)
        #expect(data.days["2026-05-12"]?.timeIntervals == nil)
    }

    // MARK: Reads (overlay sources)

    @Test func dailyBreakdownReadFiltersAndSums() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeDaily([
            day("2026-04-30", [model(.opus, input: 50, cost: 0.5)]),
            day("2026-05-01", [model(.opus, input: 1000, cost: 5.0),
                               model(.sonnet, input: 200, cost: 1.0)]),
            day("2026-05-02", [model(.haiku, input: 300, cost: 0.3)]),
        ], into: &data)

        let may = UsageArchiveLogic.dailyBreakdown(data, yearMonth: "2026-05")
        #expect(may.map { $0.dateString } == ["2026-05-01", "2026-05-02"])
        #expect(may.first?.cost == 6.0)                 // 5.0 + 1.0
        #expect(may.first?.totalTokens == 1200)         // 1000 + 200
        // April is excluded by the month prefix.
        #expect(UsageArchiveLogic.dailyBreakdown(data, yearMonth: "2026-04").count == 1)
    }

    @Test func timeDaysReadIncludesYearOnlyDays() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeTime(timeData(["2026-05-10": (3600, [(0, 3600)])]), into: &data)
        UsageArchiveLogic.mergeYearSeconds(["2026-05-12": 1800], into: &data)

        let days = UsageArchiveLogic.timeDays(data, yearMonth: "2026-05")
        #expect(days["2026-05-10"]?.totalSeconds == 3600)
        #expect(days["2026-05-10"]?.intervals.count == 1)
        // Year-scan-only day surfaces with truthful seconds, empty intervals.
        #expect(days["2026-05-12"]?.totalSeconds == 1800)
        #expect(days["2026-05-12"]?.intervals.isEmpty == true)
    }

    @Test func yearSecondsReadFiltersByYear() {
        var data = UsageArchiveData()
        UsageArchiveLogic.mergeYearSeconds(
            ["2025-12-31": 600, "2026-01-01": 1200, "2026-06-17": 999], into: &data)
        let y2026 = UsageArchiveLogic.yearSeconds(data, year: 2026)
        #expect(y2026.count == 2)
        #expect(y2026["2026-01-01"] == 1200)
        #expect(y2026["2025-12-31"] == nil)
    }
}
