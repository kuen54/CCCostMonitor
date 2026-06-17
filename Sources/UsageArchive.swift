import Foundation

// MARK: - Local usage archive — app-side file store (month-sharded)
//
// File-backed home for the durable usage archive. Deliberately lives OUTSIDE
// ~/.claude (under ~/Library/Application Support/CCCostMonitor/archive/) so
// Claude Code's startup cleanup — which prunes ~/.claude/projects and sweeps
// ~/.claude/cache — can never delete the very history we're preserving. The
// pure monotonic merge / read transforms live in Core_UsageArchive.swift
// (CCCostCore, unit-tested); this type owns only file I/O and thread-safety.
//
// Sharding: one JSON file per month (`archive/YYYY-MM.json`), each a
// UsageArchiveData holding that month's days. The whole archive is small (daily
// aggregates ≈ KB/day) but sharding keeps WRITES incremental — a merge rewrites
// only the month shards it actually changed (steady state: just the current
// month, ~tens of KB), never re-serializing years of stable history. All shards
// are read once at launch into one in-memory dict; reads/overlays operate on
// that.
//
// Threading: `data` is guarded by `lock`. Merges (scriptQueue / main) and reads
// (main) take the lock briefly; encode+write happens on `ioQueue` against a
// per-month snapshot, so disk writes never block a caller. The combined
// `overlay(...)` merges + reads under ONE lock so a concurrent sweep can't
// interleave between a write and the paired reads.
final class UsageArchive {
    private let lock = NSLock()
    private var data: UsageArchiveData
    private let shardDir: URL
    private let ioQueue = DispatchQueue(label: "com.claude.cc-cost-monitor.archive-io", qos: .utility)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support"))
        let appDir = base.appendingPathComponent("CCCostMonitor", isDirectory: true)
        shardDir = appDir.appendingPathComponent("archive", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        } catch {
            // Should never happen in Application Support; if it does, every
            // persist() below will no-op — surface it rather than lose data silently.
            NSLog("CCCostMonitor: failed to create archive dir %@: %@",
                  shardDir.path, error.localizedDescription)
        }

        var loaded = UsageArchiveData()
        if let files = try? FileManager.default.contentsOfDirectory(
            at: shardDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let raw = try? Data(contentsOf: file),
                      let shard = try? JSONDecoder().decode(UsageArchiveData.self, from: raw) else { continue }
                // Forward-compat: never merge a shard written by a newer schema
                // we don't understand (its fields could mean something else).
                guard shard.schemaVersion <= UsageArchiveData.currentSchema else {
                    NSLog("CCCostMonitor: skipping archive shard %@ (schema %d > %d)",
                          file.lastPathComponent, shard.schemaVersion, UsageArchiveData.currentSchema)
                    continue
                }
                loaded.days.merge(shard.days) { a, _ in a }
            }
        }
        data = loaded
    }

    // MARK: Status (for UI)

    var dayCount: Int {
        lock.lock(); defer { lock.unlock() }
        return data.days.count
    }

    // MARK: Merges (monotonic — never lower stored values)

    func mergeDaily(_ daily: [DailyUsage]?) {
        lock.lock()
        let changed = UsageArchiveLogic.mergeDaily(daily, into: &data)
        lock.unlock()
        persist(changedDays: changed)
    }

    func mergeTime(_ time: TimeData?) {
        lock.lock()
        let changed = UsageArchiveLogic.mergeTime(time, into: &data)
        lock.unlock()
        persist(changedDays: changed)
    }

    func mergeYearSeconds(_ days: [String: Int]) {
        lock.lock()
        let changed = UsageArchiveLogic.mergeYearSeconds(days, into: &data)
        lock.unlock()
        persist(changedDays: changed)
    }

    /// Merge an entire scan's daily + time payload in one shot (the sweep),
    /// rewriting only the months that changed.
    func merge(daily: [DailyUsage]?, time: TimeData?) {
        lock.lock()
        var changed = UsageArchiveLogic.mergeDaily(daily, into: &data)
        changed.formUnion(UsageArchiveLogic.mergeTime(time, into: &data))
        lock.unlock()
        persist(changedDays: changed)
    }

    /// Atomically merge a scan's daily + time into the archive AND read back the
    /// month's overlay (daily + time days) under a SINGLE lock — so a concurrent
    /// merge (e.g. the background sweep) can't interleave between the write and
    /// the paired reads and hand the caller a mismatched daily/time snapshot.
    func overlay(mergingDaily daily: [DailyUsage]?, time: TimeData?, yearMonth: String)
        -> (daily: [DailyUsage], timeDays: [String: DayTimeUsage]) {
        lock.lock()
        var changed = UsageArchiveLogic.mergeDaily(daily, into: &data)
        changed.formUnion(UsageArchiveLogic.mergeTime(time, into: &data))
        let d = UsageArchiveLogic.dailyBreakdown(data, yearMonth: yearMonth)
        let t = UsageArchiveLogic.timeDays(data, yearMonth: yearMonth)
        lock.unlock()
        persist(changedDays: changed)
        return (d, t)
    }

    // MARK: Reads (overlay sources)

    func dailyBreakdown(yearMonth: String) -> [DailyUsage] {
        lock.lock(); defer { lock.unlock() }
        return UsageArchiveLogic.dailyBreakdown(data, yearMonth: yearMonth)
    }

    func timeDays(yearMonth: String) -> [String: DayTimeUsage] {
        lock.lock(); defer { lock.unlock() }
        return UsageArchiveLogic.timeDays(data, yearMonth: yearMonth)
    }

    func yearSeconds(year: Int) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return UsageArchiveLogic.yearSeconds(data, year: year)
    }

    // MARK: Destructive

    /// Wipe the archive (all shard files + memory). The explicit "Clear archive"
    /// action.
    func clear() {
        lock.lock()
        data = UsageArchiveData()
        lock.unlock()
        ioQueue.async { [shardDir] in
            if let files = try? FileManager.default.contentsOfDirectory(
                at: shardDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    // MARK: Persistence (incremental — only changed months)

    /// Rewrite exactly the month shards touched by `changedDays`. A month that
    /// emptied out (after a clear) has its file removed. No-op when nothing
    /// changed, so a monotonic no-merge never hits the disk.
    private func persist(changedDays: Set<String>) {
        guard !changedDays.isEmpty else { return }
        let months = Set(changedDays.map { String($0.prefix(7)) })  // "yyyy-MM"
        lock.lock()
        let shards: [(month: String, data: UsageArchiveData)] = months.map { m in
            (m, UsageArchiveData(days: data.days.filter { $0.key.hasPrefix(m) }))
        }
        lock.unlock()
        ioQueue.async { [shardDir] in
            for shard in shards {
                let url = shardDir.appendingPathComponent("\(shard.month).json")
                if shard.data.days.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else if let encoded = try? JSONEncoder().encode(shard.data) {
                    try? encoded.write(to: url, options: .atomic)
                }
            }
        }
    }
}
