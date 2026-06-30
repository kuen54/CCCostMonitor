import Foundation

// MARK: - Date utilities (Gregorian, locale-stable) — pure core
//
// All data-path date math MUST go through these instead of Calendar.current /
// bare DateFormatter(): on a non-Gregorian system calendar (Japanese, Buddhist,
// …) Calendar.current yields era-relative years (e.g. 2569) and locale-less
// formatters can emit non-Gregorian or non-ASCII digits — every "yyyy-MM-dd"
// key would then mismatch the Python script's Gregorian local-date keys and
// Today/Week silently show 0. Human-facing display (viewingMonthLabel, …)
// intentionally keeps locale-aware formatting.
//
// Thread-safety: DateFormatter is NOT thread-safe and these helpers are hit
// from both the main thread and scriptQueue closures, so no DateFormatter is
// shared — `dayKey`/`monthKey` build their strings from Gregorian date
// components via String(format:), which is safe from any thread. Calendar
// itself is a thread-safe value type.
//
// Testability: every time-dependent function takes an explicit Date (a default
// of Date() keeps call sites brief; tests always pass explicit values). No
// hidden Date()/Calendar.current inside function bodies.
enum AppDate {
    /// Gregorian calendar pinned for data-path math. Keeps the user's LOCAL
    /// time zone: day keys must match the Python script's local-date buckets.
    static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }()

    /// "yyyy-MM-dd" key in the local time zone, Gregorian, ASCII digits.
    static func dayKey(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "yyyy-MM" key in the local time zone, Gregorian, ASCII digits.
    static func monthKey(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Monday 00:00 (local) of the week containing `date`.
    static func mondayOfWeek(containing date: Date) -> Date? {
        let weekday = gregorian.component(.weekday, from: date)  // 1=Sun, 2=Mon, …
        let daysFromMonday = (weekday + 5) % 7                   // Mon=0 … Sun=6
        guard let monday = gregorian.date(byAdding: .day, value: -daysFromMonday, to: date) else {
            return nil
        }
        return gregorian.startOfDay(for: monday)
    }

    /// Number of days in a Gregorian month (28–31), or nil on calendar
    /// arithmetic failure (unreachable for a valid year/month + the pinned
    /// Gregorian calendar above). Single source for the month length; callers
    /// pick their own fallback — a date RANGE wants 28 (valid in every month), a
    /// chart axis wants 30 (purely cosmetic on the unreachable failure path).
    static func daysInMonth(year: Int, month: Int) -> Int? {
        let cal = gregorian
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let start = cal.date(from: comps),
              let next = cal.date(byAdding: .month, value: 1, to: start),
              let last = cal.date(byAdding: .day, value: -1, to: next) else { return nil }
        return cal.component(.day, from: last)
    }

    /// Build a "YYYY-MM-01:YYYY-MM-DD" range string for a given year/month.
    static func monthDateRange(year: Int, month: Int) -> String {
        let day = daysInMonth(year: year, month: month) ?? 28  // 28 is a valid day in every month
        return String(format: "%04d-%02d-01:%04d-%02d-%02d", year, month, year, month, day)
    }

    /// Derive today's PeriodUsage from daily breakdown
    static func deriveToday(_ daily: [DailyUsage]?, now: Date = Date()) -> PeriodUsage {
        let todayStr = dayKey(now)
        if let day = daily?.first(where: { $0.dateString == todayStr }) {
            return PeriodUsage(cost: day.cost, models: day.models,
                               totalMessages: day.models.reduce(0) { $0 + $1.messages },
                               totalTokens: day.totalTokens)
        }
        return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
    }

    /// Derive this week's PeriodUsage from daily breakdown (Monday = week start)
    static func deriveWeek(_ daily: [DailyUsage]?, now: Date = Date()) -> PeriodUsage {
        guard let daily = daily else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        // Find Monday of current week (Gregorian, local time zone)
        guard let monday = mondayOfWeek(containing: now) else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        let mondayStr = dayKey(monday)

        // Sum all days from Monday onward
        let weekDays = daily.filter { $0.dateString >= mondayStr }
        return UsageParser.mergeDailyUsages(weekDays)
    }
}
