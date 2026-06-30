import Foundation
import Testing
@testable import CCCostCore

@Suite struct TimeLogicTests {

    // Fixed synthetic dates (verified against a Gregorian calendar):
    //   2026-06-08 Monday; 2026-06-29 Monday → 2026-07-05 Sunday (cross-month)
    //   2026-12-28 Monday → 2027-01-03 Sunday (cross-year)
    //   2024-01-01 Monday; 2026-01-01 Thursday; 2023-01-01 Sunday

    // MARK: formatDurationShort

    @Test func formatDurationShortBoundaries() {
        #expect(TimeLogic.formatDurationShort(0) == "0min")
        #expect(TimeLogic.formatDurationShort(-5) == "0min")
        // Nonzero seconds under a minute must not collapse to "0min"
        #expect(TimeLogic.formatDurationShort(59) == "1min")
        #expect(TimeLogic.formatDurationShort(60) == "1min")
        #expect(TimeLogic.formatDurationShort(1920) == "32min")
        #expect(TimeLogic.formatDurationShort(3599) == "59min")
        #expect(TimeLogic.formatDurationShort(3600) == "1.0hr")
        #expect(TimeLogic.formatDurationShort(5400) == "1.5hr")
        #expect(TimeLogic.formatDurationShort(12240) == "3.4hr")
    }

    // MARK: formatClock

    @Test func formatClockBoundaries() {
        #expect(TimeLogic.formatClock(0) == "00:00")
        #expect(TimeLogic.formatClock(6 * 3600) == "06:00")
        #expect(TimeLogic.formatClock(38266) == "10:37")
        #expect(TimeLogic.formatClock(86399) == "23:59")
        // End-of-day sentinel: an interval ending at midnight belongs to the
        // day it's stored under — render "24:00", never wrap to "00:00".
        #expect(TimeLogic.formatClock(86400) == "24:00")
    }

    // MARK: heatLevel

    @Test func heatLevelExactBoundaries() {
        #expect(TimeLogic.heatLevel(0) == 0)
        #expect(TimeLogic.heatLevel(1) == 1)
        #expect(TimeLogic.heatLevel(3599) == 1)
        #expect(TimeLogic.heatLevel(3600) == 2)     // 1h
        #expect(TimeLogic.heatLevel(10799) == 2)
        #expect(TimeLogic.heatLevel(10800) == 3)    // 3h
        #expect(TimeLogic.heatLevel(21599) == 3)
        #expect(TimeLogic.heatLevel(21600) == 4)    // 6h
        #expect(TimeLogic.heatLevel(86400) == 4)
    }

    // MARK: weekDayKeys

    @Test func weekDayKeysSimpleWeek() {
        let keys = TimeLogic.weekDayKeys(monday: makeDate(2026, 6, 8, hour: 0, minute: 0))
        #expect(keys == ["2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11",
                         "2026-06-12", "2026-06-13", "2026-06-14"])
    }

    @Test func weekDayKeysCrossMonth() {
        let keys = TimeLogic.weekDayKeys(monday: makeDate(2026, 6, 29, hour: 0, minute: 0))
        #expect(keys == ["2026-06-29", "2026-06-30", "2026-07-01", "2026-07-02",
                         "2026-07-03", "2026-07-04", "2026-07-05"])
    }

    @Test func weekDayKeysCrossYear() {
        let keys = TimeLogic.weekDayKeys(monday: makeDate(2026, 12, 28, hour: 0, minute: 0))
        #expect(keys == ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31",
                         "2027-01-01", "2027-01-02", "2027-01-03"])
    }

    // MARK: weeksOfMonth

    @Test func weeksOfMonthStartingMonday() {
        // 2026-06-01 is a Monday → the first week starts exactly on day 1.
        let mondays = TimeLogic.weeksOfMonth(year: 2026, month: 6).map(AppDate.dayKey)
        #expect(mondays == ["2026-06-01", "2026-06-08", "2026-06-15",
                            "2026-06-22", "2026-06-29"])
    }

    @Test func weeksOfMonthStartingSunday() {
        // 2026-02-01 is a Sunday → the first week's Monday is 2026-01-26
        // (previous month); the last week (2026-02-23) holds Feb 28, and the
        // Monday landing exactly on Mar 1's month is excluded.
        let mondays = TimeLogic.weeksOfMonth(year: 2026, month: 2).map(AppDate.dayKey)
        #expect(mondays == ["2026-01-26", "2026-02-02", "2026-02-09",
                            "2026-02-16", "2026-02-23"])
    }

    @Test func weeksOfMonthSpanningYearBoundary() {
        // December 2026: first week's Monday is 2026-11-30; the last week
        // (2026-12-28) runs through 2027-01-03 — included, since it overlaps
        // the month.
        let mondays = TimeLogic.weeksOfMonth(year: 2026, month: 12).map(AppDate.dayKey)
        #expect(mondays == ["2026-11-30", "2026-12-07", "2026-12-14",
                            "2026-12-21", "2026-12-28"])
    }

    // MARK: defaultWeekMonday

    @Test func defaultWeekMondayInCurrentMonth() throws {
        // Viewing the month containing today → the week containing today.
        let today = makeDate(2026, 6, 11)  // Thursday of the 2026-06-08 week
        let monday = try #require(TimeLogic.defaultWeekMonday(year: 2026, month: 6, today: today))
        #expect(AppDate.dayKey(monday) == "2026-06-08")
    }

    @Test func defaultWeekMondayInOtherMonth() throws {
        // Any other viewed month → its FIRST week, even when that Monday lives
        // in the previous month (Feb 2026 starts on a Sunday).
        let today = makeDate(2026, 6, 11)
        let feb = try #require(TimeLogic.defaultWeekMonday(year: 2026, month: 2, today: today))
        #expect(AppDate.dayKey(feb) == "2026-01-26")
        // Month starting exactly on a Monday → day 1 itself.
        let june = try #require(TimeLogic.defaultWeekMonday(
            year: 2026, month: 6, today: makeDate(2026, 7, 15)))
        #expect(AppDate.dayKey(june) == "2026-06-01")
    }

    @Test func defaultWeekMondayMatchesYearAndMonth() throws {
        // Same month number in a DIFFERENT year is not "the current month".
        let today = makeDate(2025, 6, 15)
        let monday = try #require(TimeLogic.defaultWeekMonday(year: 2026, month: 6, today: today))
        #expect(AppDate.dayKey(monday) == "2026-06-01")
    }

    // MARK: weekIndex

    @Test func weekIndexMatchesByDayKey() {
        let weeks = TimeLogic.weeksOfMonth(year: 2026, month: 6)
        // Matched by day key, so a non-midnight Date for the same Monday hits.
        #expect(TimeLogic.weekIndex(of: makeDate(2026, 6, 8, hour: 15), in: weeks) == 1)
        #expect(TimeLogic.weekIndex(of: makeDate(2026, 6, 29), in: weeks) == 4)
        // A Monday outside the month's week list (stale selection) → nil.
        #expect(TimeLogic.weekIndex(of: makeDate(2026, 5, 25), in: weeks) == nil)
        #expect(TimeLogic.weekIndex(of: makeDate(2026, 6, 8), in: []) == nil)
    }

    // MARK: week summary helpers

    @Test func totalAndLongestOverWeek() {
        let days: [String: DayTimeUsage] = [
            "2026-06-08": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 0, endSec: 600),
                            ActiveInterval(startSec: 1000, endSec: 1000)],  // zero-duration kept
                totalSeconds: 600),
            "2026-06-09": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 3600, endSec: 7200)],
                totalSeconds: 3600),
        ]
        let keys = TimeLogic.weekDayKeys(monday: makeDate(2026, 6, 8, hour: 0, minute: 0))
        #expect(TimeLogic.totalSeconds(in: days, dayKeys: keys) == 4200)
        #expect(TimeLogic.longestIntervalSeconds(in: days, dayKeys: keys) == 3600)
        // Missing days count zero; unrelated days are ignored
        #expect(TimeLogic.totalSeconds(in: days, dayKeys: ["2026-06-09"]) == 3600)
        #expect(TimeLogic.totalSeconds(in: [:], dayKeys: keys) == 0)
        #expect(TimeLogic.longestIntervalSeconds(in: [:], dayKeys: keys) == 0)
    }

    // MARK: year grid

    @Test func yearGridStartMondayForMondayStartYear() throws {
        // 2024-01-01 is itself a Monday → grid starts exactly on Jan 1.
        let start = try #require(TimeLogic.yearGridStartMonday(year: 2024))
        #expect(AppDate.dayKey(start) == "2024-01-01")
    }

    @Test func yearGridStartMondayForSundayStartYear() throws {
        // 2023-01-01 is a Sunday → Monday on/before is 2022-12-26.
        let start = try #require(TimeLogic.yearGridStartMonday(year: 2023))
        #expect(AppDate.dayKey(start) == "2022-12-26")
    }

    @Test func yearGridStartMondayForThursdayStartYear() throws {
        // 2026-01-01 is a Thursday → Monday on/before is 2025-12-29.
        let start = try #require(TimeLogic.yearGridStartMonday(year: 2026))
        #expect(AppDate.dayKey(start) == "2025-12-29")
    }

    @Test func gridPositionMapping() throws {
        let start = try #require(TimeLogic.yearGridStartMonday(year: 2026))  // 2025-12-29 Mon

        let origin = try #require(TimeLogic.gridPosition(dayKey: "2025-12-29", startMonday: start))
        #expect(origin == (col: 0, row: 0))

        // Jan 1 is the Thursday of column 0.
        let jan1 = try #require(TimeLogic.gridPosition(dayKey: "2026-01-01", startMonday: start))
        #expect(jan1 == (col: 0, row: 3))

        // Dec 31 2026 is a Thursday, 367 days after the grid origin → col 52.
        let dec31 = try #require(TimeLogic.gridPosition(dayKey: "2026-12-31", startMonday: start))
        #expect(dec31 == (col: 52, row: 3))
    }

    @Test func gridPositionOutOfBounds() throws {
        let start = try #require(TimeLogic.yearGridStartMonday(year: 2026))  // 2025-12-29 Mon
        // Before the grid origin
        #expect(TimeLogic.gridPosition(dayKey: "2025-12-28", startMonday: start) == nil)
        // 2027-01-04 is exactly column 53 (the Monday after the last column)
        #expect(TimeLogic.gridPosition(dayKey: "2027-01-04", startMonday: start) == nil)
        // Malformed / impossible keys
        #expect(TimeLogic.gridPosition(dayKey: "garbage", startMonday: start) == nil)
        #expect(TimeLogic.gridPosition(dayKey: "2026-02-30", startMonday: start) == nil)
    }

    @Test func gridDayKeyIsInverseOfGridPosition() throws {
        let start = try #require(TimeLogic.yearGridStartMonday(year: 2026))
        #expect(TimeLogic.dayKey(col: 0, row: 3, startMonday: start) == "2026-01-01")
        #expect(TimeLogic.dayKey(col: 52, row: 3, startMonday: start) == "2026-12-31")
        #expect(TimeLogic.dayKey(col: 0, row: 0, startMonday: start) == "2025-12-29")
    }

    // MARK: date(fromDayKey:)

    @Test func dateFromDayKeyRoundTripAndRejects() throws {
        let d = try #require(TimeLogic.date(fromDayKey: "2026-06-08"))
        #expect(AppDate.dayKey(d) == "2026-06-08")
        #expect(d == AppDate.gregorian.startOfDay(for: d))
        #expect(TimeLogic.date(fromDayKey: "2026-02-30") == nil)  // overflow must not normalize
        #expect(TimeLogic.date(fromDayKey: "2026-06") == nil)
        #expect(TimeLogic.date(fromDayKey: "") == nil)
    }

    // MARK: renderedDayKeys / avgDivisor

    private func day(_ secs: Int) -> DayTimeUsage { DayTimeUsage(intervals: [], totalSeconds: secs) }

    @Test func renderedDayKeysKeepsInMonthAndPayloadOnly() {
        // Week spanning a month boundary: May 30/31 then Jun 1..5.
        let keys = ["2026-05-30", "2026-05-31", "2026-06-01", "2026-06-02",
                    "2026-06-03", "2026-06-04", "2026-06-05"]
        // Viewing June; payload carries only one of the out-of-month days.
        let days = ["2026-05-31": day(60), "2026-06-02": day(120)]
        let rendered = TimeLogic.renderedDayKeys(keys, monthPrefix: "2026-06-", days: days)
        // All June days kept (even those with no payload), plus May 31 (has payload);
        // May 30 (out of month, no payload) dropped — no fabricated zero.
        #expect(rendered == ["2026-05-31", "2026-06-01", "2026-06-02",
                             "2026-06-03", "2026-06-04", "2026-06-05"])
    }

    @Test func avgDivisorCurrentWeekCountsElapsedDays() {
        let keys = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04",
                    "2026-06-05", "2026-06-06", "2026-06-07"]
        // Today is Wednesday (index 2) → divide by 3, not 7.
        #expect(TimeLogic.avgDivisor(dayKeys: keys, todayKey: "2026-06-03", renderedCount: 7) == 3)
    }

    @Test func avgDivisorPastWeekUsesRenderedCount() {
        let keys = ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07",
                    "2026-05-08", "2026-05-09", "2026-05-10"]
        // Fully past week (last day < today) → max(1, renderedCount).
        #expect(TimeLogic.avgDivisor(dayKeys: keys, todayKey: "2026-06-03", renderedCount: 4) == 4)
        #expect(TimeLogic.avgDivisor(dayKeys: keys, todayKey: "2026-06-03", renderedCount: 0) == 1)
    }

    @Test func avgDivisorFutureWeekIsOne() {
        let keys = ["2026-07-06", "2026-07-07", "2026-07-08", "2026-07-09",
                    "2026-07-10", "2026-07-11", "2026-07-12"]
        // First day already after today → 1 (the week renders all-zero anyway).
        #expect(TimeLogic.avgDivisor(dayKeys: keys, todayKey: "2026-06-03", renderedCount: 0) == 1)
    }
}
