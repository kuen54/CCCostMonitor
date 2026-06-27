import Foundation

// MARK: - App-only Data Models
//
// Pure data models (ModelUsage / PeriodUsage / DailyUsage / MonthlySnapshot)
// moved to Core_Models.swift (testable SPM core).
// AppDate (Gregorian/POSIX date utilities) moved to Core_DateLogic.swift.

// MARK: - Subscription Quota (OAuth)

/// Response from `GET https://api.anthropic.com/api/oauth/usage`.
/// Only available to users who authenticated via `claude login` (Pro/Max/Team/Enterprise).
/// API-key users (Bedrock/Vertex/Console) don't have an OAuth token and this returns nil.
struct OAuthUsageWindow: Codable, Equatable {
    /// Anthropic currently sends Int but we decode as Double to survive any schema
    /// drift to fractional percentages (e.g. 45.3). UI renders via `displayPercent`.
    let utilization: Double
    let resets_at: String?         // ISO-8601 timestamp

    /// Integer percent for display, clamped to non-negative (shouldn't happen but cheap).
    var displayPercent: Int { max(0, Int(utilization.rounded())) }
}

struct OAuthExtraUsage: Codable, Equatable {
    let is_enabled: Bool
    let used_credits: Double?
    let monthly_limit: Double?
}

struct OAuthUsage: Codable, Equatable {
    let five_hour: OAuthUsageWindow
    let seven_day: OAuthUsageWindow
    let extra_usage: OAuthExtraUsage?
    /// Optional Sonnet-specific 7-day bucket. Anthropic exposes this separately for
    /// Max plans (all-models + Sonnet-only caps). May be absent on Pro or when the
    /// API hasn't rolled it out to this endpoint — decoded defensively.
    let seven_day_sonnet: OAuthUsageWindow?

    var fiveHourResetDate: Date? { Self.parseISO(five_hour.resets_at) }
    var sevenDayResetDate: Date? { Self.parseISO(seven_day.resets_at) }
    var sevenDaySonnetResetDate: Date? { Self.parseISO(seven_day_sonnet?.resets_at) }

    static func parseISO(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// Tab selection
// rawValues are APPENDED, never renumbered: the selected tab's rawValue may be
// persisted (UserDefaults) and renumbering would silently remap saved choices.
// Display order is decoupled from rawValue order — PopoverView.visibleTabs
// lists cost, tokens, time, subscription explicitly.
enum DisplayTab: Int, CaseIterable {
    case cost = 0
    case tokens = 1
    case subscription = 2
    case time = 3
    var icon: String {
        switch self {
        case .cost:         return "dollarsign.circle"
        case .tokens:       return "number.circle"
        case .subscription: return "gauge.with.dots.needle.67percent"
        case .time:         return "clock"
        }
    }
    func label(_ loc: Localizer) -> String {
        switch self {
        case .cost:         return loc("cost")
        case .tokens:       return loc("tokens")
        case .subscription: return loc("subTab")
        case .time:         return loc("timeTab")
        }
    }
}

/// Inner sub-view switcher of the Time tab (Week / Month / Year). App-only —
/// not persisted, defaults to .week on each launch.
enum TimeRange: Int, CaseIterable {
    case week = 0
    case month = 1
    case year = 2

    func label(_ loc: Localizer) -> String {
        switch self {
        case .week:  return loc("timeWeek")
        case .month: return loc("timeMonth")
        case .year:  return loc("timeYear")
        }
    }
}

/// Where the app surfaces its idle icon+value: the system menu bar (default) or
/// the MacBook notch (a drop-down panel on hover). String raw value — unlike the
/// Int-raw DisplayTab above, a persisted choice can never silently remap if the
/// cases are reordered. App-only — must NOT enter any Core_*.swift.
enum DisplayMode: String, CaseIterable {
    case menubar
    case notch

    func label(_ loc: Localizer) -> String {
        switch self {
        case .menubar: return loc("displayModeMenubar")
        case .notch:   return loc("displayModeNotch")
        }
    }
}
