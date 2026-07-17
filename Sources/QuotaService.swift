import Foundation

/// App version, single-sourced from Info.plist (CFBundleShortVersionString).
/// When run as a bare binary in dev (no bundle plist), falls back to "0.0".
fileprivate let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"

/// UI-facing subset of QuotaFetchResult — only the states worth surfacing to the user.
enum QuotaError: Equatable {
    case unauthorized     // 401/403 — token expired or revoked
    case rateLimited      // 429 — Anthropic throttled us
    case networkFailure   // transient
    case decodeFailure    // schema drift — likely benign but worth logging
}

/// Result type that lets the UI distinguish "no subscription" from real failures.
enum QuotaFetchResult {
    case success(OAuthUsage)
    case noToken                 // API-key user — expected state, hide the card
    case unauthorized            // 401, token expired — suggest `claude login`
    case rateLimited             // 429 — Anthropic throttled us
    case networkFailure          // connection/timeout — transient
    case decodeFailure           // 200 response but unexpected schema — worth logging
}

// MARK: Keychain access via the `security` CLI
//
// We deliberately shell out to the Apple-signed `/usr/bin/security` instead of calling
// `SecItemCopyMatching` in-process. macOS binds the "Always Allow" Keychain grant to the
// *requesting process's* code signature: in-process that's CCCostMonitor's own self-signed,
// frequently-rebuilt identity, so the grant breaks on every rebuild / Claude Code token
// refresh and the user is re-prompted. Routing through `/usr/bin/security` binds the grant
// to that binary's stable system signature, so it's granted once and then persists.
//
// Tradeoff: once `security` is "Always Allow"-ed, any same-user process can read the item by
// spawning `security` too. That's the same exposure Claude Code's own item already has.
enum KeychainCLI {
    /// Run `/usr/bin/security` with `args`; return stdout on exit 0 (empty string allowed), else nil.
    static func runSecurity(_ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Read the credentials blob (`-w` reads the secret → this is the call that may prompt once).
    /// Hex-vs-raw decoding is pure and lives in KeychainCodec (Core_KeychainCodec.swift).
    static func readBlob(service: String) -> Data? {
        guard let out = runSecurity(["find-generic-password", "-s", service, "-w"]) else { return nil }
        return KeychainCodec.decodeSecurityValue(out)?.data(using: .utf8)
    }

    /// Discover the item's account for write-back (attributes only, no `-w`, no prompt).
    static func account(service: String) -> String {
        if let out = runSecurity(["find-generic-password", "-s", service]) {
            for line in out.split(separator: "\n") {
                if let r = line.range(of: "\"acct\"<blob>=\"") {
                    let rest = line[r.upperBound...]
                    if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
                }
            }
        }
        return NSUserName()
    }

    /// Write refreshed credentials back via `security ... -U`. Value must be newline-free JSON
    /// (see KeychainCodec.decodeSecurityValue) or Claude Code can't read its own item back.
    @discardableResult
    static func writeBlob(service: String, account: String, json: Data) -> Bool {
        guard let str = String(data: json, encoding: .utf8) else { return false }
        // NOTE: the value is passed as a CLI argument, briefly visible to same-user processes
        // via `ps`. Acceptable: any same-user process can already read the item via `security`.
        return runSecurity(["add-generic-password", "-U", "-a", account, "-s", service, "-w", str]) != nil
    }
}

// MARK: Credential load / write-back routing
//
// SECURITY INVARIANT: tokens never leave their credential sources (env / file / keychain) —
// they are held in memory only for the duration of a request and are never logged or cached.
//
// Stateless routing over the three credential sources Claude Code uses. The
// SubscriptionQuotaService serial workQueue remains the only concurrency authority:
// every call into this type happens on that queue (or, for the very first
// hasOAuthToken probe, synchronously before any other credential work exists).
enum CredentialStore {
    /// Keychain item Claude Code stores its OAuth credentials under (mirrors Claude Code).
    static let keychainService = "Claude Code-credentials"

    /// Parsed Claude Code OAuth credentials plus where they were read from, so a refreshed
    /// token can be written back to the same place.
    struct OAuthCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAtMs: Double?        // epoch ms — matches Claude Code's `expiresAt`
        let source: Source
        var fullData: [String: Any]     // entire credentials JSON, round-tripped on save

        enum Source {
            case env                    // CLAUDE_CODE_OAUTH_TOKEN — read-only, no refresh
            case file(path: String)
            case keychain(service: String)
        }

        /// Fold the (possibly refreshed) token fields back into `fullData` so every other
        /// field Claude Code stores (scopes, subscriptionType, …) survives the write-back.
        mutating func syncIntoFullData() {
            var oauth = (fullData["claudeAiOauth"] as? [String: Any]) ?? [:]
            oauth["accessToken"] = accessToken
            if let r = refreshToken { oauth["refreshToken"] = r }
            if let e = expiresAtMs { oauth["expiresAt"] = Int(e.rounded()) }
            fullData["claudeAiOauth"] = oauth
        }
    }

    /// The actual existence check: env → plaintext file → keychain attributes (no `-w`).
    static func probeTokenPresence() -> Bool {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
            return true
        }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           parseCredentials(data, source: .file(path: path)) != nil {
            return true
        }
        return KeychainCLI.runSecurity(["find-generic-password", "-s", keychainService]) != nil
    }

    /// Load credentials from env → plaintext file → Keychain (via the `security` CLI).
    static func loadCredentials() -> OAuthCredentials? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
            return OAuthCredentials(accessToken: env, refreshToken: nil, expiresAtMs: nil,
                                    source: .env, fullData: [:])
        }
        // 1. `~/.claude/.credentials.json` — Linux, or macOS opted out of Keychain.
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let creds = parseCredentials(data, source: .file(path: path)) {
            return creds
        }
        // 2. macOS Keychain — the default location Claude Code uses on macOS.
        if let data = KeychainCLI.readBlob(service: keychainService),
           let creds = parseCredentials(data, source: .keychain(service: keychainService)) {
            return creds
        }
        return nil
    }

    /// Extract the OAuth fields + retain the full JSON from a Claude Code credentials blob.
    static func parseCredentials(_ data: Data, source: OAuthCredentials.Source) -> OAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        return OAuthCredentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMs: oauth["expiresAt"] as? Double,
            source: source,
            fullData: json
        )
    }

    /// Persist (refreshed) credentials back to whichever source they came from.
    /// Re-reads the source first and merges our refreshed token fields into the FRESHEST
    /// blob — Claude Code may have rewritten the item (new scopes, …) since we loaded it
    /// minutes earlier, and a whole-blob write of stale data would clobber that.
    /// Must only be called from SubscriptionQuotaService's serial workQueue.
    static func saveCredentials(_ creds: OAuthCredentials) {
        var creds = creds
        switch creds.source {
        case .env:
            return  // injected token — nothing to persist
        case .file(let path):
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let fresh = parseCredentials(data, source: creds.source) {
                creds.fullData = fresh.fullData
            }
            creds.syncIntoFullData()
            // NOTE: these failure logs deliberately carry ONLY the filesystem
            // error (and at most the well-known credential path) — NEVER the JSON
            // blob / access or refresh token. A silent failure here was the audit
            // finding O: a dropped write/chmod/keychain result can leave the
            // refreshed token unpersisted (worst case logging Claude Code out)
            // with no signal, inconsistent with the 2.1.1 archive-dir NSLog.
            guard let json = try? JSONSerialization.data(withJSONObject: creds.fullData) else {
                NSLog("CCCostMonitor: token persist skipped — could not encode credentials JSON")
                return
            }
            do {
                try json.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                NSLog("CCCostMonitor: refreshed-token write failed: \(error.localizedDescription)")
                return
            }
            // Atomic replace swaps in a new inode — restore the credential file's
            // tight permissions afterwards.
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            } catch {
                NSLog("CCCostMonitor: credential file chmod 0600 failed: \(error.localizedDescription)")
            }
        case .keychain(let service):
            if let data = KeychainCLI.readBlob(service: service),
               let fresh = parseCredentials(data, source: creds.source) {
                creds.fullData = fresh.fullData
            }
            creds.syncIntoFullData()
            guard let json = try? JSONSerialization.data(withJSONObject: creds.fullData) else {
                NSLog("CCCostMonitor: token persist skipped — could not encode credentials JSON")
                return
            }
            if !KeychainCLI.writeBlob(service: service,
                                      account: KeychainCLI.account(service: service), json: json) {
                NSLog("CCCostMonitor: refreshed-token keychain write-back failed (token rotation not persisted)")
            }
        }
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
    // After a 429, the absolute instant before which we must NOT re-hit the endpoint
    // (honors the server's `Retry-After`). Guarded by `lock`, same as `cached`.
    //
    // This is the fix for the rate-limit death-spiral: `cached` is written only on a
    // 200, so once the last success ages past `ttl`, the success-cache guard no longer
    // short-circuits anything and EVERY refresh trigger (popover-open, FSEvents ~2min,
    // notch hover, the 30-min timer, every ⌘R) re-pokes the throttled endpoint. Each
    // poke returns a fresh, near-full `Retry-After`, so the window keeps resetting and
    // never clears while the app is in use. Sitting out the cooldown lets it elapse.
    //
    // Distinct from the 5-min success cache: that is client-side freshness (⌘R may
    // bypass it); this is a server-imposed hard limit (⌘R must respect it — forcing
    // past it just resets the penalty clock).
    private var rateLimitedUntil: Date?
    private let lock = NSLock()

    // Serial work queue: ALL credential load / token refresh / usage-fetch logic runs
    // here, so two refreshes can never race on the same refresh token (the loser's
    // whole-blob write-back could clobber the winner's rotated refresh token — worst
    // case logging Claude Code itself out). Also keeps keychain/file I/O off main.
    private let workQueue = DispatchQueue(label: "com.claude.cc-cost-monitor.quota.work")
    // Single-flight state — only touched on workQueue.
    private var fetchInFlight = false
    private var pendingCompletions: [(QuotaFetchResult) -> Void] = []

    // hasOAuthToken probe cache. NSLock-guarded because SwiftUI reads it synchronously.
    private var tokenPresenceCache: (value: Bool, at: Date)?
    private var tokenProbeInFlight = false
    private let tokenPresenceLock = NSLock()
    private static let tokenPresenceTTL: TimeInterval = 60

    // Credential parsing/routing lives in CredentialStore; keychain spawning in KeychainCLI.
    private typealias OAuthCredentials = CredentialStore.OAuthCredentials

    // OAuth refresh endpoint (mirrors Claude Code's own values).
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthScopes =
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let refreshBufferMs: Double = 5 * 60 * 1000  // refresh 5 min before expiry

    /// True if a subscription OAuth token is present. Uses an attributes-only Keychain
    /// lookup (no `-w`), so merely deciding whether to show the Plan tab never triggers a
    /// password prompt — only the actual quota fetch reads the secret.
    ///
    /// SwiftUI reads this from view code, so it must stay synchronous and cheap: the
    /// probe result is cached for 60s. When stale, the cached value is returned
    /// immediately (sticky — no Plan-tab flicker) and re-probed on the work queue, so
    /// the main thread never blocks behind a locked keychain (e.g. right after wake).
    /// Only the very first call probes synchronously, which in the common case happens
    /// at cold start before the popover is even open.
    var hasOAuthToken: Bool {
        tokenPresenceLock.lock()
        if let cached = tokenPresenceCache {
            let isFresh = Date().timeIntervalSince(cached.at) < Self.tokenPresenceTTL
            let shouldProbe = !isFresh && !tokenProbeInFlight
            if shouldProbe { tokenProbeInFlight = true }
            tokenPresenceLock.unlock()
            if shouldProbe {
                workQueue.async { [weak self] in
                    guard let self = self else { return }
                    let value = CredentialStore.probeTokenPresence()
                    self.tokenPresenceLock.lock()
                    self.tokenPresenceCache = (value, Date())
                    self.tokenProbeInFlight = false
                    self.tokenPresenceLock.unlock()
                }
            }
            return cached.value
        }
        tokenPresenceLock.unlock()
        // First-ever call: probe synchronously once so the initial value is correct.
        let value = CredentialStore.probeTokenPresence()
        tokenPresenceLock.lock()
        tokenPresenceCache = (value, Date())
        tokenPresenceLock.unlock()
        return value
    }

    /// Force a synchronous, LIVE token-presence probe, bypassing the 60s sticky
    /// cache, and refresh that cache with the result. For a manual ⌘R so a
    /// just-completed `claude login` / `logout` is reflected on this refresh
    /// instead of up to 60s later. Attributes-only (no `-w`) → never prompts.
    /// Called from the main thread on ⌘R, matching the existing first-ever probe.
    @discardableResult
    func probeTokenPresenceNow() -> Bool {
        let value = CredentialStore.probeTokenPresence()
        tokenPresenceLock.lock()
        tokenPresenceCache = (value, Date())
        tokenPresenceLock.unlock()
        return value
    }

    /// When the currently-cached quota was fetched from the network (nil if never).
    /// Both success paths — a live 200 and a cache-hit — serve `cached.quota`, and
    /// the 200 path stamps `cached = (quota, Date())` before completing, so
    /// `cached.at` is always the true retrieval time of what the UI is showing.
    /// The footer reads this to show the Plan tab's real freshness.
    var lastSuccessAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return cached?.at
    }

    /// When the active 429 cooldown ends, or nil if not rate-limited (or the cooldown
    /// has already elapsed but no fetch has cleared it yet). The Plan tab reads this to
    /// show a concrete "retry in Nm" instead of the vague "retrying soon".
    var rateLimitCooldownUntil: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until = rateLimitedUntil, until > Date() else { return nil }
        return until
    }

    /// Turn a 429 `Retry-After` into an absolute deadline. The header is delta-seconds
    /// (what Anthropic sends, e.g. "3367") or, per RFC 7231, an HTTP-date. Absent or
    /// unparseable → `defaultCooldown` so we ALWAYS back off something. Capped at 1h so
    /// a pathological header can't freeze the quota indefinitely (an early retry just
    /// re-429s and re-arms the cooldown, self-correcting).
    private static func retryDeadline(from http: HTTPURLResponse?,
                                      default defaultCooldown: TimeInterval) -> Date {
        let now = Date()
        let cap: TimeInterval = 3600
        if let raw = http?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let secs = TimeInterval(raw) {
                return now.addingTimeInterval(min(cap, max(0, secs)))
            }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "GMT")
            fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            if let d = fmt.date(from: raw), d > now {
                return min(d, now.addingTimeInterval(cap))
            }
        }
        return now.addingTimeInterval(defaultCooldown)
    }

    // MARK: Token refresh (mirrors openusage / Claude Code's own OAuth refresh)

    private func needsRefresh(_ creds: OAuthCredentials) -> Bool {
        guard let exp = creds.expiresAtMs else { return false }
        return Date().timeIntervalSince1970 * 1000 >= exp - Self.refreshBufferMs
    }

    /// Refresh proactively if the token is expired / expiring; otherwise pass through unchanged.
    private func ensureFreshToken(_ creds: OAuthCredentials,
                                  completion: @escaping (OAuthCredentials) -> Void) {
        guard needsRefresh(creds), creds.refreshToken != nil else { completion(creds); return }
        performRefresh(creds) { completion($0 ?? creds) }
    }

    /// Exchange the refresh token for a new access token and persist it back to its source.
    private func performRefresh(_ creds: OAuthCredentials,
                                completion: @escaping (OAuthCredentials?) -> Void) {
        guard let refresh = creds.refreshToken, !refresh.isEmpty else { completion(nil); return }
        var req = URLRequest(url: Self.refreshURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CCCostMonitor/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.oauthClientID,
            "scope": Self.oauthScopes,
        ])

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self else { completion(nil); return }
            // Hop back onto the serial work queue before touching/persisting credentials,
            // so the write-back can never interleave with other credential work.
            self.workQueue.async {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status), let data = data,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccess = body["access_token"] as? String, !newAccess.isEmpty else {
                    completion(nil)
                    return
                }
                var updated = creds
                updated.accessToken = newAccess
                if let r = body["refresh_token"] as? String, !r.isEmpty { updated.refreshToken = r }
                if let e = body["expires_in"] as? Double {
                    updated.expiresAtMs = Date().timeIntervalSince1970 * 1000 + e * 1000
                }
                CredentialStore.saveCredentials(updated)
                completion(updated)
            }
        }.resume()
    }

    /// Fetch quota. Always returns a `QuotaFetchResult` so callers can differentiate
    /// "no subscription auth" (expected, hide UI) from actual error states (401/429/etc).
    /// Completion is always delivered on the main queue. Concurrent calls (wake + 30-min
    /// timer + ⌘R) are single-flighted: late callers join the in-flight request and all
    /// complete with its result — so performRefresh can never run twice in parallel and
    /// burn the same refresh token twice.
    func fetch(forceRefresh: Bool = false, completion: @escaping (QuotaFetchResult) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if !forceRefresh, let c = self.cached, Date().timeIntervalSince(c.at) < self.ttl {
                let q = c.quota
                self.lock.unlock()
                DispatchQueue.main.async { completion(.success(q)) }
                return
            }
            // Server-imposed 429 cooldown: sit it out WITHOUT a request — even for a
            // forced ⌘R. forceRefresh only bypasses the success cache above (client
            // freshness); re-poking a throttled endpoint returns a fresh full
            // Retry-After and resets the window, which is exactly the death-spiral we
            // are fixing. Re-serve `.rateLimited` so the UI keeps last-known bars + the
            // "retry in Nm" hint.
            if let until = self.rateLimitedUntil, Date() < until {
                self.lock.unlock()
                DispatchQueue.main.async { completion(.rateLimited) }
                return
            }
            self.lock.unlock()

            self.pendingCompletions.append(completion)
            guard !self.fetchInFlight else { return }  // join the in-flight fetch
            self.fetchInFlight = true

            guard let creds = CredentialStore.loadCredentials() else {
                self.finishFetch(.noToken)
                return
            }

            // Refresh proactively when expired/expiring, then fetch usage. requestUsage also
            // force-refreshes once on a 401 in case Claude Code rotated the token out from under us.
            self.ensureFreshToken(creds) { fresh in
                self.requestUsage(fresh, allowRefreshRetry: true) { result in
                    self.finishFetch(result)
                }
            }
        }
    }

    /// Complete the in-flight fetch: fire every waiting completion (on main) with the
    /// same result and let the next fetch start a new flight.
    private func finishFetch(_ result: QuotaFetchResult) {
        workQueue.async {
            let completions = self.pendingCompletions
            self.pendingCompletions = []
            self.fetchInFlight = false
            DispatchQueue.main.async { completions.forEach { $0(result) } }
        }
    }

    private func requestUsage(_ creds: OAuthCredentials, allowRefreshRetry: Bool,
                              completion: @escaping (QuotaFetchResult) -> Void) {
        // Belt-and-suspenders HTTPS assertion. URL is hardcoded `https://` but prevents
        // future edits from accidentally introducing a plaintext URL.
        guard url.scheme == "https" else {
            completion(.networkFailure)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CCCostMonitor/\(appVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self else { return }
            // Hop back onto the serial work queue: the cache write and the 401 retry
            // (which re-enters performRefresh) must not race other credential work.
            self.workQueue.async {
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? -1
                switch status {
                case 200:
                    guard let data = data,
                          let quota = try? JSONDecoder().decode(OAuthUsage.self, from: data)
                    else {
                        completion(.decodeFailure)
                        return
                    }
                    self.lock.lock()
                    self.cached = (quota, Date())
                    self.rateLimitedUntil = nil   // recovered — drop any 429 cooldown
                    self.lock.unlock()
                    completion(.success(quota))
                case 401, 403:
                    if allowRefreshRetry, creds.refreshToken != nil {
                        self.performRefresh(creds) { refreshed in
                            if let r = refreshed {
                                self.requestUsage(r, allowRefreshRetry: false, completion: completion)
                            } else {
                                completion(.unauthorized)
                            }
                        }
                    } else {
                        completion(.unauthorized)
                    }
                case 429:
                    // Arm the cooldown from Retry-After BEFORE completing, so any
                    // fetch that starts right after (or a joined single-flight caller
                    // re-triggering) sees it and short-circuits instead of re-poking.
                    let deadline = Self.retryDeadline(from: http, default: 60)
                    self.lock.lock()
                    self.rateLimitedUntil = deadline
                    self.lock.unlock()
                    completion(.rateLimited)
                default:
                    completion(.networkFailure)
                }
            }
        }.resume()
    }
}
