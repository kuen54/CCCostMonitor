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

/// One entry in the newer `limits` array Anthropic returns from the OAuth usage
/// endpoint. It supersedes the flat `seven_day_opus` / `seven_day_sonnet` fields:
/// model-scoped caps (e.g. the weekly Fable cap subscription users recently got)
/// now arrive here as `weekly_scoped` entries whose `scope.model.display_name`
/// names the model. Every field is optional so a schema drift in a single entry
/// can never fail the whole quota decode (which would also blank the working
/// 5h / 7d bars).
struct OAuthUsageLimit: Codable, Equatable {
    let kind: String?          // "session" | "weekly_all" | "weekly_scoped" | …
    let group: String?         // "session" | "weekly"
    let percent: Double?       // used %, integer-valued but decoded as Double for safety
    let resets_at: String?     // ISO-8601 timestamp
    let scope: OAuthLimitScope?
    let is_active: Bool?

    /// Integer percent used, clamped non-negative (mirrors OAuthUsageWindow).
    var displayPercent: Int { max(0, Int((percent ?? 0).rounded())) }
    var resetDate: Date? { OAuthUsage.parseISO(resets_at) }
    var modelDisplayName: String? { scope?.model?.display_name }
}

struct OAuthLimitScope: Codable, Equatable {
    let model: OAuthLimitModel?
    // `surface` is also sent but unused — Codable ignores unknown keys.
}

struct OAuthLimitModel: Codable, Equatable {
    let id: String?
    let display_name: String?
}

/// Lossy container for the `limits` array: decodes element-by-element and DROPS
/// any element that fails to decode instead of throwing. `limits` sits next to a
/// cluster of experimental, frequently-changing server fields, so a schema drift
/// in a single entry must never fail the whole quota response — that would blank
/// the working 5h / 7d bars and surface a decode error for a peripheral feature.
struct OAuthLimitList: Codable, Equatable {
    let items: [OAuthUsageLimit]
    init(items: [OAuthUsageLimit]) { self.items = items }

    init(from decoder: Decoder) throws {
        // Tolerate `limits` being present but NOT an array (a wholesale schema flip
        // to an object / number / string / bool): fall back to empty instead of
        // throwing, which would otherwise blank the working 5h / 7d bars.
        guard var c = try? decoder.unkeyedContainer() else { items = []; return }
        var out: [OAuthUsageLimit] = []
        while !c.isAtEnd {
            // FailableLimit.init always succeeds (it swallows the element's decode
            // error into nil), so the unkeyed container advances exactly one
            // element regardless of the bad element's JSON type — no infinite loop.
            if let v = try c.decode(FailableLimit.self).value { out.append(v) }
        }
        items = out
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(contentsOf: items)
    }

    private struct FailableLimit: Decodable {
        let value: OAuthUsageLimit?
        init(from decoder: Decoder) throws { value = try? OAuthUsageLimit(from: decoder) }
    }
}

struct OAuthUsage: Codable, Equatable {
    let five_hour: OAuthUsageWindow
    let seven_day: OAuthUsageWindow
    let extra_usage: OAuthExtraUsage?
    /// Optional Sonnet-specific 7-day bucket. Anthropic exposes this separately for
    /// Max plans (all-models + Sonnet-only caps). May be absent on Pro or when the
    /// API hasn't rolled it out to this endpoint — decoded defensively.
    let seven_day_sonnet: OAuthUsageWindow?
    /// Newer per-limit array (session / weekly_all / weekly_scoped). Present on
    /// accounts the endpoint has rolled it out to; absent (nil) elsewhere. Decoded
    /// via OAuthLimitList so neither its absence NOR a malformed entry can affect
    /// the flat 5h / 7d fields above.
    let limits: OAuthLimitList?

    var fiveHourResetDate: Date? { Self.parseISO(five_hour.resets_at) }
    var sevenDayResetDate: Date? { Self.parseISO(seven_day.resets_at) }
    var sevenDaySonnetResetDate: Date? { Self.parseISO(seven_day_sonnet?.resets_at) }

    /// Model-scoped weekly caps from `limits` (e.g. the Fable weekly cap). Rendered
    /// as their own remaining bars in the Plan tab. Filtered to entries that name a
    /// model and sorted by model name for a stable, churn-free render order.
    var scopedModelLimits: [OAuthUsageLimit] {
        (limits?.items ?? [])
            // Require a usable model name — drop nil AND empty/whitespace-only so a
            // scoped entry never renders as a nameless "7-day · " bar.
            .filter { !($0.modelDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            .sorted { ($0.modelDisplayName ?? "") < ($1.modelDisplayName ?? "") }
    }

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
    case session = 4
    var icon: String {
        switch self {
        case .cost:         return "dollarsign.circle"
        case .tokens:       return "number.circle"
        case .subscription: return "gauge.with.dots.needle.67percent"
        case .time:         return "clock"
        case .session:      return "bubble.left.and.bubble.right"
        }
    }
    func label(_ loc: Localizer) -> String {
        switch self {
        case .cost:         return loc("cost")
        case .tokens:       return loc("tokens")
        case .subscription: return loc("subTab")
        case .time:         return loc("timeTab")
        case .session:      return loc("sessionTab")
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
