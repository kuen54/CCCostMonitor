import Foundation

// MARK: - Active-time formatting / bucketing / grid math — pure core
//
// Foundation-only statics for the Time tab: duration formatting, heatmap level
// bucketing, week-row day keys, and the 53×7 Monday-first year grid. No Date()
// inside function bodies — callers pass explicit dates so tests stay
// deterministic. All calendar math goes through AppDate's pinned Gregorian
// calendar (data-path keys must match the Python script's local-date buckets).
enum TimeLogic {

    // MARK: Duration / clock formatting

    /// Short duration for the menu bar and per-row totals: "0min" for none,
    /// "32min" under an hour (floor, but nonzero seconds never round down to
    /// "0min"), "3.4hr" from one hour up. Locale-neutral by design (digits +
    /// unit letters only) — no i18n keys needed.
    static func formatDurationShort(_ seconds: Int) -> String {
        if seconds <= 0 { return "0min" }
        if seconds < 3600 { return "\(max(1, seconds / 60))min" }
        return String(format: "%.1fhr", Double(seconds) / 3600.0)
    }

    /// "HH:MM" wall clock from seconds-of-local-day for interval tooltips.
    /// 86400 (the end-of-day sentinel) renders as "24:00", not "00:00" —
    /// an interval ending at midnight belongs to the day it's stored under.
    static func formatClock(_ secondsOfDay: Int) -> String {
        let s = min(max(secondsOfDay, 0), 86400)
        return String(format: "%02d:%02d", s / 3600, (s % 3600) / 60)
    }

    // MARK: Year-heatmap level bucketing

    /// 5 fixed levels for the GitHub-style heatmap:
    /// 0 → none, 1 → <1h, 2 → 1–3h, 3 → 3–6h, 4 → ≥6h.
    static func heatLevel(_ seconds: Int) -> Int {
        if seconds <= 0 { return 0 }
        if seconds < 3600 { return 1 }
        if seconds < 10800 { return 2 }
        if seconds < 21600 { return 3 }
        return 4
    }

    // MARK: Week rows (Mon–Sun)

    /// The 7 consecutive "yyyy-MM-dd" day keys of the week starting at
    /// `monday` (callers obtain it via AppDate.mondayOfWeek). Crosses month
    /// and year boundaries via calendar arithmetic, never string math.
    static func weekDayKeys(monday: Date) -> [String] {
        let cal = AppDate.gregorian
        return (0..<7).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: monday).map(AppDate.dayKey)
        }
    }

    // MARK: Weeks of a month (Monday-aligned)

    /// Local-midnight Mondays of every Monday-aligned week OVERLAPPING the
    /// given month — the shared week list behind the Month chart's rows and
    /// the Week view's ◀▶ navigation. The first entry is the Monday on or
    /// before day 1 (may live in the previous month); the last entry's week
    /// contains the month's final day (may reach into the next month / year).
    /// Empty only on calendar arithmetic failure.
    static func weeksOfMonth(year: Int, month: Int) -> [Date] {
        let cal = AppDate.gregorian
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let first = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: first),
              var monday = AppDate.mondayOfWeek(containing: first) else { return [] }
        var mondays: [Date] = []
        while monday < nextMonth {
            mondays.append(monday)
            guard let next = cal.date(byAdding: .day, value: 7, to: monday) else { break }
            monday = next
        }
        return mondays
    }

    /// Default selected week for the Week view when the user hasn't navigated:
    /// viewing the month containing `today` → the week containing today; any
    /// other month → the month's FIRST week (the Monday-aligned week holding
    /// day 1). nil only on calendar arithmetic failure.
    static func defaultWeekMonday(year: Int, month: Int, today: Date) -> Date? {
        let cal = AppDate.gregorian
        if cal.component(.year, from: today) == year,
           cal.component(.month, from: today) == month {
            return AppDate.mondayOfWeek(containing: today)
        }
        return weeksOfMonth(year: year, month: month).first
    }

    /// Index of `monday`'s week within `weeks`, matched by day key — Date
    /// equality is too strict across separately derived values (a stored
    /// selection vs a freshly computed week list). nil when absent.
    static func weekIndex(of monday: Date, in weeks: [Date]) -> Int? {
        let key = AppDate.dayKey(monday)
        return weeks.firstIndex { AppDate.dayKey($0) == key }
    }

    // MARK: Week summary helpers

    /// Sum of totalSeconds over the given day keys (missing days count 0).
    static func totalSeconds(in days: [String: DayTimeUsage], dayKeys: [String]) -> Int {
        dayKeys.reduce(0) { $0 + (days[$1]?.totalSeconds ?? 0) }
    }

    /// Longest single stored interval over the given day keys. Note: an
    /// interval bridging local midnight is stored split per day, so this is
    /// the longest within-day piece — consistent with what the week chart
    /// renders on its 0–24h axis.
    static func longestIntervalSeconds(in days: [String: DayTimeUsage], dayKeys: [String]) -> Int {
        var longest = 0
        for key in dayKeys {
            for interval in days[key]?.intervals ?? [] {
                longest = max(longest, interval.durationSeconds)
            }
        }
        return longest
    }

    // MARK: Week stats scope / daily-average divisor

    /// The day keys actually rendered/counted for a week row: in-month days
    /// always, out-of-month days only when the payload carries them (no
    /// fabricated zeros from the cross-week prev-month tail). `monthPrefix` is
    /// "yyyy-MM-" of the viewed month; `days` is the time payload's day map.
    static func renderedDayKeys(_ dayKeys: [String], monthPrefix: String,
                                days: [String: DayTimeUsage]) -> [String] {
        dayKeys.filter { $0.hasPrefix(monthPrefix) || days[$0] != nil }
    }

    /// Daily-average divisor for a week: the week containing `todayKey` averages
    /// over elapsed days Mon..today (a Tuesday isn't divided by 7); a fully past
    /// week divides by the days that rendered data (min 1); a future week (its
    /// first day already after today) yields 1 (it renders all-zero anyway).
    /// `dayKeys` are the week's 7 chronological keys; `renderedCount` =
    /// renderedDayKeys.count. "yyyy-MM-dd" keys compare chronologically as strings.
    static func avgDivisor(dayKeys: [String], todayKey: String, renderedCount: Int) -> Int {
        if let todayIndex = dayKeys.firstIndex(of: todayKey) {
            return todayIndex + 1
        }
        guard let first = dayKeys.first, first <= todayKey else { return 1 }
        return max(1, renderedCount)
    }

    // MARK: Year grid (53 cols × 7 rows, Monday-first)

    /// Local midnight of the Monday on or before Jan 1 of `year` — column 0 of
    /// the heatmap grid. Cells before Jan 1 / after Dec 31 are out-of-year.
    static func yearGridStartMonday(year: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        guard let jan1 = AppDate.gregorian.date(from: comps) else { return nil }
        return AppDate.mondayOfWeek(containing: jan1)
    }

    /// Parse a "yyyy-MM-dd" day key into local midnight via the pinned
    /// Gregorian calendar. Returns nil for malformed keys.
    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        guard let parsed = AppDate.gregorian.date(from: comps) else { return nil }
        // Reject normalized overflow (e.g. "2026-02-30" rolling into March).
        guard AppDate.dayKey(parsed) == key else { return nil }
        return AppDate.gregorian.startOfDay(for: parsed)
    }

    /// (col, row) of a day in the Monday-first year grid: col = weeks since
    /// `startMonday`, row = 0 (Mon) … 6 (Sun). Returns nil for malformed keys,
    /// days before the grid start, or beyond 53 columns.
    static func gridPosition(dayKey: String, startMonday: Date) -> (col: Int, row: Int)? {
        guard let day = date(fromDayKey: dayKey) else { return nil }
        let start = AppDate.gregorian.startOfDay(for: startMonday)
        guard let dayCount = AppDate.gregorian.dateComponents([.day], from: start, to: day).day,
              dayCount >= 0 else { return nil }
        let col = dayCount / 7
        guard col < 53 else { return nil }
        return (col: col, row: dayCount % 7)
    }

    /// Inverse of gridPosition for iterating the 53×7 grid: the day key of the
    /// cell at (col, row). Returns nil only on calendar arithmetic failure.
    static func dayKey(col: Int, row: Int, startMonday: Date) -> String? {
        let start = AppDate.gregorian.startOfDay(for: startMonday)
        return AppDate.gregorian.date(byAdding: .day, value: col * 7 + row, to: start)
            .map(AppDate.dayKey)
    }
}
