import Foundation
import Combine

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
    @Published var hasOAuthToken: Bool = false {
        didSet {
            // The Plan tab is hidden for API-key users; if the token vanishes while
            // it's selected, drop back to Cost so the segmented picker stays valid.
            if !hasOAuthToken && selectedTab == .subscription {
                selectedTab = .cost
            }
        }
    }
    /// Last non-success result for the quota fetch, if any. Used to show error hints
    /// (token expired, rate limited, network, schema change).
    @Published var quotaError: QuotaError?

    var isCurrentMonth: Bool {
        let cal = AppDate.gregorian
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
        // Date construction is data-path (Gregorian year/month ints); only the
        // df.string(from:) output is human-facing and stays locale-aware.
        guard let date = AppDate.gregorian.date(from: comps) else { return "" }
        return df.string(from: date)
    }

    // Script discovery + Process spawning (incl. timeout machinery) live in
    // UsageScriptClient; ALL invocations still flow through scriptQueue below.
    private let scriptClient = UsageScriptClient()

    // Serial queue for ALL analyze_usage.py executions: rapid month flipping or
    // repeated ⌘R must never stack concurrent full Python scans.
    private let scriptQueue = DispatchQueue(label: "com.claude.cc-cost-monitor.scripts", qos: .utility)
    // Staleness guard (main thread only): bumped by month navigation and each new
    // scan, so a slow old scan's result can never paint over a newer view.
    private var fetchGeneration = 0
    // Coalescing flag (main thread only): a manual ⌘R while the 30-min auto-refresh
    // scan is in flight must not queue a second identical scan behind it.
    private var isRefreshInFlight = false

    // Cache directory: ~/.claude/cache/cc-monitor/
    private var cacheDir: String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cache/cc-monitor")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    init() {
        let cal = AppDate.gregorian
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

        // Probe OAuth state once at startup so UI can choose Bedrock vs subscription branch.
        hasOAuthToken = SubscriptionQuotaService.shared.hasOAuthToken
    }

    /// Fetch subscription quota from Anthropic's OAuth endpoint and update @Published state.
    /// Fast-paths for API-key users (no token): avoids unnecessary @Published churn and
    /// network calls. Safe to call repeatedly — the service caches for 5 minutes internally.
    func refreshQuota(force: Bool = false) {
        let probedHasToken = SubscriptionQuotaService.shared.hasOAuthToken
        if !probedHasToken {
            // API-key user. Only publish if state drifted (e.g. user ran `claude logout`).
            if hasOAuthToken || subscriptionQuota != nil || quotaError != nil {
                hasOAuthToken = false
                subscriptionQuota = nil
                quotaError = nil
            }
            return
        }
        SubscriptionQuotaService.shared.fetch(forceRefresh: force) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.hasOAuthToken { self.hasOAuthToken = true }
                switch result {
                case .success(let quota):
                    if self.subscriptionQuota != quota { self.subscriptionQuota = quota }
                    if self.quotaError != nil { self.quotaError = nil }
                case .noToken:
                    // Token disappeared between probe and fetch (user ran `claude logout`).
                    self.hasOAuthToken = false
                    self.subscriptionQuota = nil
                    self.quotaError = nil
                case .unauthorized:
                    self.subscriptionQuota = nil
                    self.quotaError = .unauthorized
                case .rateLimited:
                    // Keep any previously cached quota visible; just surface the error.
                    if self.quotaError != .rateLimited { self.quotaError = .rateLimited }
                case .networkFailure:
                    if self.quotaError != .networkFailure { self.quotaError = .networkFailure }
                case .decodeFailure:
                    if self.quotaError != .decodeFailure { self.quotaError = .decodeFailure }
                }
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
        guard let date = AppDate.gregorian.date(from: comps) else { return }
        let cal = AppDate.gregorian
        viewingYear = cal.component(.year, from: date)
        viewingMonth = cal.component(.month, from: date)

        // Invalidate any in-flight scan's view update — it was for the old month.
        fetchGeneration += 1

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
        fetchGeneration += 1
        let generation = fetchGeneration
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let range = AppDate.monthDateRange(year: y, month: m)
            let ym = String(format: "%04d-%02d", y, m)
            let (data, daily) = self.fetchMonthData(range, yearMonth: ym)
            DispatchQueue.main.async {
                // Guard: user might have navigated away — or a newer scan might have
                // superseded this one — while loading
                guard generation == self.fetchGeneration,
                      self.viewingYear == y && self.viewingMonth == m else { return }
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

        if isCurrentMonth {
            // Restore cached today/week/month synchronously so UI doesn't flash
            // empty while the async fetch runs.
            if self.today == nil {
                loadCacheForCurrentMonth()
            }
            if self.month == nil {
                DispatchQueue.main.async { self.isLoading = true }
            }
        } else {
            // Viewing a historical month: reload that view (cache hit or re-fetch).
            // The current-month async fetch below still runs so the menu-bar total
            // and on-disk cache stay fresh regardless of what the user is viewing.
            loadHistoricalMonth()
        }
        // Coalesce: if a current-month scan is already in flight (e.g. auto-refresh),
        // don't queue a second identical scan behind it — the menu-bar spinner
        // (isLoading) already reflects the one that's running.
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        // No generation needed here: isRefreshInFlight already serializes current-month
        // scans, and the result is always current-month data — whether to paint the
        // popover is fully decided by isCurrentMonth at completion time. (Generation
        // guarding is only load-bearing in loadHistoricalMonth, where a superseded
        // scan for a different month must not paint.)
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            // Single script call for the whole month
            let cal = AppDate.gregorian
            let now = Date()
            let nowYear = cal.component(.year, from: now)
            let nowMonth = cal.component(.month, from: now)
            let ym = String(format: "%04d-%02d", nowYear, nowMonth)
            let (m, daily) = self.fetchMonthData("month", yearMonth: ym)
            // If script failed, keep existing cached data visible
            guard m != nil else {
                DispatchQueue.main.async {
                    self.isRefreshInFlight = false
                    self.isLoading = false
                }
                return
            }
            // Derive today & week from daily breakdown
            let t = AppDate.deriveToday(daily)
            var w = AppDate.deriveWeek(daily)
            var weekStartKey: String? = nil
            if let monday = AppDate.mondayOfWeek(containing: now) {
                weekStartKey = AppDate.dayKey(monday)
                if AppDate.monthKey(monday) != ym {
                    // The week's Monday is in the PREVIOUS month: the month scan
                    // (1st..today) misses up to 6 of this week's days, so run ONE
                    // extra scan for exactly Monday..today. It runs sequentially
                    // inside this same scriptQueue work item — no re-entrancy
                    // with the isRefreshInFlight coalescing. A range scan returns
                    // the same JSON shape as a month scan, so its totals ARE the
                    // week totals. The week is a superset of the month-derived
                    // week — never accept a smaller value (failed/partial scan
                    // falls back to the month-derived week, same as before).
                    let range = "\(weekStartKey!):\(AppDate.dayKey(now))"
                    if let json = self.scriptClient.runScript(["--json", "--range", range]),
                       let crossWeek = UsageParser.parsePeriod(json),
                       crossWeek.cost >= w.cost {
                        w = crossWeek
                    }
                }
            }
            DispatchQueue.main.async {
                self.isRefreshInFlight = false
                // Menu-bar total and cache persistence are always about the current month,
                // so update them regardless of what the user is currently viewing.
                self.currentMonthData = m
                self.lastUpdate = Date()
                if let m = m {
                    self.saveCache(
                        year: nowYear, month: nowMonth,
                        data: m, daily: daily,
                        week: w, weekStart: weekStartKey)
                }
                // Popover fields (today/week/month/dailyBreakdown) feed the active view.
                // Only skip painting when the user is viewing a historical month —
                // this scan's data is current-month by definition, so painting while
                // viewing the current month is always correct.
                guard self.isCurrentMonth else {
                    self.isLoading = false
                    return
                }
                self.today = t
                self.week = w
                self.month = m
                self.dailyBreakdown = daily
                self.isLoading = false
            }
        }
    }

    // MARK: - Cache I/O

    private func cachePath(year: Int, month: Int) -> String {
        return (cacheDir as NSString).appendingPathComponent(
            String(format: "%04d-%02d.json", year, month))
    }

    private func saveCache(year: Int, month: Int, data: PeriodUsage, daily: [DailyUsage]? = nil,
                           week: PeriodUsage? = nil, weekStart: String? = nil) {
        var snapshot = MonthlySnapshot(year: year, month: month, data: data, lastUpdated: Date())
        snapshot.dailyBreakdown = daily
        snapshot.week = week
        snapshot.weekStart = weekStart
        guard let jsonData = UsageParser.encodeSnapshot(snapshot) else { return }
        try? jsonData.write(to: URL(fileURLWithPath: cachePath(year: year, month: month)))
    }

    private func loadCache(year: Int, month: Int) -> PeriodUsage? {
        return loadCacheSnapshot(year: year, month: month)?.data
    }

    private func loadCacheSnapshot(year: Int, month: Int) -> MonthlySnapshot? {
        let path = cachePath(year: year, month: month)
        guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return UsageParser.decodeSnapshot(rawData)
    }

    /// Load cached data for the current month and display immediately (before background refresh)
    func loadCacheForCurrentMonth() {
        let cal = AppDate.gregorian
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        guard let snapshot = loadCacheSnapshot(year: y, month: m) else {
            // No cache yet (fresh install, or returning to current month with only
            // historical state loaded). Clear stale fields so the UI shows the
            // loading spinner rather than a historical-month-data ghost or errorView.
            self.today = nil
            self.week = nil
            self.month = nil
            self.dailyBreakdown = nil
            return
        }
        let daily = snapshot.dailyBreakdown
        // Derive today/week from daily breakdown, or set empty fallback (old cache format)
        if daily != nil {
            self.today = AppDate.deriveToday(daily)
            // Restore the persisted (cross-month-safe) week only if it still covers
            // THIS week — its Monday must match — and is at least the month-derived
            // value (the persisted week is a superset). Otherwise, or for old cache
            // files without the field, fall back to deriving from daily; the refresh
            // that follows immediately self-corrects.
            let derivedWeek = AppDate.deriveWeek(daily)
            if let cachedWeek = snapshot.week,
               let cachedStart = snapshot.weekStart,
               let monday = AppDate.mondayOfWeek(containing: now),
               cachedStart == AppDate.dayKey(monday),
               cachedWeek.cost >= derivedWeek.cost {
                self.week = cachedWeek
            } else {
                self.week = derivedWeek
            }
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
    //
    // Process spawning lives in UsageScriptClient; JSON parsing in UsageParser
    // (Core_UsageParser.swift). These thin wrappers run inside scriptQueue work
    // items only — the queue/coalescing/generation logic above is unchanged.

    private func fetchPeriod(_ range: String) -> PeriodUsage? {
        guard let json = scriptClient.runScript(["--json", "--range", range]) else { return nil }
        return UsageParser.parsePeriod(json)
    }

    /// Fetch month data with daily breakdown from a single script call
    /// yearMonth: "YYYY-MM" string for filtering daily data (e.g. "2026-04")
    private func fetchMonthData(_ range: String, yearMonth: String) -> (PeriodUsage?, [DailyUsage]?) {
        guard let json = scriptClient.runScript(["--json", "--range", range]) else { return (nil, nil) }
        let period = UsageParser.parsePeriod(json)
        let daily = UsageParser.parseDailyBreakdown(json, yearMonth: yearMonth)
        return (period, daily)
    }
}
