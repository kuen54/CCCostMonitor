import Foundation
import Testing
@testable import CCCostCore

@Suite struct DateLogicTests {

    // Fixed synthetic week (verified against a Gregorian calendar):
    //   2026-06-08 Monday … 2026-06-10 Wednesday … 2026-06-14 Sunday
    //   2026-06-29 Monday → 2026-07-01 Wednesday (cross-month)
    //   2026-12-28 Monday → 2027-01-01 Friday   (cross-year)

    // MARK: dayKey / monthKey

    @Test func dayKeyAndMonthKeyAreGregorianASCII() {
        let d = makeDate(2026, 6, 8, hour: 0, minute: 0)
        #expect(AppDate.dayKey(d) == "2026-06-08")
        #expect(AppDate.monthKey(d) == "2026-06")
    }

    // MARK: mondayOfWeek

    @Test func mondayOfWeekFromWednesday() throws {
        let monday = try #require(AppDate.mondayOfWeek(containing: makeDate(2026, 6, 10)))
        #expect(AppDate.dayKey(monday) == "2026-06-08")
    }

    @Test func mondayOfWeekFromSundayGoesBackNotForward() throws {
        // Sunday belongs to the week that STARTED the previous Monday —
        // weekday==1 (Sun) must map 6 days back, never forward to tomorrow.
        let monday = try #require(AppDate.mondayOfWeek(containing: makeDate(2026, 6, 14)))
        #expect(AppDate.dayKey(monday) == "2026-06-08")
    }

    @Test func mondayOfWeekFromMondayItself() throws {
        let monday = try #require(AppDate.mondayOfWeek(containing: makeDate(2026, 6, 8, hour: 23, minute: 59)))
        #expect(AppDate.dayKey(monday) == "2026-06-08")
        // Must be normalized to local midnight (startOfDay)
        #expect(monday == AppDate.gregorian.startOfDay(for: monday))
    }

    @Test func mondayOfWeekCrossMonth() throws {
        // 2026-07-01 is a Wednesday; its Monday is back in June.
        let monday = try #require(AppDate.mondayOfWeek(containing: makeDate(2026, 7, 1)))
        #expect(AppDate.dayKey(monday) == "2026-06-29")
    }

    @Test func mondayOfWeekCrossYear() throws {
        // 2027-01-01 is a Friday; its Monday is back in December 2026.
        let monday = try #require(AppDate.mondayOfWeek(containing: makeDate(2027, 1, 1)))
        #expect(AppDate.dayKey(monday) == "2026-12-28")
    }

    // MARK: monthDateRange

    @Test func monthDateRangeLastDayOfMonth() {
        #expect(AppDate.monthDateRange(year: 2026, month: 4) == "2026-04-01:2026-04-30")
        #expect(AppDate.monthDateRange(year: 2026, month: 2) == "2026-02-01:2026-02-28")
        #expect(AppDate.monthDateRange(year: 2028, month: 2) == "2028-02-01:2028-02-29") // leap
        #expect(AppDate.monthDateRange(year: 2026, month: 12) == "2026-12-01:2026-12-31")
    }

    // MARK: deriveWeek

    @Test func deriveWeekSumsFromMondayOnward() {
        // now = Wednesday 2026-06-10. Buckets: previous-week Sunday (06-07)
        // must be EXCLUDED; Mon/Tue/Wed included. The 06-11 bucket pins the
        // legacy semantics: the filter has NO upper bound (dateString >=
        // monday only), so a future-dated bucket IS summed — by design,
        // since real daily breakdowns never contain future days.
        let daily = [
            makeDay("2026-06-07", cost: 100.0, totalTokens: 9999,
                    models: [makeModel(.sonnet, cost: 100.0, messages: 50, input: 5000, output: 4999)]),
            makeDay("2026-06-08", cost: 1.0, totalTokens: 20,
                    models: [makeModel(.sonnet, cost: 1.0, messages: 1, input: 10, output: 10)]),
            makeDay("2026-06-09", cost: 2.0, totalTokens: 40,
                    models: [makeModel(.sonnet, cost: 2.0, messages: 2, input: 20, output: 20)]),
            makeDay("2026-06-10", cost: 4.0, totalTokens: 20,
                    models: [makeModel(.opus, cost: 4.0, messages: 1, input: 5, output: 5,
                                       cacheRead: 5, cacheWrite: 5)]),
            makeDay("2026-06-11", cost: 8.0, totalTokens: 10,
                    models: [makeModel(.opus, cost: 8.0, messages: 1, input: 5, output: 5)]),
        ]
        let week = AppDate.deriveWeek(daily, now: makeDate(2026, 6, 10, hour: 18, minute: 30))
        #expect(approx(week.cost, 15.0))
        #expect(week.totalMessages == 5)
        #expect(week.totalTokens == 90)
        #expect(week.models.map(\.id) == ["opus", "sonnet"])
        #expect(approx(week.models[1].cost, 3.0))   // sonnet Mon+Tue
        #expect(week.models[1].messages == 3)
        #expect(approx(week.models[0].cost, 12.0))  // opus Wed + future Thu
    }

    @Test func deriveWeekNilOrEmptyDaily() {
        let now = makeDate(2026, 6, 10)
        #expect(AppDate.deriveWeek(nil, now: now).cost == 0)
        #expect(AppDate.deriveWeek(nil, now: now).models.isEmpty)
        #expect(AppDate.deriveWeek([], now: now).cost == 0)
    }

    // MARK: deriveToday

    @Test func deriveTodayPicksMatchingBucket() {
        let daily = [
            makeDay("2026-06-09", cost: 2.0, totalTokens: 40,
                    models: [makeModel(.sonnet, cost: 2.0, messages: 2, input: 20, output: 20)]),
            makeDay("2026-06-10", cost: 4.0, totalTokens: 20,
                    models: [makeModel(.opus, cost: 4.0, messages: 1, input: 5, output: 5,
                                       cacheRead: 5, cacheWrite: 5)]),
        ]
        let today = AppDate.deriveToday(daily, now: makeDate(2026, 6, 10, hour: 0, minute: 0))
        #expect(approx(today.cost, 4.0))
        #expect(today.totalMessages == 1)
        #expect(today.totalTokens == 20)
        #expect(today.models.map(\.id) == ["opus"])
    }

    @Test func deriveTodayExcludesYesterdayBucket() {
        // Only bucket present is dated yesterday → today must be all zeros.
        let daily = [
            makeDay("2026-06-09", cost: 2.0, totalTokens: 40,
                    models: [makeModel(.sonnet, cost: 2.0, messages: 2, input: 20, output: 20)]),
        ]
        let today = AppDate.deriveToday(daily, now: makeDate(2026, 6, 10))
        #expect(today.cost == 0)
        #expect(today.models.isEmpty)
        #expect(today.totalTokens == 0)
        #expect(today.totalMessages == 0)
    }

    @Test func deriveTodayNilDaily() {
        let today = AppDate.deriveToday(nil, now: makeDate(2026, 6, 10))
        #expect(today.cost == 0)
        #expect(today.models.isEmpty)
    }

    @Test func daysInMonthHandlesAllLengths() {
        #expect(AppDate.daysInMonth(year: 2026, month: 1) == 31)
        #expect(AppDate.daysInMonth(year: 2026, month: 4) == 30)
        #expect(AppDate.daysInMonth(year: 2026, month: 2) == 28)  // common year
        #expect(AppDate.daysInMonth(year: 2024, month: 2) == 29)  // leap year
        #expect(AppDate.daysInMonth(year: 2000, month: 2) == 29)  // div-by-400 leap
        #expect(AppDate.daysInMonth(year: 1900, month: 2) == 28)  // div-by-100 non-leap
        #expect(AppDate.daysInMonth(year: 2026, month: 12) == 31)
    }

    @Test func monthDateRangeUsesDaysInMonth() {
        #expect(AppDate.monthDateRange(year: 2026, month: 2) == "2026-02-01:2026-02-28")
        #expect(AppDate.monthDateRange(year: 2024, month: 2) == "2024-02-01:2024-02-29")
        #expect(AppDate.monthDateRange(year: 2026, month: 4) == "2026-04-01:2026-04-30")
    }
}
