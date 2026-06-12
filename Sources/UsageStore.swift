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

    // MARK: Active time ("Time" tab)

    // Current month's active-time data, cross-week merged (days from the extra
    // Monday..today scan replace month-scan days when the week spans a month
    // boundary). Feeds the menu-bar title and the Week sub-view; unaffected by
    // month navigation — mirrors currentMonthData. nil = old script / old cache
    // without the "time" section → empty/loading state in the UI.
    @Published var currentTimeData: TimeData?
    // Follows month navigation (equals currentTimeData when viewing the
    // current month) — feeds the Month sub-view, mirrors `month`/`dailyBreakdown`.
    @Published var viewingTimeData: TimeData?
    // Today's active total, derived from currentTimeData + today's dayKey.
    // Day rollover repaints via the 30-min timer: the fingerprint includes the
    // dayKey, so the rollover tick runs a real scan and republishes.
    @Published var timeTodaySeconds: Int = 0
    // Inner Week / Month / Year switcher. Switching to Year lazily loads that
    // year's data (no-op when the in-memory cache already has it).
    @Published var timeRange: TimeRange = .week {
        didSet {
            guard timeRange == .year, oldValue != .year else { return }
            // Async: the didSet fires inside a SwiftUI binding write — mutating
            // other @Published fields synchronously here would publish during
            // view updates.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.loadYearTime(self.viewingTimeYear)
            }
        }
    }
    // Year shown by the Year sub-view (own ◀▶ nav, independent of month nav).
    @Published var viewingTimeYear: Int
    // Week sub-view selection: the Monday of the selected week, nil = "use the
    // default rule" (viewing the current month → the week containing today;
    // any other month → that month's first week). Month navigation resets it
    // to nil; ⌘R / refresh leaves it alone. Stored as nil-means-default so day
    // rollover self-corrects instead of freezing a stale computed default.
    @Published var selectedWeekMonday: Date?
    // Visible year's per-day totals ("yyyy-MM-dd" → seconds). nil = loading,
    // empty dict = fetch failed (retry via nav / ⌘R; failures aren't cached).
    @Published var yearTimeDays: [String: Int]?
    // In-memory per-year cache (main thread only). ⌘R clears it.
    private var yearTimeCache: [Int: [String: Int]] = [:]
    // Staleness guard for year fetches (main thread only), same pattern as
    // fetchGeneration for historical months.
    private var yearFetchGeneration = 0

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

    // P1-4(a) fingerprint short-circuit (scriptQueue only): if nothing the month
    // scan reads has changed since the last SUCCESSFUL scan, skip spawning Python
    // and republish the stored results. Both fields are read/written exclusively
    // inside scriptQueue work items (serial queue), so no extra locking is needed.
    private var lastScanFingerprint: String?
    private var lastScanResults: ScanResults?

    /// Parsed output of the last successful current-month scan, kept so a
    /// fingerprint-matched refresh can republish without re-running the script.
    private struct ScanResults {
        let today: PeriodUsage
        let week: PeriodUsage
        let month: PeriodUsage
        let daily: [DailyUsage]?
        let time: TimeData?
    }

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
        viewingTimeYear = cal.component(.year, from: now)

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

        // Changing months invalidates the Week sub-view's selection: back to
        // the default rule for the newly viewed month.
        selectedWeekMonday = nil

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
        // Try cache first. Must have daily data AND a time section, otherwise
        // re-fetch: caches written before the Time tab existed have no `time`,
        // and accepting them would leave the Time month view permanently empty.
        // The re-fetch re-caches with `time` — one extra scan per old month,
        // self-healing.
        if let snapshot = loadCacheSnapshot(year: y, month: m),
           snapshot.dailyBreakdown != nil, snapshot.time != nil {
            self.today = nil
            self.week = nil
            self.month = snapshot.data
            self.dailyBreakdown = snapshot.dailyBreakdown
            self.viewingTimeData = snapshot.time
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
            let (data, daily, time) = self.fetchMonthData(range, yearMonth: ym)
            DispatchQueue.main.async {
                // Guard: user might have navigated away — or a newer scan might have
                // superseded this one — while loading
                guard generation == self.fetchGeneration,
                      self.viewingYear == y && self.viewingMonth == m else { return }
                self.today = nil
                self.week = nil
                self.month = data
                self.dailyBreakdown = daily
                self.viewingTimeData = time
                self.isLoading = false
                if let data = data {
                    self.saveCache(year: y, month: m, data: data, daily: daily, time: time)
                }
            }
        }
    }

    // MARK: - Refresh (current month)

    /// - Parameter force: bypass the fingerprint short-circuit and always run a
    ///   real scan (manual ⌘R). Does NOT bypass isRefreshInFlight coalescing.
    func refresh(force: Bool = false) {
        // Refresh subscription quota in parallel (no-op for API-key users).
        // It keeps its own independent 5-minute cache — unaffected by the
        // JSONL fingerprint below.
        refreshQuota()

        // ⌘R also invalidates the per-year time cache; refetch only the year
        // the user is actually looking at (other years reload lazily on nav).
        if force {
            yearTimeCache.removeAll()
            if selectedTab == .time && timeRange == .year {
                loadYearTime(viewingTimeYear, force: true)
            }
        }

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

            // P1-4(a): cheap (path, mtime, size) stat-walk over everything the
            // month scan reads, plus the scan-range inputs (month key, today's
            // day key, cross-month-week flag — so midnight/month/week rollovers
            // naturally bust it). Computed BEFORE the scan so a file changing
            // mid-scan can't be masked: the stored (pre-scan) fingerprint then
            // differs from the next computation → next refresh scans for real.
            let weekMonday = AppDate.mondayOfWeek(containing: now)
            let weekCrossesMonth = weekMonday.map { AppDate.monthKey($0) != ym } ?? false
            var fingerprint = self.computeScanFingerprint(
                monthKey: ym, dayKey: AppDate.dayKey(now), weekCrossesMonth: weekCrossesMonth)
            if !force,
               let fp = fingerprint,
               fp == self.lastScanFingerprint,
               let cached = self.lastScanResults {
                // Nothing the script reads has changed since the last SUCCESSFUL
                // scan: skip spawning Python entirely and republish the stored
                // results. lastUpdate IS refreshed — "data as of now" is honest
                // because we just verified the data is current. isLoading was
                // never raised for this path (the pre-queue code only shows the
                // spinner when month == nil, which implies no stored results),
                // so the spinner doesn't blink.
                DispatchQueue.main.async {
                    self.isRefreshInFlight = false
                    self.currentMonthData = cached.month
                    self.currentTimeData = cached.time
                    self.recomputeTimeToday()
                    self.lastUpdate = Date()
                    guard self.isCurrentMonth else {
                        self.isLoading = false
                        return
                    }
                    self.today = cached.today
                    self.week = cached.week
                    self.month = cached.month
                    self.dailyBreakdown = cached.daily
                    self.viewingTimeData = cached.time
                    self.isLoading = false
                }
                return
            }

            let (m, daily, monthTime) = self.fetchMonthData("month", yearMonth: ym)
            // If script failed, keep existing cached data visible
            guard m != nil else {
                // A failed scan must never be short-circuited over: drop the
                // stored fingerprint so the next refresh runs a real scan.
                self.lastScanFingerprint = nil
                self.lastScanResults = nil
                DispatchQueue.main.async {
                    self.isRefreshInFlight = false
                    self.isLoading = false
                }
                return
            }
            // Derive today & week from daily breakdown
            let t = AppDate.deriveToday(daily)
            var w = AppDate.deriveWeek(daily)
            var crossWeekTime: TimeData? = nil
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
                    // The same JSON carries a "time" section for Monday..today —
                    // captured only when the scan is accepted, merged below.
                    let range = "\(weekStartKey!):\(AppDate.dayKey(now))"
                    if let json = self.scriptClient.runScript(["--json", "--no-sessions", "--range", range]),
                       let crossWeek = UsageParser.parsePeriod(json),
                       crossWeek.cost >= w.cost {
                        w = crossWeek
                        crossWeekTime = UsageParser.parseTimeSection(json)
                    } else {
                        // Extra scan failed (timeout/script error): the week card
                        // falls back to the smaller month-derived value. Don't let
                        // the fingerprint freeze that undercount — invalidate it so
                        // the next refresh retries the extra scan (the time merge
                        // below likewise falls back to month-scan days only).
                        fingerprint = nil
                    }
                }
            }
            // Cross-week days REPLACE month days (the extra scan's file set is a
            // superset for Monday..today; see UsageParser.mergeTimeData). The
            // merged dict may contain prev-month day keys — harmless, the month
            // view filters by yearMonth prefix and the Week view wants them.
            let mergedTime = UsageParser.mergeTimeData(base: monthTime, override: crossWeekTime)
            // Scan succeeded: remember the PRE-scan fingerprint + parsed results
            // (scriptQueue-only fields) so an unchanged-world refresh can skip
            // the next spawn. `fingerprint` may be nil (enumeration error) — a
            // nil stored value simply never matches, forcing a real scan.
            self.lastScanFingerprint = fingerprint
            if let m = m {
                self.lastScanResults = ScanResults(today: t, week: w, month: m, daily: daily,
                                                   time: mergedTime)
            }
            DispatchQueue.main.async {
                self.isRefreshInFlight = false
                // Menu-bar total and cache persistence are always about the current month,
                // so update them regardless of what the user is currently viewing.
                self.currentMonthData = m
                self.currentTimeData = mergedTime
                self.recomputeTimeToday()
                self.lastUpdate = Date()
                if let m = m {
                    self.saveCache(
                        year: nowYear, month: nowMonth,
                        data: m, daily: daily,
                        week: w, weekStart: weekStartKey,
                        time: mergedTime)
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
                self.viewingTimeData = mergedTime
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
                           week: PeriodUsage? = nil, weekStart: String? = nil,
                           time: TimeData? = nil) {
        var snapshot = MonthlySnapshot(year: year, month: month, data: data, lastUpdated: Date())
        snapshot.dailyBreakdown = daily
        snapshot.week = week
        snapshot.weekStart = weekStart
        snapshot.time = time
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
            self.currentTimeData = nil
            self.viewingTimeData = nil
            self.recomputeTimeToday()
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
        // Old (pre-Time-tab) caches have no `time` → nil → the Time tab shows
        // its empty/loading state until the background refresh fills it in.
        self.currentTimeData = snapshot.time
        self.viewingTimeData = snapshot.time
        self.recomputeTimeToday()
        self.lastUpdate = snapshot.lastUpdated
        self.isLoading = false
    }

    /// Recompute today's active total from currentTimeData. Main thread only
    /// (mutates @Published state). Guarded publish to limit menu-bar churn.
    private func recomputeTimeToday(now: Date = Date()) {
        let seconds = currentTimeData?.days[AppDate.dayKey(now)]?.totalSeconds ?? 0
        if timeTodaySeconds != seconds { timeTodaySeconds = seconds }
    }

    // MARK: - Year time loading (--time-year)

    /// Load per-day totals for `year` into yearTimeDays. Serves the in-memory
    /// per-year cache unless `force`; otherwise runs `--time-year` on the same
    /// serial scriptQueue (existing 120s timeout machinery applies). A failed
    /// fetch publishes an empty dict (empty heatmap, NOT cached) so nav / ⌘R
    /// retries it. Main thread only.
    func loadYearTime(_ year: Int, force: Bool = false) {
        viewingTimeYear = year
        if !force, let cached = yearTimeCache[year] {
            yearTimeDays = cached
            return
        }
        yearTimeDays = nil  // loading state
        yearFetchGeneration += 1
        let generation = yearFetchGeneration
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let json = self.scriptClient.runScript(["--time-year", "\(year)"])
            let parsed = json.flatMap { UsageParser.parseYearTime($0) }
            DispatchQueue.main.async {
                // Guard: user may have navigated to another year (or a newer
                // fetch superseded this one) while the scan ran.
                guard generation == self.yearFetchGeneration,
                      self.viewingTimeYear == year else { return }
                if let parsed = parsed, parsed.year == year {
                    self.yearTimeCache[year] = parsed.days
                    self.yearTimeDays = parsed.days
                } else {
                    self.yearTimeDays = [:]
                }
            }
        }
    }

    /// ◀▶ year navigation for the Year sub-view.
    func navigateTimeYear(offset: Int) {
        loadYearTime(viewingTimeYear + offset)
    }

    // MARK: - Week sub-view navigation

    /// The Monday the Week sub-view shows right now: the explicit selection if
    /// any, else the default rule for the viewed month (current month → the
    /// week containing today; other months → the month's first week).
    var resolvedWeekMonday: Date? {
        selectedWeekMonday ?? TimeLogic.defaultWeekMonday(
            year: viewingYear, month: viewingMonth, today: Date())
    }

    /// ◀▶ week navigation among the Monday-aligned weeks overlapping the
    /// viewed month, clamped to that list — cross-month jumps are not a thing
    /// here, months change via the top month navigator (which resets the
    /// selection). A stale/absent selection falls back to the first week.
    func navigateTimeWeek(offset: Int) {
        let weeks = TimeLogic.weeksOfMonth(year: viewingYear, month: viewingMonth)
        guard !weeks.isEmpty else { return }
        let current = resolvedWeekMonday.flatMap { TimeLogic.weekIndex(of: $0, in: weeks) } ?? 0
        selectedWeekMonday = weeks[min(max(current + offset, 0), weeks.count - 1)]
    }

    // MARK: - Script execution
    //
    // Process spawning lives in UsageScriptClient; JSON parsing in UsageParser
    // (Core_UsageParser.swift). These thin wrappers run inside scriptQueue work
    // items only — the queue/coalescing/generation logic above is unchanged.

    private func fetchPeriod(_ range: String) -> PeriodUsage? {
        guard let json = scriptClient.runScript(["--json", "--no-sessions", "--range", range]) else { return nil }
        return UsageParser.parsePeriod(json)
    }

    /// Fetch month data with daily breakdown + active-time section from a
    /// single script call.
    /// yearMonth: "YYYY-MM" string for filtering daily data (e.g. "2026-04")
    private func fetchMonthData(_ range: String, yearMonth: String) -> (PeriodUsage?, [DailyUsage]?, TimeData?) {
        guard let json = scriptClient.runScript(["--json", "--no-sessions", "--range", range]) else { return (nil, nil, nil) }
        let period = UsageParser.parsePeriod(json)
        let daily = UsageParser.parseDailyBreakdown(json, yearMonth: yearMonth)
        let time = UsageParser.parseTimeSection(json)
        return (period, daily, time)
    }

    // MARK: - Scan fingerprint (P1-4a)

    /// Aggregate (path, mtime, size) over every *.jsonl under ~/.claude/projects,
    /// plus the scan-range inputs and the script identity. Pure stat() walk —
    /// a few hundred files ≈ milliseconds. Runs ONLY inside scriptQueue work
    /// items (it's I/O; and the lastScanFingerprint fields it feeds are
    /// scriptQueue-confined).
    ///
    /// Returns nil on ANY enumeration/stat error → caller treats it as
    /// "changed" and runs a real scan.
    private func computeScanFingerprint(monthKey: String, dayKey: String,
                                        weekCrossesMonth: Bool) -> String? {
        let fm = FileManager.default
        let projectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectsDir, isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false  // stop walking; we'll run a real scan instead
            }
        ) else { return nil }

        var entries: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            entries.append("\(url.path)|\(mtime.timeIntervalSinceReferenceDate)|\(size)")
        }
        if enumerationFailed { return nil }
        // Enumeration order isn't guaranteed stable across runs — sort so the
        // same file set always digests identically.
        entries.sort()
        // Hasher's per-process random seed is fine: the fingerprint is only
        // ever compared against one computed earlier in this same process.
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry) }
        let fileDigest = hasher.finalize()
        return "\(fileDigest)|n=\(entries.count)|\(monthKey)|\(dayKey)|w=\(weekCrossesMonth)|\(scriptClient.scriptPath)"
    }
}
