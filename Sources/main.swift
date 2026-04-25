import Cocoa
import SwiftUI
import Combine

// ╔══════════════════════════════════════════════════════════════╗
// ║  CC Cost Monitor — macOS Menu Bar App                       ║
// ║  Reads Claude Code session data, shows cost in menu bar     ║
// ╚══════════════════════════════════════════════════════════════╝

// MARK: - Data Models

struct ModelUsage: Identifiable, Codable {
    let id: String
    let name: String
    let cost: Double
    let messages: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cacheWrite: Int
    var totalTokens: Int { inputTokens + outputTokens + cacheRead + cacheWrite }

    var color: Color {
        switch id {
        case "opus":   return Color(red: 0.56, green: 0.27, blue: 0.96) // purple
        case "sonnet": return Color(red: 0.24, green: 0.52, blue: 0.98) // blue
        case "haiku":  return Color(red: 0.20, green: 0.78, blue: 0.45) // green
        default:       return .gray
        }
    }

    var icon: String {
        switch id {
        case "opus":   return "circle.fill"
        case "sonnet": return "circle.fill"
        case "haiku":  return "circle.fill"
        default:       return "circle"
        }
    }
}

struct PeriodUsage: Codable {
    let cost: Double
    let models: [ModelUsage]
    let totalMessages: Int
    let totalTokens: Int

    var totalInput: Int { models.reduce(0) { $0 + $1.inputTokens } }
    var totalOutput: Int { models.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheRead: Int { models.reduce(0) { $0 + $1.cacheRead } }
    var totalCacheWrite: Int { models.reduce(0) { $0 + $1.cacheWrite } }
}

struct DailyUsage: Codable, Identifiable {
    var id: String { dateString }
    let dateString: String   // "2026-04-01"
    let day: Int             // 1..31
    let cost: Double
    let totalTokens: Int
    let models: [ModelUsage]
}

struct MonthlySnapshot: Codable {
    let year: Int
    let month: Int
    let data: PeriodUsage
    let lastUpdated: Date
    var dailyBreakdown: [DailyUsage]?
}

// MARK: - Subscription Quota (OAuth)

/// Response from `GET https://api.anthropic.com/api/oauth/usage`.
/// Only available to users who authenticated via `claude login` (Pro/Max/Team/Enterprise).
/// API-key users (Bedrock/Vertex/Console) don't have an OAuth token and this returns nil.
struct OAuthUsageWindow: Codable {
    let utilization: Int           // 0–100
    let resets_at: String?         // ISO-8601 timestamp
}

struct OAuthExtraUsage: Codable {
    let is_enabled: Bool
    let used_credits: Double?
    let monthly_limit: Double?
}

struct OAuthUsage: Codable {
    let five_hour: OAuthUsageWindow
    let seven_day: OAuthUsageWindow
    let extra_usage: OAuthExtraUsage?

    var fiveHourResetDate: Date? { Self.parseISO(five_hour.resets_at) }
    var sevenDayResetDate: Date? { Self.parseISO(seven_day.resets_at) }

    static func parseISO(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Self-contained service: reads credentials, calls Anthropic's OAuth usage endpoint,
/// caches response for 5 minutes. Returns nil whenever the user doesn't have a
/// subscription OAuth token (the expected state for API-key users).
final class SubscriptionQuotaService {
    static let shared = SubscriptionQuotaService()
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let ttl: TimeInterval = 300
    private var cached: (quota: OAuthUsage, at: Date)?
    private let lock = NSLock()

    /// True if a credentials file with an OAuth access token was found on disk.
    /// Distinguishes "API-key user (expected no quota)" from "network/API failure".
    var hasOAuthToken: Bool {
        return readToken() != nil
    }

    private func readToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
            return env
        }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Fetch quota. Returns cached value if fresh. Returns nil if no token (API-key user)
    /// or on network failure (caller can distinguish via `hasOAuthToken`).
    func fetch(forceRefresh: Bool = false, completion: @escaping (OAuthUsage?) -> Void) {
        lock.lock()
        if !forceRefresh, let c = cached, Date().timeIntervalSince(c.at) < ttl {
            let q = c.quota
            lock.unlock()
            completion(q)
            return
        }
        lock.unlock()

        guard let token = readToken() else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CCCostMonitor/1.2.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self,
                  let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let quota = try? JSONDecoder().decode(OAuthUsage.self, from: data)
            else {
                completion(nil)
                return
            }
            self.lock.lock()
            self.cached = (quota, Date())
            self.lock.unlock()
            completion(quota)
        }.resume()
    }
}

// Tab selection
enum DisplayTab: Int, CaseIterable {
    case cost = 0
    case tokens = 1
    var icon: String { self == .cost ? "dollarsign.circle" : "number.circle" }
    func label(_ loc: (String) -> String) -> String {
        self == .cost ? loc("cost") : loc("tokens")
    }
}

// MARK: - Localization

enum AppLanguage: String, CaseIterable, Codable {
    case en = "en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja = "ja"

    var displayName: String {
        switch self {
        case .en:     return "EN"
        case .zhHans: return "简"
        case .zhHant: return "繁"
        case .ja:     return "JP"
        }
    }

    static func fromSystem() -> AppLanguage {
        let lang = Locale.preferredLanguages.first ?? "en"
        if lang.hasPrefix("zh-Hans") || lang.hasPrefix("zh-CN") { return .zhHans }
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") { return .zhHant }
        if lang.hasPrefix("zh") { return .zhHans }  // bare "zh" → Simplified
        if lang.hasPrefix("ja") { return .ja }
        return .en
    }
}

private let i18n: [AppLanguage: [String: String]] = [
    .en: [
        "tkIn":         "in",
        "tkOut":        "out",
        "tkCR":         "c_r",
        "tkCW":         "c_w",
        "title":        "Local CC Usage",
        "cost":         "Cost",
        "tokens":       "Tokens",
        "today":        "Today",
        "thisWeek":     "This Week",
        "thisMonth":    "This Month",
        "monthlyTotal": "Monthly Total",
        "daily":        "Daily",
        "noData":       "No data",
        "loading":      "Loading usage data…",
        "loadFailed":   "Failed to load data",
        "noMonthData":  "No data for this month",
        "updated":      "Updated %@",
        "cachedData":   "Cached data",
        "refresh":      "Refresh (⌘R)",
        "quit":         "Quit",
        "justNow":      "just now",
        "mAgo":         "%dm ago",
        "hAgo":         "%dh ago",
        "dAgo":         "%dd ago",
        "mTokens":      "%.1fm tokens",
        "kTokens":      "%.1fk tokens",
        "nTokens":      "%d tokens",
        "win5hHeader":       "5-hour window",
        "win5hResetsIn":     "Resets in %@",
        "win5hLocal":        "Local this window",
        "win5hQuotaSection": "Subscription quota",
        "win5hMsgs":         "msgs",
        "quota5h":           "5h",
        "quota7d":           "7d",
        "quotaWarnHigh":     "⏰ Close to limit",
        "quotaExtra":        "💸 Extra usage on",
        "quotaFetchFail":    "Quota API failed",
        "bedrockNote":       "API-key auth — no subscription 5h/weekly quota applies.",
    ],
    .zhHans: [
        "tkIn":         "输入",
        "tkOut":        "输出",
        "tkCR":         "缓读",
        "tkCW":         "缓写",
        "title":        "CC 用量监控",
        "cost":         "费用",
        "tokens":       "Tokens",
        "today":        "今日",
        "thisWeek":     "本周",
        "thisMonth":    "本月",
        "monthlyTotal": "月度汇总",
        "daily":        "每日",
        "noData":       "无数据",
        "loading":      "加载用量数据…",
        "loadFailed":   "数据加载失败",
        "noMonthData":  "当月无数据",
        "updated":      "%@ 更新",
        "cachedData":   "缓存数据",
        "refresh":      "刷新 (⌘R)",
        "quit":         "退出",
        "justNow":      "刚刚",
        "mAgo":         "%d分钟前",
        "hAgo":         "%d小时前",
        "dAgo":         "%d天前",
        "mTokens":      "%.1fm tokens",
        "kTokens":      "%.1fk tokens",
        "nTokens":      "%d tokens",
        "win5hHeader":       "5 小时窗口",
        "win5hResetsIn":     "%@ 后重置",
        "win5hLocal":        "本窗口本机消耗",
        "win5hQuotaSection": "订阅配额",
        "win5hMsgs":         "条",
        "quota5h":           "5小时",
        "quota7d":           "7天",
        "quotaWarnHigh":     "⏰ 接近上限",
        "quotaExtra":        "💸 已开启额外用量",
        "quotaFetchFail":    "订阅配额 API 失败",
        "bedrockNote":       "API key 鉴权 — 不受订阅的 5h/周限额约束",
    ],
    .zhHant: [
        "tkIn":         "輸入",
        "tkOut":        "輸出",
        "tkCR":         "緩讀",
        "tkCW":         "緩寫",
        "title":        "CC 用量監控",
        "cost":         "費用",
        "tokens":       "Tokens",
        "today":        "今日",
        "thisWeek":     "本週",
        "thisMonth":    "本月",
        "monthlyTotal": "月度匯總",
        "daily":        "每日",
        "noData":       "無數據",
        "loading":      "載入用量數據…",
        "loadFailed":   "數據載入失敗",
        "noMonthData":  "當月無數據",
        "updated":      "%@ 更新",
        "cachedData":   "快取數據",
        "refresh":      "重新整理 (⌘R)",
        "quit":         "結束",
        "justNow":      "剛剛",
        "mAgo":         "%d分鐘前",
        "hAgo":         "%d小時前",
        "dAgo":         "%d天前",
        "mTokens":      "%.1fm tokens",
        "kTokens":      "%.1fk tokens",
        "nTokens":      "%d tokens",
        "win5hHeader":       "5 小時視窗",
        "win5hResetsIn":     "%@ 後重置",
        "win5hLocal":        "本視窗本機消耗",
        "win5hQuotaSection": "訂閱配額",
        "win5hMsgs":         "條",
        "quota5h":           "5小時",
        "quota7d":           "7天",
        "quotaWarnHigh":     "⏰ 接近上限",
        "quotaExtra":        "💸 已啟用額外用量",
        "quotaFetchFail":    "訂閱配額 API 失敗",
        "bedrockNote":       "API key 驗證 — 不受訂閱的 5h/週限額約束",
    ],
    .ja: [
        "tkIn":         "入力",
        "tkOut":        "出力",
        "tkCR":         "c読",
        "tkCW":         "c書",
        "title":        "CC 使用量",
        "cost":         "コスト",
        "tokens":       "トークン",
        "today":        "今日",
        "thisWeek":     "今週",
        "thisMonth":    "今月",
        "monthlyTotal": "月間合計",
        "daily":        "日別",
        "noData":       "データなし",
        "loading":      "使用量を読み込み中…",
        "loadFailed":   "データの読み込みに失敗",
        "noMonthData":  "今月のデータなし",
        "updated":      "%@ に更新",
        "cachedData":   "キャッシュデータ",
        "refresh":      "更新 (⌘R)",
        "quit":         "終了",
        "justNow":      "たった今",
        "mAgo":         "%d分前",
        "hAgo":         "%d時間前",
        "dAgo":         "%d日前",
        "mTokens":      "%.1fm トークン",
        "kTokens":      "%.1fk トークン",
        "nTokens":      "%d トークン",
        "win5hHeader":       "5 時間ウィンドウ",
        "win5hResetsIn":     "%@後にリセット",
        "win5hLocal":        "このウィンドウの消費",
        "win5hQuotaSection": "サブスク配分",
        "win5hMsgs":         "件",
        "quota5h":           "5h",
        "quota7d":           "7d",
        "quotaWarnHigh":     "⏰ 上限間近",
        "quotaExtra":        "💸 追加利用が有効",
        "quotaFetchFail":    "配分 API 失敗",
        "bedrockNote":       "API キー認証 — サブスクの 5h/週の制限は適用されません",
    ],
]

// MARK: - Data Store

class UsageStore: ObservableObject {
    @Published var today: PeriodUsage?
    @Published var week: PeriodUsage?
    @Published var month: PeriodUsage?
    @Published var isLoading = true
    @Published var lastUpdate: Date?
    @Published var selectedTab: DisplayTab = .cost

    // Month navigation
    @Published var viewingYear: Int
    @Published var viewingMonth: Int

    // Always holds current month data (for menu bar, unaffected by navigation)
    @Published var currentMonthData: PeriodUsage?
    @Published var dailyBreakdown: [DailyUsage]?

    // Localization
    @Published var language: AppLanguage

    // Subscription quota (from Anthropic OAuth endpoint, only populated for Pro/Max users)
    @Published var subscriptionQuota: OAuthUsage?
    @Published var hasOAuthToken: Bool = false

    var isCurrentMonth: Bool {
        let cal = Calendar.current
        let now = Date()
        return viewingYear == cal.component(.year, from: now)
            && viewingMonth == cal.component(.month, from: now)
    }

    var viewingMonthLabel: String {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        df.locale = Locale(identifier: language.rawValue)
        var comps = DateComponents()
        comps.year = viewingYear
        comps.month = viewingMonth
        comps.day = 1
        guard let date = Calendar.current.date(from: comps) else { return "" }
        return df.string(from: date)
    }

    private let scriptPath: String
    private let pythonPath: String

    // Cache directory: ~/.claude/cache/cc-monitor/
    private var cacheDir: String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cache/cc-monitor")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    init() {
        let cal = Calendar.current
        let now = Date()
        viewingYear = cal.component(.year, from: now)
        viewingMonth = cal.component(.month, from: now)

        // Language: restore from UserDefaults or detect system language
        if let saved = UserDefaults.standard.string(forKey: "appLanguage"),
           let lang = AppLanguage(rawValue: saved) {
            language = lang
        } else {
            language = AppLanguage.fromSystem()
        }

        if let bundled = Bundle.main.path(forResource: "analyze_usage", ofType: "py") {
            scriptPath = bundled
        } else {
            scriptPath = (NSHomeDirectory() as NSString).appendingPathComponent(
                ".claude/skills/local-cc-cost/scripts/analyze_usage.py"
            )
        }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        pythonPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3"

        // Probe OAuth state once at startup so UI can choose Bedrock vs subscription branch.
        hasOAuthToken = SubscriptionQuotaService.shared.hasOAuthToken
    }

    /// Fetch subscription quota from Anthropic's OAuth endpoint and update @Published state.
    /// Safe to call repeatedly — the service caches for 5 minutes internally.
    func refreshQuota(force: Bool = false) {
        SubscriptionQuotaService.shared.fetch(forceRefresh: force) { [weak self] quota in
            DispatchQueue.main.async {
                self?.subscriptionQuota = quota
                // Update the token flag in case credentials changed (e.g. user ran `claude login`)
                self?.hasOAuthToken = SubscriptionQuotaService.shared.hasOAuthToken
            }
        }
    }

    func loc(_ key: String) -> String {
        i18n[language]?[key] ?? i18n[.en]?[key] ?? key
    }

    func setLanguage(_ lang: AppLanguage) {
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage")
    }

    // MARK: - Navigation

    func navigateMonth(offset: Int) {
        var comps = DateComponents()
        comps.year = viewingYear
        comps.month = viewingMonth + offset
        comps.day = 1
        guard let date = Calendar.current.date(from: comps) else { return }
        let cal = Calendar.current
        viewingYear = cal.component(.year, from: date)
        viewingMonth = cal.component(.month, from: date)

        if isCurrentMonth {
            refresh()
        } else {
            loadHistoricalMonth()
        }
    }

    func loadHistoricalMonth() {
        let y = viewingYear, m = viewingMonth
        // Try cache first (must have daily data, otherwise re-fetch)
        if let snapshot = loadCacheSnapshot(year: y, month: m),
           snapshot.dailyBreakdown != nil {
            self.today = nil
            self.week = nil
            self.month = snapshot.data
            self.dailyBreakdown = snapshot.dailyBreakdown
            self.isLoading = false
            return
        }
        // Fetch from script
        isLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let range = self.monthDateRange(year: y, month: m)
            let ym = String(format: "%04d-%02d", y, m)
            let (data, daily) = self.fetchMonthData(range, yearMonth: ym)
            DispatchQueue.main.async {
                // Guard: user might have navigated away while loading
                guard self.viewingYear == y && self.viewingMonth == m else { return }
                self.today = nil
                self.week = nil
                self.month = data
                self.dailyBreakdown = daily
                self.isLoading = false
                if let data = data {
                    self.saveCache(year: y, month: m, data: data, daily: daily)
                }
            }
        }
    }

    // MARK: - Refresh (current month)

    func refresh() {
        // Refresh subscription quota in parallel (no-op for API-key users)
        refreshQuota()

        // If not viewing current month, just reload historical
        guard isCurrentMonth else {
            loadHistoricalMonth()
            return
        }
        // If returning from a historical month (today/week nil but stale month data present),
        // immediately restore cached current month data so UI doesn't flash error
        if self.today == nil {
            loadCacheForCurrentMonth()
        }
        // Only show loading spinner if no cached data is displayed yet
        if self.month == nil {
            DispatchQueue.main.async { self.isLoading = true }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            // Single script call for the whole month
            let cal = Calendar.current
            let now = Date()
            let ym = String(format: "%04d-%02d", cal.component(.year, from: now), cal.component(.month, from: now))
            let (m, daily) = self.fetchMonthData("month", yearMonth: ym)
            // If script failed, keep existing cached data visible
            guard m != nil else {
                DispatchQueue.main.async { self.isLoading = false }
                return
            }
            // Derive today & week from daily breakdown
            let t = self.deriveToday(daily)
            let w = self.deriveWeek(daily)
            DispatchQueue.main.async {
                self.today = t
                self.week = w
                self.month = m
                self.dailyBreakdown = daily
                self.currentMonthData = m
                self.lastUpdate = Date()
                self.isLoading = false
                // Persist current month snapshot
                if let m = m {
                    self.saveCache(
                        year: cal.component(.year, from: now),
                        month: cal.component(.month, from: now),
                        data: m, daily: daily)
                }
            }
        }
    }

    // MARK: - Cache I/O

    private func cachePath(year: Int, month: Int) -> String {
        return (cacheDir as NSString).appendingPathComponent(
            String(format: "%04d-%02d.json", year, month))
    }

    private func saveCache(year: Int, month: Int, data: PeriodUsage, daily: [DailyUsage]? = nil) {
        var snapshot = MonthlySnapshot(year: year, month: month, data: data, lastUpdated: Date())
        snapshot.dailyBreakdown = daily
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let jsonData = try? encoder.encode(snapshot) else { return }
        try? jsonData.write(to: URL(fileURLWithPath: cachePath(year: year, month: month)))
    }

    private func loadCache(year: Int, month: Int) -> PeriodUsage? {
        return loadCacheSnapshot(year: year, month: month)?.data
    }

    private func loadCacheSnapshot(year: Int, month: Int) -> MonthlySnapshot? {
        let path = cachePath(year: year, month: month)
        guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MonthlySnapshot.self, from: rawData)
    }

    /// Load cached data for the current month and display immediately (before background refresh)
    func loadCacheForCurrentMonth() {
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        guard let snapshot = loadCacheSnapshot(year: y, month: m) else { return }
        let daily = snapshot.dailyBreakdown
        // Derive today/week from daily breakdown, or set empty fallback (old cache format)
        if daily != nil {
            self.today = deriveToday(daily)
            self.week = deriveWeek(daily)
        } else {
            let empty = PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
            self.today = empty
            self.week = empty
        }
        self.month = snapshot.data
        self.dailyBreakdown = daily
        self.currentMonthData = snapshot.data
        self.lastUpdate = snapshot.lastUpdated
        self.isLoading = false
    }

    // MARK: - Script execution

    /// Build a "YYYY-MM-01:YYYY-MM-DD" range string for a given year/month
    private func monthDateRange(year: Int, month: Int) -> String {
        let cal = Calendar.current
        var startComps = DateComponents()
        startComps.year = year
        startComps.month = month
        startComps.day = 1
        guard let startDate = cal.date(from: startComps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: startDate),
              let lastDay = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
            return String(format: "%04d-%02d-01:%04d-%02d-28", year, month, year, month)
        }
        let day = cal.component(.day, from: lastDay)
        return String(format: "%04d-%02d-01:%04d-%02d-%02d", year, month, year, month, day)
    }

    private func fetchPeriod(_ range: String) -> PeriodUsage? {
        guard let json = runScript(["--json", "--range", range]) else { return nil }
        return parsePeriod(json)
    }

    /// Fetch month data with daily breakdown from a single script call
    /// yearMonth: "YYYY-MM" string for filtering daily data (e.g. "2026-04")
    private func fetchMonthData(_ range: String, yearMonth: String) -> (PeriodUsage?, [DailyUsage]?) {
        guard let json = runScript(["--json", "--range", range]) else { return (nil, nil) }
        let period = parsePeriod(json)
        let daily = parseDailyBreakdown(json, yearMonth: yearMonth)
        return (period, daily)
    }

    /// Parse PeriodUsage from JSON (extracted from fetchPeriod for reuse)
    private func parsePeriod(_ json: [String: Any]) -> PeriodUsage? {
        let grandTotal = json["grand_total_cost"] as? Double ?? 0
        var models: [ModelUsage] = []
        var totalMessages = 0, totalTokens = 0
        let order = ["opus", "sonnet", "haiku"]
        let names = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]

        if let totals = json["totals_by_model"] as? [String: Any] {
            for key in order {
                guard let data = totals[key] as? [String: Any] else { continue }
                let inp  = data["input_tokens"] as? Int ?? 0
                let out  = data["output_tokens"] as? Int ?? 0
                let cr   = data["cache_read"] as? Int ?? 0
                let cw   = data["cache_write"] as? Int ?? 0
                let msgs = data["messages"] as? Int ?? 0
                let cost = data["cost"] as? Double ?? 0
                models.append(ModelUsage(
                    id: key, name: names[key] ?? key,
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
    private func parseDailyBreakdown(_ json: [String: Any], yearMonth: String) -> [DailyUsage]? {
        guard let breakdown = json["daily_breakdown"] as? [String: Any], !breakdown.isEmpty else {
            return nil
        }
        let order = ["opus", "sonnet", "haiku"]
        let names = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]

        var result: [DailyUsage] = []
        for dateStr in breakdown.keys.sorted() {
            guard dateStr.hasPrefix(yearMonth),
                  let dayData = breakdown[dateStr] as? [String: Any] else { continue }
            let dayCost = dayData["total_cost"] as? Double ?? 0
            var models: [ModelUsage] = []
            var totalTokens = 0
            if let modelsDict = dayData["models"] as? [String: Any] {
                for key in order {
                    guard let data = modelsDict[key] as? [String: Any] else { continue }
                    let inp  = data["input_tokens"] as? Int ?? 0
                    let out  = data["output_tokens"] as? Int ?? 0
                    let cr   = data["cache_read"] as? Int ?? 0
                    let cw   = data["cache_write"] as? Int ?? 0
                    let msgs = data["messages"] as? Int ?? 0
                    let cost = data["cost"] as? Double ?? 0
                    models.append(ModelUsage(
                        id: key, name: names[key] ?? key,
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

    /// Derive today's PeriodUsage from daily breakdown
    private func deriveToday(_ daily: [DailyUsage]?) -> PeriodUsage {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: Date())
        if let day = daily?.first(where: { $0.dateString == todayStr }) {
            return PeriodUsage(cost: day.cost, models: day.models,
                               totalMessages: day.models.reduce(0) { $0 + $1.messages },
                               totalTokens: day.totalTokens)
        }
        return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
    }

    /// Derive this week's PeriodUsage from daily breakdown (Monday = week start)
    private func deriveWeek(_ daily: [DailyUsage]?) -> PeriodUsage {
        guard let daily = daily else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        let cal = Calendar.current
        let now = Date()
        // Find Monday of current week
        let weekday = cal.component(.weekday, from: now)  // 1=Sun, 2=Mon, ...
        let daysFromMon = (weekday + 5) % 7  // Mon=0, Tue=1, ..., Sun=6
        guard let monday = cal.date(byAdding: .day, value: -daysFromMon, to: now) else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let mondayStr = df.string(from: monday)

        // Sum all days from Monday onward
        let weekDays = daily.filter { $0.dateString >= mondayStr }
        return mergeDailyUsages(weekDays)
    }

    /// Merge multiple DailyUsage entries into a single PeriodUsage
    private func mergeDailyUsages(_ days: [DailyUsage]) -> PeriodUsage {
        guard !days.isEmpty else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        let order = ["opus", "sonnet", "haiku"]
        let names = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
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
        for key in order {
            guard let a = accum[key] else { continue }
            models.append(ModelUsage(id: key, name: names[key] ?? key,
                                     cost: a.cost, messages: a.msgs,
                                     inputTokens: a.inp, outputTokens: a.out,
                                     cacheRead: a.cr, cacheWrite: a.cw))
            totalTokens += a.inp + a.out + a.cr + a.cw
        }
        return PeriodUsage(cost: totalCost, models: models,
                           totalMessages: models.reduce(0) { $0 + $1.messages },
                           totalTokens: totalTokens)
    }

    private func runScript(_ args: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + args
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read pipe BEFORE waitUntilExit to avoid deadlock when output > 64KB
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}

// MARK: - SwiftUI Views

// ── Claude logo as SwiftUI Shape ──
struct ClaudeLogoShape: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        let s = min(rect.width, rect.height) / 24.0
        var p = SwiftUI.Path()
        // Official Claude logo SVG path (SimpleIcons, CC0)
        p.move(to: CGPoint(x: 4.7144*s, y: 15.9555*s))
        p.addLine(to: CGPoint(x: 9.4318*s, y: 13.3084*s))
        p.addLine(to: CGPoint(x: 9.5108*s, y: 13.0777*s))
        p.addLine(to: CGPoint(x: 9.4318*s, y: 12.9502*s))
        p.addLine(to: CGPoint(x: 9.2011*s, y: 12.9502*s))
        p.addLine(to: CGPoint(x: 8.4118*s, y: 12.9016*s))
        p.addLine(to: CGPoint(x: 5.7162*s, y: 12.8287*s))
        p.addLine(to: CGPoint(x: 3.3787*s, y: 12.7316*s))
        p.addLine(to: CGPoint(x: 1.1141*s, y: 12.6102*s))
        p.addLine(to: CGPoint(x: 0.5434*s, y: 12.4887*s))
        p.addLine(to: CGPoint(x: 0.0091*s, y: 11.7845*s))
        p.addLine(to: CGPoint(x: 0.0637*s, y: 11.4323*s))
        p.addLine(to: CGPoint(x: 0.5434*s, y: 11.1105*s))
        p.addLine(to: CGPoint(x: 1.2294*s, y: 11.1713*s))
        p.addLine(to: CGPoint(x: 2.7473*s, y: 11.2745*s))
        p.addLine(to: CGPoint(x: 5.0240*s, y: 11.4323*s))
        p.addLine(to: CGPoint(x: 6.6754*s, y: 11.5295*s))
        p.addLine(to: CGPoint(x: 9.1222*s, y: 11.7845*s))
        p.addLine(to: CGPoint(x: 9.5108*s, y: 11.7845*s))
        p.addLine(to: CGPoint(x: 9.5654*s, y: 11.6266*s))
        p.addLine(to: CGPoint(x: 9.4318*s, y: 11.5295*s))
        p.addLine(to: CGPoint(x: 9.3286*s, y: 11.4323*s))
        p.addLine(to: CGPoint(x: 6.9730*s, y: 9.8356*s))
        p.addLine(to: CGPoint(x: 4.4230*s, y: 8.1477*s))
        p.addLine(to: CGPoint(x: 3.0874*s, y: 7.1763*s))
        p.addLine(to: CGPoint(x: 2.3649*s, y: 6.6845*s))
        p.addLine(to: CGPoint(x: 2.0006*s, y: 6.2231*s))
        p.addLine(to: CGPoint(x: 1.8428*s, y: 5.2153*s))
        p.addLine(to: CGPoint(x: 2.4985*s, y: 4.4928*s))
        p.addLine(to: CGPoint(x: 3.3788*s, y: 4.5535*s))
        p.addLine(to: CGPoint(x: 3.6034*s, y: 4.6142*s))
        p.addLine(to: CGPoint(x: 4.4959*s, y: 5.3002*s))
        p.addLine(to: CGPoint(x: 6.4023*s, y: 6.7756*s))
        p.addLine(to: CGPoint(x: 8.8916*s, y: 8.6092*s))
        p.addLine(to: CGPoint(x: 9.2559*s, y: 8.9127*s))
        p.addLine(to: CGPoint(x: 9.4016*s, y: 8.8095*s))
        p.addLine(to: CGPoint(x: 9.4198*s, y: 8.7367*s))
        p.addLine(to: CGPoint(x: 9.2558*s, y: 8.4634*s))
        p.addLine(to: CGPoint(x: 7.9019*s, y: 6.0167*s))
        p.addLine(to: CGPoint(x: 6.4569*s, y: 3.5274*s))
        p.addLine(to: CGPoint(x: 5.8134*s, y: 2.4954*s))
        p.addLine(to: CGPoint(x: 5.6434*s, y: 1.8760*s))
        p.addCurve(to: CGPoint(x: 5.5402*s, y: 1.1475*s),
                   control1: CGPoint(x: 5.5827*s, y: 1.6210*s),
                   control2: CGPoint(x: 5.5402*s, y: 1.4086*s))
        p.addLine(to: CGPoint(x: 6.2870*s, y: 0.1335*s))
        p.addLine(to: CGPoint(x: 6.6997*s, y: 0.0*s))
        p.addLine(to: CGPoint(x: 7.6954*s, y: 0.1336*s))
        p.addLine(to: CGPoint(x: 8.1144*s, y: 0.4978*s))
        p.addLine(to: CGPoint(x: 8.7336*s, y: 1.9125*s))
        p.addLine(to: CGPoint(x: 9.7354*s, y: 4.1407*s))
        p.addLine(to: CGPoint(x: 11.2897*s, y: 7.1703*s))
        p.addLine(to: CGPoint(x: 11.7450*s, y: 8.0688*s))
        p.addLine(to: CGPoint(x: 11.9879*s, y: 8.9006*s))
        p.addLine(to: CGPoint(x: 12.0789*s, y: 9.1556*s))
        p.addLine(to: CGPoint(x: 12.2368*s, y: 9.1556*s))
        p.addLine(to: CGPoint(x: 12.2368*s, y: 9.0099*s))
        p.addLine(to: CGPoint(x: 12.3643*s, y: 7.3039*s))
        p.addLine(to: CGPoint(x: 12.6011*s, y: 5.2092*s))
        p.addLine(to: CGPoint(x: 12.8318*s, y: 2.5135*s))
        p.addLine(to: CGPoint(x: 12.9107*s, y: 1.7546*s))
        p.addLine(to: CGPoint(x: 13.2871*s, y: 0.8439*s))
        p.addLine(to: CGPoint(x: 14.0339*s, y: 0.3521*s))
        p.addLine(to: CGPoint(x: 14.6167*s, y: 0.6314*s))
        p.addLine(to: CGPoint(x: 15.0964*s, y: 1.3174*s))
        p.addLine(to: CGPoint(x: 15.0296*s, y: 1.7607*s))
        p.addLine(to: CGPoint(x: 14.7443*s, y: 3.6124*s))
        p.addLine(to: CGPoint(x: 14.1857*s, y: 6.5145*s))
        p.addLine(to: CGPoint(x: 13.8214*s, y: 8.4574*s))
        p.addLine(to: CGPoint(x: 14.0339*s, y: 8.4574*s))
        p.addLine(to: CGPoint(x: 14.2768*s, y: 8.2145*s))
        p.addLine(to: CGPoint(x: 15.2603*s, y: 6.9092*s))
        p.addLine(to: CGPoint(x: 16.9117*s, y: 4.8449*s))
        p.addLine(to: CGPoint(x: 17.6403*s, y: 4.0253*s))
        p.addLine(to: CGPoint(x: 18.4903*s, y: 3.1207*s))
        p.addLine(to: CGPoint(x: 19.0367*s, y: 2.6896*s))
        p.addLine(to: CGPoint(x: 20.0688*s, y: 2.6896*s))
        p.addLine(to: CGPoint(x: 20.8278*s, y: 3.8189*s))
        p.addLine(to: CGPoint(x: 20.4878*s, y: 4.9846*s))
        p.addLine(to: CGPoint(x: 19.4253*s, y: 6.3324*s))
        p.addLine(to: CGPoint(x: 18.5449*s, y: 7.4738*s))
        p.addLine(to: CGPoint(x: 17.2821*s, y: 9.1738*s))
        p.addLine(to: CGPoint(x: 16.4928*s, y: 10.5338*s))
        p.addLine(to: CGPoint(x: 16.5657*s, y: 10.6431*s))
        p.addLine(to: CGPoint(x: 16.7539*s, y: 10.6248*s))
        p.addLine(to: CGPoint(x: 19.6074*s, y: 10.0178*s))
        p.addLine(to: CGPoint(x: 21.1495*s, y: 9.7384*s))
        p.addLine(to: CGPoint(x: 22.9891*s, y: 9.4227*s))
        p.addLine(to: CGPoint(x: 23.8209*s, y: 9.8113*s))
        p.addLine(to: CGPoint(x: 23.9119*s, y: 10.2059*s))
        p.addLine(to: CGPoint(x: 23.5841*s, y: 11.0134*s))
        p.addLine(to: CGPoint(x: 21.6171*s, y: 11.4991*s))
        p.addLine(to: CGPoint(x: 19.3099*s, y: 11.9605*s))
        p.addLine(to: CGPoint(x: 15.8735*s, y: 12.7741*s))
        p.addLine(to: CGPoint(x: 15.8310*s, y: 12.8045*s))
        p.addLine(to: CGPoint(x: 15.8796*s, y: 12.8652*s))
        p.addLine(to: CGPoint(x: 17.4278*s, y: 13.0109*s))
        p.addLine(to: CGPoint(x: 18.0896*s, y: 13.0473*s))
        p.addLine(to: CGPoint(x: 19.7106*s, y: 13.0473*s))
        p.addLine(to: CGPoint(x: 22.7281*s, y: 13.2720*s))
        p.addLine(to: CGPoint(x: 23.5173*s, y: 13.7940*s))
        p.addLine(to: CGPoint(x: 23.9909*s, y: 14.4316*s))
        p.addLine(to: CGPoint(x: 23.9119*s, y: 14.9173*s))
        p.addLine(to: CGPoint(x: 22.6977*s, y: 15.5366*s))
        p.addLine(to: CGPoint(x: 21.0584*s, y: 15.1480*s))
        p.addLine(to: CGPoint(x: 17.2334*s, y: 14.2373*s))
        p.addLine(to: CGPoint(x: 15.9221*s, y: 13.9094*s))
        p.addLine(to: CGPoint(x: 15.7399*s, y: 13.9094*s))
        p.addLine(to: CGPoint(x: 15.7399*s, y: 14.0187*s))
        p.addLine(to: CGPoint(x: 16.8328*s, y: 15.0873*s))
        p.addLine(to: CGPoint(x: 18.8363*s, y: 16.8965*s))
        p.addLine(to: CGPoint(x: 21.3438*s, y: 19.2279*s))
        p.addLine(to: CGPoint(x: 21.4713*s, y: 19.8047*s))
        p.addLine(to: CGPoint(x: 21.1495*s, y: 20.2601*s))
        p.addLine(to: CGPoint(x: 20.8095*s, y: 20.2115*s))
        p.addLine(to: CGPoint(x: 18.6056*s, y: 18.5540*s))
        p.addLine(to: CGPoint(x: 17.7556*s, y: 17.8072*s))
        p.addLine(to: CGPoint(x: 15.8310*s, y: 16.1862*s))
        p.addLine(to: CGPoint(x: 15.7035*s, y: 16.1862*s))
        p.addLine(to: CGPoint(x: 15.7035*s, y: 16.3562*s))
        p.addLine(to: CGPoint(x: 16.1467*s, y: 17.0058*s))
        p.addLine(to: CGPoint(x: 18.4903*s, y: 20.5272*s))
        p.addLine(to: CGPoint(x: 18.6117*s, y: 21.6079*s))
        p.addLine(to: CGPoint(x: 18.4417*s, y: 21.9600*s))
        p.addLine(to: CGPoint(x: 17.8346*s, y: 22.1725*s))
        p.addLine(to: CGPoint(x: 17.1667*s, y: 22.0511*s))
        p.addLine(to: CGPoint(x: 15.7946*s, y: 20.1265*s))
        p.addLine(to: CGPoint(x: 14.3800*s, y: 17.9590*s))
        p.addLine(to: CGPoint(x: 13.2386*s, y: 16.0162*s))
        p.addLine(to: CGPoint(x: 13.0989*s, y: 16.0952*s))
        p.addLine(to: CGPoint(x: 12.4249*s, y: 23.3504*s))
        p.addLine(to: CGPoint(x: 12.1093*s, y: 23.7207*s))
        p.addLine(to: CGPoint(x: 11.3807*s, y: 24.0000*s))
        p.addLine(to: CGPoint(x: 10.7736*s, y: 23.5386*s))
        p.addLine(to: CGPoint(x: 10.4518*s, y: 22.7918*s))
        p.addLine(to: CGPoint(x: 10.7736*s, y: 21.3165*s))
        p.addLine(to: CGPoint(x: 11.1622*s, y: 19.3919*s))
        p.addLine(to: CGPoint(x: 11.4779*s, y: 17.8619*s))
        p.addLine(to: CGPoint(x: 11.7632*s, y: 15.9615*s))
        p.addLine(to: CGPoint(x: 11.9332*s, y: 15.3301*s))
        p.addLine(to: CGPoint(x: 11.9211*s, y: 15.2876*s))
        p.addLine(to: CGPoint(x: 11.7814*s, y: 15.3058*s))
        p.addLine(to: CGPoint(x: 10.3486*s, y: 17.2730*s))
        p.addLine(to: CGPoint(x: 8.1690*s, y: 20.2176*s))
        p.addLine(to: CGPoint(x: 6.4447*s, y: 22.0632*s))
        p.addLine(to: CGPoint(x: 6.0319*s, y: 22.2272*s))
        p.addLine(to: CGPoint(x: 5.3155*s, y: 21.8568*s))
        p.addLine(to: CGPoint(x: 5.3822*s, y: 21.1950*s))
        p.addLine(to: CGPoint(x: 5.7830*s, y: 20.6061*s))
        p.addLine(to: CGPoint(x: 8.1690*s, y: 17.5704*s))
        p.addLine(to: CGPoint(x: 9.6079*s, y: 15.6884*s))
        p.addLine(to: CGPoint(x: 10.5369*s, y: 14.6016*s))
        p.addLine(to: CGPoint(x: 10.5307*s, y: 14.4437*s))
        p.addLine(to: CGPoint(x: 10.4761*s, y: 14.4437*s))
        p.addLine(to: CGPoint(x: 4.1376*s, y: 18.5601*s))
        p.addLine(to: CGPoint(x: 3.0083*s, y: 18.7058*s))
        p.addLine(to: CGPoint(x: 2.5226*s, y: 18.2504*s))
        p.addLine(to: CGPoint(x: 2.5834*s, y: 17.5037*s))
        p.addLine(to: CGPoint(x: 2.8141*s, y: 17.2608*s))
        p.addLine(to: CGPoint(x: 4.7205*s, y: 15.9494*s))
        p.closeSubpath()
        return p
    }
}

// ── Proportion bar (generic — works for cost or tokens) ──
struct ProportionBar: View {
    let segments: [(color: Color, fraction: CGFloat)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.fraction > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seg.color)
                            .frame(width: max(3, seg.fraction * geo.size.width))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

// ── Cost proportion bar (convenience wrapper) ──
struct CostBar: View {
    let models: [ModelUsage]
    let total: Double

    var body: some View {
        ProportionBar(segments: models.map { m in
            (color: m.color, fraction: total > 0 ? CGFloat(m.cost / total) : 0)
        })
    }
}

// ── Token proportion bar (by model) ──
struct TokenBar: View {
    let models: [ModelUsage]
    let total: Int

    var body: some View {
        ProportionBar(segments: models.map { m in
            (color: m.color, fraction: total > 0 ? CGFloat(Double(m.totalTokens) / Double(total)) : 0)
        })
    }
}

// ── Token type proportion bar (in / out / cache_r / cache_w) ──
struct TokenTypeBar: View {
    let usage: PeriodUsage
    var loc: ((String) -> String)? = nil

    // in/out use saturated teal & coral; cache_read/cache_write use desaturated tints of same hues
    static let typeEntries: [(String, Color, KeyPath<PeriodUsage, Int>)] = [
        ("tkIn",  Color(red: 0.10, green: 0.60, blue: 0.65), \.totalInput),      // teal
        ("tkOut", Color(red: 0.90, green: 0.40, blue: 0.30), \.totalOutput),      // coral
        ("tkCR",  Color(red: 0.55, green: 0.78, blue: 0.80), \.totalCacheRead),   // desaturated teal
        ("tkCW",  Color(red: 0.92, green: 0.70, blue: 0.62), \.totalCacheWrite),  // desaturated coral
    ]

    var body: some View {
        let l = loc ?? { i18n[.en]?[$0] ?? $0 }
        VStack(alignment: .leading, spacing: 4) {
            ProportionBar(segments: Self.typeEntries.map { (_, color, kp) in
                let val = usage[keyPath: kp]
                return (color: color, fraction: usage.totalTokens > 0
                    ? CGFloat(Double(val) / Double(usage.totalTokens)) : 0)
            })

            // Legend row
            HStack(spacing: 10) {
                ForEach(Array(Self.typeEntries.enumerated()), id: \.offset) { _, item in
                    let (key, color, kp) = item
                    HStack(spacing: 3) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(l(key))
                            .font(.system(size: 9))
                            .foregroundColor(color.opacity(0.9))
                        Text(formatTokensShort(usage[keyPath: kp]))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// ── Daily bar chart ──
struct DailyChart: View {
    let data: [DailyUsage]
    let mode: DisplayTab
    let year: Int
    let month: Int
    let loc: (String) -> String

    @State private var hoveredDay: Int? = nil

    private var daysInMonth: Int {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let start = cal.date(from: comps),
              let next = cal.date(byAdding: .month, value: 1, to: start),
              let last = cal.date(byAdding: .day, value: -1, to: next) else { return 30 }
        return cal.component(.day, from: last)
    }

    private var dayLookup: [Int: DailyUsage] {
        Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })
    }

    private var maxValue: Double {
        data.map { mode == .cost ? $0.cost : Double($0.totalTokens) }.max() ?? 1
    }

    // Which day numbers to show as x-axis labels
    private var labelDays: Set<Int> {
        let total = daysInMonth
        var labels: Set<Int> = [1]
        for d in stride(from: 5, through: total - 3, by: 5) { labels.insert(d) }
        labels.insert(total)
        return labels
    }

    private let chartHeight: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title + hover tooltip
            HStack(spacing: 4) {
                Text(loc("daily"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if let day = hoveredDay, let usage = dayLookup[day] {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(String(format: "%d/%d", month, day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    if mode == .cost {
                        Text(formatCost(usage.cost))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    } else {
                        Text(formatTokensShort(usage.totalTokens))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    // Model breakdown chips
                    ForEach(usage.models.filter {
                        mode == .cost ? $0.cost > 0 : $0.totalTokens > 0
                    }) { m in
                        HStack(spacing: 2) {
                            Circle().fill(m.color).frame(width: 4, height: 4)
                            Text(mode == .cost
                                 ? formatCost(m.cost)
                                 : formatTokensShort(m.totalTokens))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                } else if let day = hoveredDay, dayLookup[day] == nil {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(String(format: "%d/%d", month, day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    Text(loc("noData"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(height: 14)

            // Bar chart
            GeometryReader { geo in
                let totalDays = CGFloat(daysInMonth)
                let spacing: CGFloat = 1
                let barWidth = max(2, (geo.size.width - spacing * (totalDays - 1)) / totalDays)
                let ch = geo.size.height

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(1...daysInMonth, id: \.self) { day in
                        barView(day: day, barWidth: barWidth, chartHeight: ch)
                    }
                }
            }
            .frame(height: chartHeight)

            // X-axis labels
            GeometryReader { geo in
                let totalDays = CGFloat(daysInMonth)
                let spacing: CGFloat = 1
                let barWidth = (geo.size.width - spacing * (totalDays - 1)) / totalDays
                let step = barWidth + spacing

                ZStack(alignment: .leading) {
                    ForEach(Array(labelDays.sorted()), id: \.self) { day in
                        Text("\(day)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                            .position(
                                x: step * CGFloat(day - 1) + barWidth / 2,
                                y: 5
                            )
                    }
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Bar Chart Helpers

    @ViewBuilder
    private func barView(day: Int, barWidth: CGFloat, chartHeight: CGFloat) -> some View {
        if let usage = dayLookup[day] {
            let value = mode == .cost ? usage.cost : Double(usage.totalTokens)
            let height = maxValue > 0 ? CGFloat(value / maxValue) * chartHeight : 0
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                stackedBar(usage: usage, totalHeight: max(2, height), barWidth: barWidth,
                           highlighted: hoveredDay == day)
            }
            .frame(width: barWidth)
            .contentShape(Rectangle())
            .onHover { h in hoveredDay = h ? day : nil }
        } else {
            VStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: barWidth, height: 1)
            }
            .frame(width: barWidth)
            .contentShape(Rectangle())
            .onHover { h in hoveredDay = h ? day : nil }
        }
    }

    @ViewBuilder
    private func stackedBar(usage: DailyUsage, totalHeight: CGFloat, barWidth: CGFloat,
                            highlighted: Bool) -> some View {
        let total = mode == .cost ? usage.cost : Double(usage.totalTokens)
        if total > 0 {
            VStack(spacing: 0) {
                ForEach(usage.models) { model in
                    let modelVal = mode == .cost ? model.cost : Double(model.totalTokens)
                    let fraction = modelVal / total
                    let segHeight = max(0, CGFloat(fraction) * totalHeight)
                    if segHeight > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(model.color)
                            .frame(width: barWidth, height: segHeight)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(
                // Subtle top cap on hover
                highlighted ?
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                    : nil
            )
        }
    }
}

// ── Single model row (cost) ──
struct ModelRow: View {
    let model: ModelUsage

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.color)
                .frame(width: 8, height: 8)
            Text(model.name)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
            Spacer()
            Text(formatCost(model.cost))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// ── Single model row (tokens) ──
struct TokenModelRow: View {
    let model: ModelUsage
    var loc: ((String) -> String)? = nil

    var body: some View {
        let l = loc ?? { i18n[.en]?[$0] ?? $0 }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.color)
                    .frame(width: 8, height: 8)
                Text(model.name)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTokensShort(model.totalTokens))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.primary)
            }
            // Token breakdown sub-row
            HStack(spacing: 8) {
                TokenChip(label: l("tkIn"), value: model.inputTokens, color: TokenTypeBar.typeEntries[0].1)
                TokenChip(label: l("tkOut"), value: model.outputTokens, color: TokenTypeBar.typeEntries[1].1)
                TokenChip(label: l("tkCR"), value: model.cacheRead, color: TokenTypeBar.typeEntries[2].1)
                TokenChip(label: l("tkCW"), value: model.cacheWrite, color: TokenTypeBar.typeEntries[3].1)
            }
            .padding(.leading, 14)
        }
    }
}

// ── Compact token chip ──
struct TokenChip: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(color.opacity(0.8))
            Text(formatTokensShort(value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

// ── Period card ──
struct PeriodCard: View {
    let icon: String
    let title: String
    let usage: PeriodUsage
    var showStats: Bool = false
    var loc: ((String) -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title + cost
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatCost(usage.cost))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // Cost proportion bar
            if !usage.models.isEmpty {
                CostBar(models: usage.models, total: usage.cost)
                    .padding(.vertical, 2)
            }

            // Model breakdown
            ForEach(usage.models.filter { $0.cost >= 0.005 }) { m in
                ModelRow(model: m)
            }

            // Stats footer (month only)
            if showStats {
                HStack(spacing: 12) {
                    Label("\(formatNumber(usage.totalMessages))", systemImage: "message")
                    Label(formatTokens(usage.totalTokens, loc), systemImage: "number")
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// ── Period card (tokens) ──
struct TokenPeriodCard: View {
    let icon: String
    let title: String
    let usage: PeriodUsage
    var showStats: Bool = false
    var loc: ((String) -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title + total tokens
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatTokensShort(usage.totalTokens))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // Token type distribution bar (in / out / cache_r / cache_w)
            if usage.totalTokens > 0 {
                TokenTypeBar(usage: usage, loc: loc)
                    .padding(.vertical, 2)
            }

            // Model proportion bar
            if !usage.models.isEmpty {
                TokenBar(models: usage.models, total: usage.totalTokens)
                    .padding(.bottom, 2)
            }

            // Model breakdown
            ForEach(usage.models.filter { $0.totalTokens > 0 }) { m in
                TokenModelRow(model: m, loc: loc)
            }

            // Stats footer (month only)
            if showStats {
                HStack(spacing: 12) {
                    Label("\(formatNumber(usage.totalMessages))", systemImage: "message")
                    Label(formatCost(usage.cost), systemImage: "dollarsign.circle")
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// ── Language switcher (plain button → NSMenu, avoids accent color tinting) ──
struct LanguageSwitcher: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        btn.contentTintColor = .secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    class Coordinator: NSObject {
        let store: UsageStore
        init(store: UsageStore) { self.store = store }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            for lang in AppLanguage.allCases {
                let item = NSMenuItem(title: lang.displayName, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = lang
                if lang == store.language { item.state = .on }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pick(_ item: NSMenuItem) {
            if let lang = item.representedObject as? AppLanguage {
                store.setLanguage(lang)
            }
        }
    }
}

// ── Main popover content ──
// MARK: - Five-Hour Window Card (subscription quota + local measurement)

/// Horizontal progress bar with color coding (< 70 green / 70–90 amber / > 90 red / > 100 purple).
struct QuotaProgressBar: View {
    let percent: Int   // 0-100+
    var height: CGFloat = 8

    private var fraction: CGFloat { min(1.0, CGFloat(percent) / 100.0) }
    private var color: Color {
        switch percent {
        case ..<70:  return Color(red: 0.20, green: 0.78, blue: 0.45) // green
        case 70..<90: return Color(red: 0.95, green: 0.70, blue: 0.25) // amber
        case 90..<100: return Color(red: 0.90, green: 0.40, blue: 0.30) // coral
        default: return Color(red: 0.60, green: 0.35, blue: 0.75) // purple (> 100%)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.gray.opacity(0.18))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}

/// One row: label on the left, progress bar in the middle, pct + reset on the right.
struct QuotaRow: View {
    let label: String
    let percent: Int
    let resetAt: Date?
    let loc: (String) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .leading)
            QuotaProgressBar(percent: percent)
            Text("\(percent)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
            if let r = resetAt {
                Text(resetLabel(r))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func resetLabel(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

struct FiveHourWindowCard: View {
    @ObservedObject var store: UsageStore
    let loc: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(loc("win5hHeader"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let q = store.subscriptionQuota, let reset = q.fiveHourResetDate {
                    Text(resetHeaderLabel(reset))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Local measurement (always shown; from JSONL)
            if let today = store.today {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(loc("win5hLocal"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "$%.2f  ·  %d %@  ·  %@",
                                today.cost,
                                today.totalMessages,
                                loc("win5hMsgs"),
                                formatTokensShort(today.totalTokens)))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                }
            }

            Divider()
                .padding(.vertical, 2)

            // Subscription quota section — one of three states
            if let quota = store.subscriptionQuota {
                Text(loc("win5hQuotaSection"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                QuotaRow(label: loc("quota5h"),
                         percent: quota.five_hour.utilization,
                         resetAt: quota.fiveHourResetDate,
                         loc: loc)
                QuotaRow(label: loc("quota7d"),
                         percent: quota.seven_day.utilization,
                         resetAt: quota.sevenDayResetDate,
                         loc: loc)
                // Optional footnote flags
                HStack(spacing: 10) {
                    if quota.five_hour.utilization >= 90 {
                        Text(loc("quotaWarnHigh"))
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 0.90, green: 0.40, blue: 0.30))
                    }
                    if quota.extra_usage?.is_enabled == true {
                        Text(loc("quotaExtra"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else if store.hasOAuthToken {
                // Token present, API call failed
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(loc("quotaFetchFail"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            } else {
                // No OAuth token: user is API-key auth (Bedrock/Vertex/Console).
                // Correct state per Anthropic docs — not an error.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(loc("bedrockNote"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func resetHeaderLabel(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 60 { return String(format: loc("win5hResetsIn"), "<1m") }
        if seconds < 3600 {
            return String(format: loc("win5hResetsIn"), "\(Int(seconds / 60))m")
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return String(format: loc("win5hResetsIn"), "\(h)h \(m)m")
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                HStack(spacing: 6) {
                    ClaudeLogoShape()
                        .fill(Color(red: 0.851, green: 0.467, blue: 0.341))
                        .frame(width: 14, height: 14)
                    Text(store.loc("title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // ── Month Navigator (top-level, highest hierarchy) ──
            HStack {
                Button(action: { store.navigateMonth(offset: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(store.viewingMonthLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { store.navigateMonth(offset: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(store.isCurrentMonth)
                .opacity(store.isCurrentMonth ? 0.3 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // ── Tab Picker (Cost / Tokens) ──
            Picker("", selection: $store.selectedTab) {
                ForEach(DisplayTab.allCases, id: \.self) { tab in
                    Label(tab.label(store.loc), systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // ── 5-hour Window Card (subscription quota) ──
            // Only meaningful for Pro/Max users who signed in via OAuth. API-key users
            // (Bedrock / Vertex / Console) have no subscription quota to show — hide
            // the card entirely for them rather than cluttering the popover with a
            // "not applicable" note.
            if store.isCurrentMonth && store.hasOAuthToken {
                FiveHourWindowCard(store: store, loc: store.loc)
            }

            // ── Content (no scroll, show everything) ──
            if store.isCurrentMonth {
                if let today = store.today, let week = store.week, let month = store.month {
                    VStack(spacing: 8) {
                        if store.selectedTab == .cost {
                            PeriodCard(icon: "calendar", title: store.loc("today"), usage: today)
                            PeriodCard(icon: "calendar.badge.clock", title: store.loc("thisWeek"), usage: week)
                            PeriodCard(icon: "chart.bar", title: store.loc("thisMonth"), usage: month, showStats: true, loc: store.loc)
                        } else {
                            TokenPeriodCard(icon: "calendar", title: store.loc("today"), usage: today, loc: store.loc)
                            TokenPeriodCard(icon: "calendar.badge.clock", title: store.loc("thisWeek"), usage: week, loc: store.loc)
                            TokenPeriodCard(icon: "chart.bar", title: store.loc("thisMonth"), usage: month, showStats: true, loc: store.loc)
                        }
                        if let daily = store.dailyBreakdown, !daily.isEmpty {
                            DailyChart(data: daily, mode: store.selectedTab,
                                       year: store.viewingYear, month: store.viewingMonth,
                                       loc: store.loc)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                } else if store.isLoading {
                    loadingView
                } else {
                    errorView
                }
            } else {
                if let month = store.month {
                    VStack(spacing: 8) {
                        if store.selectedTab == .cost {
                            PeriodCard(icon: "chart.bar", title: store.loc("monthlyTotal"),
                                       usage: month, showStats: true, loc: store.loc)
                        } else {
                            TokenPeriodCard(icon: "chart.bar", title: store.loc("monthlyTotal"),
                                            usage: month, showStats: true, loc: store.loc)
                        }
                        if let daily = store.dailyBreakdown, !daily.isEmpty {
                            DailyChart(data: daily, mode: store.selectedTab,
                                       year: store.viewingYear, month: store.viewingMonth,
                                       loc: store.loc)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                } else if store.isLoading {
                    loadingView
                } else {
                    noDataView
                }
            }

            Divider()
                .padding(.horizontal, 10)

            // ── Footer ──
            HStack(spacing: 12) {
                if let time = store.lastUpdate, store.isCurrentMonth {
                    Text(String(format: store.loc("updated"),
                                timeAgo(time, store.loc)))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                } else if !store.isCurrentMonth {
                    Text(store.loc("cachedData"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Language switcher
                LanguageSwitcher(store: store)

                Button(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(store.loc("refresh"))
                .keyboardShortcut("r", modifiers: .command)

                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(store.loc("quit"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(store.loc("loading"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text(store.loc("loadFailed"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }

    private var noDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(store.loc("noMonthData"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store = UsageStore()
    private var refreshTimer: Timer?
    private var cancellable: AnyCancellable?

    // Claude official logo as a menu bar template image
    // SVG path from SimpleIcons (https://simpleicons.org/?q=claude), viewBox 0 0 24 24
    private func makeClaudeIcon(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let scale = size / 24.0
        let transform = NSAffineTransform()
        // SVG Y-axis is top-down, macOS is bottom-up → flip vertically
        transform.translateX(by: 0, yBy: size)
        transform.scaleX(by: scale, yBy: -scale)

        let path = NSBezierPath()
        // Official Claude logo SVG path data (from SimpleIcons, CC0 licensed)
        // Parsed into move/line/curve commands:
        path.move(to: NSPoint(x: 4.7144, y: 15.9555))
        path.line(to: NSPoint(x: 9.4318, y: 13.3084))
        path.line(to: NSPoint(x: 9.5108, y: 13.0777))
        path.line(to: NSPoint(x: 9.4318, y: 12.9502))
        path.line(to: NSPoint(x: 9.2011, y: 12.9502))
        path.line(to: NSPoint(x: 8.4118, y: 12.9016))
        path.line(to: NSPoint(x: 5.7162, y: 12.8287))
        path.line(to: NSPoint(x: 3.3787, y: 12.7316))
        path.line(to: NSPoint(x: 1.1141, y: 12.6102))
        path.line(to: NSPoint(x: 0.5434, y: 12.4887))
        path.line(to: NSPoint(x: 0.0091, y: 11.7845))
        path.line(to: NSPoint(x: 0.0637, y: 11.4323))
        path.line(to: NSPoint(x: 0.5434, y: 11.1105))
        path.line(to: NSPoint(x: 1.2294, y: 11.1713))
        path.line(to: NSPoint(x: 2.7473, y: 11.2745))
        path.line(to: NSPoint(x: 5.0240, y: 11.4323))
        path.line(to: NSPoint(x: 6.6754, y: 11.5295))
        path.line(to: NSPoint(x: 9.1222, y: 11.7845))
        path.line(to: NSPoint(x: 9.5108, y: 11.7845))
        path.line(to: NSPoint(x: 9.5654, y: 11.6266))
        path.line(to: NSPoint(x: 9.4318, y: 11.5295))
        path.line(to: NSPoint(x: 9.3286, y: 11.4323))
        path.line(to: NSPoint(x: 6.9730, y: 9.8356))
        path.line(to: NSPoint(x: 4.4230, y: 8.1477))
        path.line(to: NSPoint(x: 3.0874, y: 7.1763))
        path.line(to: NSPoint(x: 2.3649, y: 6.6845))
        path.line(to: NSPoint(x: 2.0006, y: 6.2231))
        path.line(to: NSPoint(x: 1.8428, y: 5.2153))
        path.line(to: NSPoint(x: 2.4985, y: 4.4928))
        path.line(to: NSPoint(x: 3.3788, y: 4.5535))
        path.line(to: NSPoint(x: 3.6034, y: 4.6142))
        path.line(to: NSPoint(x: 4.4959, y: 5.3002))
        path.line(to: NSPoint(x: 6.4023, y: 6.7756))
        path.line(to: NSPoint(x: 8.8916, y: 8.6092))
        path.line(to: NSPoint(x: 9.2559, y: 8.9127))
        path.line(to: NSPoint(x: 9.4016, y: 8.8095))
        path.line(to: NSPoint(x: 9.4198, y: 8.7367))
        path.line(to: NSPoint(x: 9.2558, y: 8.4634))
        path.line(to: NSPoint(x: 7.9019, y: 6.0167))
        path.line(to: NSPoint(x: 6.4569, y: 3.5274))
        path.line(to: NSPoint(x: 5.8134, y: 2.4954))
        path.line(to: NSPoint(x: 5.6434, y: 1.8760))
        path.curve(to: NSPoint(x: 5.5402, y: 1.1475),
                   controlPoint1: NSPoint(x: 5.5827, y: 1.6210),
                   controlPoint2: NSPoint(x: 5.5402, y: 1.4086))
        path.line(to: NSPoint(x: 6.2870, y: 0.1335))
        path.line(to: NSPoint(x: 6.6997, y: 0.0))
        path.line(to: NSPoint(x: 7.6954, y: 0.1336))
        path.line(to: NSPoint(x: 8.1144, y: 0.4978))
        path.line(to: NSPoint(x: 8.7336, y: 1.9125))
        path.line(to: NSPoint(x: 9.7354, y: 4.1407))
        path.line(to: NSPoint(x: 11.2897, y: 7.1703))
        path.line(to: NSPoint(x: 11.7450, y: 8.0688))
        path.line(to: NSPoint(x: 11.9879, y: 8.9006))
        path.line(to: NSPoint(x: 12.0789, y: 9.1556))
        path.line(to: NSPoint(x: 12.2368, y: 9.1556))
        path.line(to: NSPoint(x: 12.2368, y: 9.0099))
        path.line(to: NSPoint(x: 12.3643, y: 7.3039))
        path.line(to: NSPoint(x: 12.6011, y: 5.2092))
        path.line(to: NSPoint(x: 12.8318, y: 2.5135))
        path.line(to: NSPoint(x: 12.9107, y: 1.7546))
        path.line(to: NSPoint(x: 13.2871, y: 0.8439))
        path.line(to: NSPoint(x: 14.0339, y: 0.3521))
        path.line(to: NSPoint(x: 14.6167, y: 0.6314))
        path.line(to: NSPoint(x: 15.0964, y: 1.3174))
        path.line(to: NSPoint(x: 15.0296, y: 1.7607))
        path.line(to: NSPoint(x: 14.7443, y: 3.6124))
        path.line(to: NSPoint(x: 14.1857, y: 6.5145))
        path.line(to: NSPoint(x: 13.8214, y: 8.4574))
        path.line(to: NSPoint(x: 14.0339, y: 8.4574))
        path.line(to: NSPoint(x: 14.2768, y: 8.2145))
        path.line(to: NSPoint(x: 15.2603, y: 6.9092))
        path.line(to: NSPoint(x: 16.9117, y: 4.8449))
        path.line(to: NSPoint(x: 17.6403, y: 4.0253))
        path.line(to: NSPoint(x: 18.4903, y: 3.1207))
        path.line(to: NSPoint(x: 19.0367, y: 2.6896))
        path.line(to: NSPoint(x: 20.0688, y: 2.6896))
        path.line(to: NSPoint(x: 20.8278, y: 3.8189))
        path.line(to: NSPoint(x: 20.4878, y: 4.9846))
        path.line(to: NSPoint(x: 19.4253, y: 6.3324))
        path.line(to: NSPoint(x: 18.5449, y: 7.4738))
        path.line(to: NSPoint(x: 17.2821, y: 9.1738))
        path.line(to: NSPoint(x: 16.4928, y: 10.5338))
        path.line(to: NSPoint(x: 16.5657, y: 10.6431))
        path.line(to: NSPoint(x: 16.7539, y: 10.6248))
        path.line(to: NSPoint(x: 19.6074, y: 10.0178))
        path.line(to: NSPoint(x: 21.1495, y: 9.7384))
        path.line(to: NSPoint(x: 22.9891, y: 9.4227))
        path.line(to: NSPoint(x: 23.8209, y: 9.8113))
        path.line(to: NSPoint(x: 23.9119, y: 10.2059))
        path.line(to: NSPoint(x: 23.5841, y: 11.0134))
        path.line(to: NSPoint(x: 21.6171, y: 11.4991))
        path.line(to: NSPoint(x: 19.3099, y: 11.9605))
        path.line(to: NSPoint(x: 15.8735, y: 12.7741))
        path.line(to: NSPoint(x: 15.8310, y: 12.8045))
        path.line(to: NSPoint(x: 15.8796, y: 12.8652))
        path.line(to: NSPoint(x: 17.4278, y: 13.0109))
        path.line(to: NSPoint(x: 18.0896, y: 13.0473))
        path.line(to: NSPoint(x: 19.7106, y: 13.0473))
        path.line(to: NSPoint(x: 22.7281, y: 13.2720))
        path.line(to: NSPoint(x: 23.5173, y: 13.7940))
        path.line(to: NSPoint(x: 23.9909, y: 14.4316))
        path.line(to: NSPoint(x: 23.9119, y: 14.9173))
        path.line(to: NSPoint(x: 22.6977, y: 15.5366))
        path.line(to: NSPoint(x: 21.0584, y: 15.1480))
        path.line(to: NSPoint(x: 17.2334, y: 14.2373))
        path.line(to: NSPoint(x: 15.9221, y: 13.9094))
        path.line(to: NSPoint(x: 15.7399, y: 13.9094))
        path.line(to: NSPoint(x: 15.7399, y: 14.0187))
        path.line(to: NSPoint(x: 16.8328, y: 15.0873))
        path.line(to: NSPoint(x: 18.8363, y: 16.8965))
        path.line(to: NSPoint(x: 21.3438, y: 19.2279))
        path.line(to: NSPoint(x: 21.4713, y: 19.8047))
        path.line(to: NSPoint(x: 21.1495, y: 20.2601))
        path.line(to: NSPoint(x: 20.8095, y: 20.2115))
        path.line(to: NSPoint(x: 18.6056, y: 18.5540))
        path.line(to: NSPoint(x: 17.7556, y: 17.8072))
        path.line(to: NSPoint(x: 15.8310, y: 16.1862))
        path.line(to: NSPoint(x: 15.7035, y: 16.1862))
        path.line(to: NSPoint(x: 15.7035, y: 16.3562))
        path.line(to: NSPoint(x: 16.1467, y: 17.0058))
        path.line(to: NSPoint(x: 18.4903, y: 20.5272))
        path.line(to: NSPoint(x: 18.6117, y: 21.6079))
        path.line(to: NSPoint(x: 18.4417, y: 21.9600))
        path.line(to: NSPoint(x: 17.8346, y: 22.1725))
        path.line(to: NSPoint(x: 17.1667, y: 22.0511))
        path.line(to: NSPoint(x: 15.7946, y: 20.1265))
        path.line(to: NSPoint(x: 14.3800, y: 17.9590))
        path.line(to: NSPoint(x: 13.2386, y: 16.0162))
        path.line(to: NSPoint(x: 13.0989, y: 16.0952))
        path.line(to: NSPoint(x: 12.4249, y: 23.3504))
        path.line(to: NSPoint(x: 12.1093, y: 23.7207))
        path.line(to: NSPoint(x: 11.3807, y: 24.0000))
        path.line(to: NSPoint(x: 10.7736, y: 23.5386))
        path.line(to: NSPoint(x: 10.4518, y: 22.7918))
        path.line(to: NSPoint(x: 10.7736, y: 21.3165))
        path.line(to: NSPoint(x: 11.1622, y: 19.3919))
        path.line(to: NSPoint(x: 11.4779, y: 17.8619))
        path.line(to: NSPoint(x: 11.7632, y: 15.9615))
        path.line(to: NSPoint(x: 11.9332, y: 15.3301))
        path.line(to: NSPoint(x: 11.9211, y: 15.2876))
        path.line(to: NSPoint(x: 11.7814, y: 15.3058))
        path.line(to: NSPoint(x: 10.3486, y: 17.2730))
        path.line(to: NSPoint(x: 8.1690, y: 20.2176))
        path.line(to: NSPoint(x: 6.4447, y: 22.0632))
        path.line(to: NSPoint(x: 6.0319, y: 22.2272))
        path.line(to: NSPoint(x: 5.3155, y: 21.8568))
        path.line(to: NSPoint(x: 5.3822, y: 21.1950))
        path.line(to: NSPoint(x: 5.7830, y: 20.6061))
        path.line(to: NSPoint(x: 8.1690, y: 17.5704))
        path.line(to: NSPoint(x: 9.6079, y: 15.6884))
        path.line(to: NSPoint(x: 10.5369, y: 14.6016))
        path.line(to: NSPoint(x: 10.5307, y: 14.4437))
        path.line(to: NSPoint(x: 10.4761, y: 14.4437))
        path.line(to: NSPoint(x: 4.1376, y: 18.5601))
        path.line(to: NSPoint(x: 3.0083, y: 18.7058))
        path.line(to: NSPoint(x: 2.5226, y: 18.2504))
        path.line(to: NSPoint(x: 2.5834, y: 17.5037))
        path.line(to: NSPoint(x: 2.8141, y: 17.2608))
        path.line(to: NSPoint(x: 4.7205, y: 15.9494))
        path.close()

        path.transform(using: transform as AffineTransform)
        NSColor.black.setFill()
        path.fill()

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "CCCostMonitor"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = makeClaudeIcon()
            button.imagePosition = .imageLeft
            button.title = " … "
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover with SwiftUI content
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: PopoverView(store: store, onQuit: {
                NSApplication.shared.terminate(nil)
            })
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController

        // Observe current month data + tab changes to update menu bar title
        // Always shows current month regardless of which month is being viewed
        cancellable = Publishers.CombineLatest3(store.$currentMonthData, store.$selectedTab, store.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] monthData, tab, _ in
                guard let self = self, let monthData = monthData else { return }
                let title: String
                switch tab {
                case .cost:
                    title = formatCost(monthData.cost)
                case .tokens:
                    title = formatTokensShort(monthData.totalTokens)
                }
                self.statusItem.button?.title = " \(title) "
            }

        // Load cached data instantly, then refresh in background
        store.loadCacheForCurrentMonth()
        store.refresh()

        // Auto-refresh every 30 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }

        // Refresh on system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // Listen for "show popover" from a second instance launched via `open -n`
        // (normal `open` goes through applicationShouldHandleReopen instead)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onShowRequest),
            name: NSNotification.Name("com.claude.cc-cost-monitor.show"),
            object: nil
        )
    }

    // Called when user opens the app again (double-click, Spotlight, Launchpad, etc.)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func onShowRequest(_ note: Notification) {
        // DistributedNotification may arrive on a non-main thread
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    private func showPopover() {
        // Ensure the status item is visible in case macOS hid it in overflow
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func onWake(_ note: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.store.refresh()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring popover window to front
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Helpers

func formatCost(_ value: Double) -> String {
    if value >= 1000    { return String(format: "$%.0f", value) }
    if value >= 100     { return String(format: "$%.0f", value) }
    if value >= 10      { return String(format: "$%.1f", value) }
    return String(format: "$%.2f", value)
}

func formatTokens(_ count: Int, _ loc: ((String) -> String)? = nil) -> String {
    let l: (String) -> String = loc ?? { i18n[.en]?[$0] ?? $0 }
    if count >= 1_000_000 { return String(format: l("mTokens"), Double(count) / 1_000_000) }
    if count >= 1_000     { return String(format: l("kTokens"), Double(count) / 1_000) }
    return String(format: l("nTokens"), count)
}

func formatTokensShort(_ count: Int) -> String {
    if count >= 1_000_000_000 { return String(format: "%.1fb", Double(count) / 1_000_000_000) }
    if count >= 1_000_000 { return String(format: "%.1fm", Double(count) / 1_000_000) }
    if count >= 1_000     { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}

func formatNumber(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func timeAgo(_ date: Date, _ loc: ((String) -> String)? = nil) -> String {
    let l: (String) -> String = loc ?? { i18n[.en]?[$0] ?? $0 }
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60    { return l("justNow") }
    if seconds < 3600  { return String(format: l("mAgo"), seconds / 60) }
    if seconds < 86400 { return String(format: l("hAgo"), seconds / 3600) }
    return String(format: l("dAgo"), seconds / 86400)
}

// MARK: - Entry Point

// Single-instance guard for `open -n` (force-new-instance) scenarios.
// Normal `open` is handled by applicationShouldHandleReopen in AppDelegate.
let myBundleID = "com.claude.cc-cost-monitor"
let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
let isAlreadyRunning = running.contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if isAlreadyRunning {
    DistributedNotificationCenter.default().post(
        name: NSNotification.Name("com.claude.cc-cost-monitor.show"),
        object: nil
    )
    // Small delay so the notification is delivered before we exit
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
