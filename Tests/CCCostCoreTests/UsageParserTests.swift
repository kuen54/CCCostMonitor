import Foundation
import Testing
@testable import CCCostCore

@Suite struct UsageParserTests {

    /// Synthetic analyze_usage.py --json payload. Numbers are hand-checkable:
    ///   fable  tokens 100+200+300+400 = 1000, 5 msgs, $1.50
    ///   opus   tokens  10+20+30+40   =  100, 2 msgs, $2.00
    ///   sonnet tokens   1+2+3+4      =   10, 1 msg,  $0.25
    ///   other  tokens 1000+0+0+0     = 1000, 3 msgs, $0.75  (output/cache keys absent)
    ///   haiku  absent entirely (must be tolerated, not crash)
    ///   grand total = $4.50, tokens = 2110, messages = 11
    let payload = jsonDict("""
    {
      "script_version": "0.0.0-test",
      "range": "2026-04-01:2026-04-30",
      "sessions": [
        {"project": "/tmp/demo-project", "total_cost": 4.5}
      ],
      "grand_total_cost": 4.5,
      "totals_by_model": {
        "fable":  {"input_tokens": 100,  "output_tokens": 200, "cache_read": 300, "cache_write": 400, "messages": 5, "cost": 1.5},
        "opus":   {"input_tokens": 10,   "output_tokens": 20,  "cache_read": 30,  "cache_write": 40,  "messages": 2, "cost": 2.0},
        "sonnet": {"input_tokens": 1,    "output_tokens": 2,   "cache_read": 3,   "cache_write": 4,   "messages": 1, "cost": 0.25},
        "other":  {"input_tokens": 1000, "messages": 3, "cost": 0.75}
      },
      "daily_breakdown": {
        "2026-04-01": {"total_cost": 1.0, "models": {"sonnet": {"input_tokens": 10, "output_tokens": 20, "cache_read": 0, "cache_write": 0, "messages": 1, "cost": 1.0}}},
        "2026-04-09": "garbage-not-a-dict",
        "2026-04-15": {"total_cost": 2.0, "models": {"opus": {"input_tokens": 5, "output_tokens": 5, "cache_read": 5, "cache_write": 5, "messages": 2, "cost": 2.0}}},
        "2026-04-20": {"total_cost": 0.5, "models": {"sonnet": "also-garbage", "mystery-model": {"input_tokens": 7, "messages": 1, "cost": 0.5}}},
        "2026-05-01": {"total_cost": 99.0, "models": {"sonnet": {"input_tokens": 999, "output_tokens": 999, "messages": 9, "cost": 99.0}}}
      }
    }
    """)

    // MARK: parsePeriod

    @Test func parsePeriodTotalsPerModelClassIncludingOther() throws {
        let p = try #require(UsageParser.parsePeriod(payload))
        #expect(approx(p.cost, 4.5))
        #expect(p.totalMessages == 11)
        #expect(p.totalTokens == 2110)

        // haiku is absent from totals_by_model → skipped; order follows ModelClass.allCases
        #expect(p.models.map(\.id) == ["fable", "opus", "sonnet", "other"])
        #expect(p.models.map(\.name) == ["Fable", "Opus", "Sonnet", "Other"])

        let fable = p.models[0]
        #expect(fable.inputTokens == 100)
        #expect(fable.outputTokens == 200)
        #expect(fable.cacheRead == 300)
        #expect(fable.cacheWrite == 400)
        #expect(fable.messages == 5)
        #expect(approx(fable.cost, 1.5))
        #expect(fable.totalTokens == 1000)

        // "other" entry is missing output/cache keys → they default to 0
        let other = p.models[3]
        #expect(other.inputTokens == 1000)
        #expect(other.outputTokens == 0)
        #expect(other.cacheRead == 0)
        #expect(other.cacheWrite == 0)
        #expect(approx(other.cost, 0.75))
    }

    @Test func parsePeriodMissingTotalsByModel() throws {
        let p = try #require(UsageParser.parsePeriod(jsonDict(#"{"grand_total_cost": 3.25}"#)))
        #expect(approx(p.cost, 3.25))
        #expect(p.models.isEmpty)
        #expect(p.totalMessages == 0)
        #expect(p.totalTokens == 0)
    }

    @Test func parsePeriodEmptyJSON() throws {
        let p = try #require(UsageParser.parsePeriod([:]))
        #expect(p.cost == 0)
        #expect(p.models.isEmpty)
    }

    // MARK: parseDailyBreakdown

    @Test func parseDailyBreakdownMonthFilterAndMalformedEntries() throws {
        let days = try #require(UsageParser.parseDailyBreakdown(payload, yearMonth: "2026-04"))

        // 2026-05-01 filtered out (month mismatch); 2026-04-09 (not a dict) skipped;
        // 2026-04-20 survives but with empty models (model value not a dict /
        // unknown class key both ignored). Sorted ascending by date.
        #expect(days.map(\.dateString) == ["2026-04-01", "2026-04-15", "2026-04-20"])
        #expect(days.map(\.day) == [1, 15, 20])

        #expect(approx(days[0].cost, 1.0))
        #expect(days[0].totalTokens == 30)
        #expect(days[0].models.map(\.id) == ["sonnet"])

        #expect(days[1].totalTokens == 20)
        #expect(days[1].models.map(\.id) == ["opus"])

        #expect(approx(days[2].cost, 0.5))
        #expect(days[2].models.isEmpty)
        #expect(days[2].totalTokens == 0)
    }

    @Test func parseDailyBreakdownNoMatchReturnsNil() {
        #expect(UsageParser.parseDailyBreakdown(payload, yearMonth: "2026-03") == nil)
        #expect(UsageParser.parseDailyBreakdown([:], yearMonth: "2026-04") == nil)
        #expect(UsageParser.parseDailyBreakdown(jsonDict(#"{"daily_breakdown": {}}"#),
                                                yearMonth: "2026-04") == nil)
    }

    // MARK: mergeDailyUsages

    @Test func mergeDailyUsagesAccumulatesPerClassInLegacyOrder() {
        let days = [
            makeDay("2026-04-01", cost: 1.0, totalTokens: 30,
                    models: [makeModel(.sonnet, cost: 1.0, messages: 1, input: 10, output: 20)]),
            makeDay("2026-04-02", cost: 4.0, totalTokens: 60,
                    models: [makeModel(.sonnet, cost: 2.0, messages: 2, input: 10, output: 10),
                             makeModel(.opus, cost: 2.0, messages: 1, input: 10, output: 10,
                                       cacheRead: 10, cacheWrite: 10)]),
        ]
        let merged = UsageParser.mergeDailyUsages(days)
        #expect(approx(merged.cost, 5.0))
        #expect(merged.totalMessages == 4)
        #expect(merged.totalTokens == 90)
        // opus before sonnet (ModelClass.allCases order), regardless of input order
        #expect(merged.models.map(\.id) == ["opus", "sonnet"])
        #expect(merged.models[1].inputTokens == 20)
        #expect(merged.models[1].outputTokens == 30)
        #expect(merged.models[1].messages == 3)
        #expect(approx(merged.models[1].cost, 3.0))
    }

    @Test func mergeDailyUsagesEmpty() {
        let merged = UsageParser.mergeDailyUsages([])
        #expect(merged.cost == 0)
        #expect(merged.models.isEmpty)
    }

    // MARK: snapshot codec

    @Test func snapshotEncodeDecodeRoundTrip() throws {
        let snapshot = MonthlySnapshot(
            year: 2026, month: 4,
            data: PeriodUsage(cost: 4.5,
                              models: [makeModel(.opus, cost: 4.5, messages: 2, input: 10, output: 20)],
                              totalMessages: 2, totalTokens: 30),
            lastUpdated: makeDate(2026, 4, 30, hour: 23, minute: 59),
            dailyBreakdown: [makeDay("2026-04-01", cost: 4.5, totalTokens: 30,
                                     models: [makeModel(.opus, cost: 4.5, messages: 2, input: 10, output: 20)])],
            week: PeriodUsage(cost: 1.0, models: [], totalMessages: 0, totalTokens: 0),
            weekStart: "2026-04-27"
        )
        let data = try #require(UsageParser.encodeSnapshot(snapshot))
        let decoded = try #require(UsageParser.decodeSnapshot(data))
        #expect(decoded.year == 2026)
        #expect(decoded.month == 4)
        #expect(approx(decoded.data.cost, 4.5))
        #expect(decoded.dailyBreakdown?.first?.dateString == "2026-04-01")
        #expect(approx(decoded.week?.cost ?? -1, 1.0))
        #expect(decoded.weekStart == "2026-04-27")
        // ISO-8601 strategy has 1-second granularity; identity within a second
        #expect(abs(decoded.lastUpdated.timeIntervalSince(snapshot.lastUpdated)) < 1.0)
    }
}
