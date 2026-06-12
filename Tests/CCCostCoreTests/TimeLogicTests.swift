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
        #expect(TimeLogic.formatDurationShort(0) == "0m")
        #expect(TimeLogic.formatDurationShort(-5) == "0m")
        // Nonzero seconds under a minute must not collapse to "0m"
        #expect(TimeLogic.formatDurationShort(59) == "1m")
        #expect(TimeLogic.formatDurationShort(60) == "1m")
        #expect(TimeLogic.formatDurationShort(1920) == "32m")
        #expect(TimeLogic.formatDurationShort(3599) == "59m")
        #expect(TimeLogic.formatDurationShort(3600) == "1.0h")
        #expect(TimeLogic.formatDurationShort(5400) == "1.5h")
        #expect(TimeLogic.formatDurationShort(12240) == "3.4h")
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
}
