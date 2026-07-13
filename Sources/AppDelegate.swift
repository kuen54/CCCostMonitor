import Cocoa
import SwiftUI
import Combine
import CoreServices

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store = UsageStore()
    private var refreshTimer: Timer?
    private var cancellable: AnyCancellable?
    // P1-4(b): FSEvents watcher on ~/.claude/projects — push-based refresh so new
    // usage shows up within seconds instead of up to 30 min. The 30-min timer
    // stays as a fallback (cross-midnight repaint with zero file changes still
    // needs it; the fingerprint includes dayKey so that timer tick really scans).
    private var fsEventStream: FSEventStreamRef?
    // Debounce (main thread only — FSEvents callbacks are delivered on the main
    // queue via FSEventStreamSetDispatchQueue): each burst of events reschedules
    // this work item so the refresh fires only after a quiet period.
    private var fsRefreshDebounce: DispatchWorkItem?
    // Main thread only. When the last FSEvents-triggered refresh fired; enforces a
    // minimum gap between FSEvents-driven scans (the trailing debounce alone can't —
    // FSEvents' 5s latency delivers callbacks farther apart than the 3s window during
    // sustained writes, so the work item would fire every cycle and spawn Python ~2s
    // of CPU each time). Timer / wake / ⌘R / popover-open refreshes are unaffected.
    private var lastFSTriggeredRefresh: Date?
    // Menu-bar content is a SwiftUI hosting view inside the status button (so the
    // Claude mark can spin while a session is busy and carry the attention dot — the
    // same behavior as the notch and popover header). `menuBarModel.text` holds the
    // current value string; the status item length tracks the measured content width.
    private let menuBarModel = MenuBarModel(text: "…")
    private var menuBarHostingView: NSView?
    // Latest desired menu-bar value. While the popover is open we defer applying it (a
    // resizing status item makes NSPopover drift left); popoverDidClose flushes it.
    private var latestMenuText = "…"
    // Last measured content width — the status item length. Frozen while the popover
    // is open; restored on close and when switching back to menu-bar mode.
    private var lastMenuBarWidth: CGFloat = 40

    // Notch display mode. When displayMode == .notch the controller owns the notch
    // panel + its whole lifecycle; the displayMode sink below is the SINGLE writer of
    // statusItem.isVisible and the only place the controller is built/torn down.
    private var notchController: NotchController?
    private var displayModeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item. Length is managed manually (updateMenuBarWidth) to track the
        // SwiftUI content's measured width — variableLength can't size to a hosted view.
        statusItem = NSStatusBar.system.statusItem(withLength: lastMenuBarWidth)
        statusItem.autosaveName = "CCCostMonitor"
        // Initial visibility set synchronously to avoid a launch-time flash of the
        // icon in notch mode; the displayMode sink below remains the single owner.
        statusItem.isVisible = (store.displayMode == .menubar)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            // Host [Claude mark + value] in SwiftUI so the mark can spin while a session
            // is busy and carry the attention dot (same view as the notch/popover). The
            // hosting view passes mouse events through to the button so a click still
            // toggles the popover; its measured width drives the status item length.
            let content = MenuBarContentView(
                sessionStore: store.sessionStore,
                model: menuBarModel,
                onWidth: { [weak self] w in self?.updateMenuBarWidth(w) })
            let hosting = PassthroughStatusHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            menuBarHostingView = hosting
        }
        // Popover drift is prevented by freezing the value (and thus the width) while the
        // popover is open (see the value sink + popoverDidClose), not by pinning a width.

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
        // Always shows current month regardless of which month is being viewed.
        // CombineLatest4 is Combine's max arity — the time-tab input is chained
        // on with an extra combineLatest.
        // The .session tab's menu-bar value (count + ▸busy marker) derives from
        // sessionStore, which now lives outside UsageStore — fold a DEDUPED
        // "count|anyBusy" signal into the pipeline so the title refreshes when
        // sessions change, without re-titling on every 2s scan that changed neither.
        let sessionMenuSignal = store.sessionStore.$sessions
            .map { sessions -> String in
                "\(sessions.count)|\(sessions.contains { $0.status == .busy })"
            }
            .removeDuplicates()
        cancellable = Publishers.CombineLatest4(
            store.$currentMonthData, store.$selectedTab, store.$language, store.$subscriptionQuota)
            .combineLatest(store.$timeTodaySeconds)
            .combineLatest(sessionMenuSignal)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined, _ in
                let ((monthData, _, _, _), _) = combined
                guard let self = self, monthData != nil else { return }
                // Single source of truth: store.menuBarValue (shared with the notch
                // idle label) computes the per-tab string. Guard on monthData so a
                // transient nil can never overwrite a good value with "…".
                let value = self.store.menuBarValue
                self.latestMenuText = value
                // Don't resize the status item while the popover is open — a resizing
                // anchor makes NSPopover creep left. popoverDidClose applies the latest.
                if !self.popover.isShown {
                    self.menuBarModel.text = value
                }
            }

        // Load cached data instantly, then refresh in background
        store.loadCacheForCurrentMonth()
        store.refresh()

        // Live session monitor (FSEvents + poll over ~/.claude/sessions). Runs in
        // both menu-bar and notch modes; the poll bumps to active while the
        // popover is on screen (popoverDidShow/Close).
        store.startSessionMonitoring()

        // Auto-refresh every 30 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }

        // FSEvents: refresh shortly after JSONL files actually change (P1-4b)
        startProjectsWatcher()

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

        // Display-mode lifecycle: the SINGLE owner of statusItem visibility and the
        // notch controller. @Published delivers the current value on subscribe, so
        // this sink also performs the initial build for a saved .notch preference.
        displayModeCancellable = store.$displayMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.applyDisplayMode(mode) }
    }

    /// Build or tear down the notch UI and toggle the menu-bar item to match the mode.
    /// Idempotent — safe to call repeatedly with the same value. The one place that
    /// writes statusItem.isVisible while a notch controller may exist.
    private func applyDisplayMode(_ mode: DisplayMode) {
        switch mode {
        case .menubar:
            notchController?.stop()
            notchController = nil
            // Flush any value deferred while in notch mode and restore the width.
            menuBarModel.text = latestMenuText
            statusItem.length = lastMenuBarWidth
            statusItem.isVisible = true
        case .notch:
            statusItem.isVisible = false
            // If the popover happened to be open when switching, close it.
            if popover.isShown { popover.performClose(nil) }
            if notchController == nil {
                let controller = NotchController(store: store, onQuit: {
                    NSApplication.shared.terminate(nil)
                })
                notchController = controller
                controller.start()
            }
        }
    }

    /// The SwiftUI menu-bar content measured a new intrinsic width — size the status
    /// item to it. Frozen while the popover is open (a resizing anchor drifts the
    /// popover left); popoverDidClose restores lastMenuBarWidth. Only the value text
    /// changes width — the spinning mark and the dot never do — so this fires only on
    /// value changes, which are already deferred while the popover is open.
    private func updateMenuBarWidth(_ w: CGFloat) {
        let width = max(20, w)
        lastMenuBarWidth = width
        guard store.displayMode == .menubar, !popover.isShown else { return }
        statusItem.length = width
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

    // NSPopoverDelegate: the title may have changed (data refresh or tab switch) while
    // the popover was open and we deferred it to keep the anchor stable. Apply it now.
    func popoverDidClose(_ notification: Notification) {
        // Apply the value we deferred while open, then restore the width (the value
        // change re-measures asynchronously; set the known width now to avoid a blip).
        menuBarModel.text = latestMenuText
        if store.displayMode == .menubar {
            statusItem.length = lastMenuBarWidth
        }
        store.setSessionMonitorActive(false)
    }

    // Animate the open, but stop animating once shown so per-tab content-height
    // changes resize the popover instantly instead of jittering the rows above.
    func popoverDidShow(_ notification: Notification) {
        popover.animates = false
        store.setSessionMonitorActive(true)
    }

    private func showPopover() {
        // In notch mode there is no status item to anchor to — a relaunch / reopen
        // expands the notch instead of popping the (hidden) menu-bar popover.
        if store.displayMode == .notch {
            notchController?.reveal()
            return
        }
        // Ensure the status item is visible in case macOS hid it in overflow
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.animates = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Non-forced kick: the fingerprint short-circuit makes this nearly
            // free when nothing changed, and catches changes the debounced
            // FSEvents refresh hasn't delivered yet.
            store.refresh()
        }
    }

    // MARK: - FSEvents watcher (P1-4b)

    private func startProjectsWatcher() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        var context = FSEventStreamContext(
            version: 0,
            // passUnretained is safe: AppDelegate lives for the whole app
            // lifetime, and applicationWillTerminate stops + invalidates the
            // stream before the process goes away.
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // Directory-level events suffice (we only need "something changed";
        // FSEvents watches recursively by default — no FileEvents flag needed).
        // latency 5s lets the kernel coalesce write bursts before calling us.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            delegate.scheduleDebouncedRefresh()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,  // seconds of kernel-side coalescing
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return }
        fsEventStream = stream
        // Deliver callbacks on the main queue: scheduleDebouncedRefresh touches
        // main-thread-only state (fsRefreshDebounce) and store.refresh() expects main.
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            // Start failure leaves a dead stream — clean up and fall back to
            // the 30-min timer (which keeps working regardless).
            NSLog("CCCostMonitor: FSEventStreamStart failed; falling back to timer-only refresh")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    /// Main thread only. Trailing 3s debounce + a minimum 120s gap between
    /// FSEvents-triggered refreshes. The debounce alone coalesces only bursts
    /// shorter than FSEvents' 5s coalescing latency; during sustained Claude Code
    /// usage callbacks arrive every ~5s and each would fire a real Python scan.
    /// The 120s floor caps that at ~30 scans/hour; data is at most ~2 min stale
    /// during active use, and the non-forced popover-open refresh still delivers
    /// instant freshness when the user actually looks.
    private func scheduleDebouncedRefresh() {
        fsRefreshDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastFSTriggeredRefresh = Date()
            // Non-forced: FSEvents over-fires (any write under ~/.claude/projects,
            // not just *.jsonl) — the fingerprint short-circuit confirms whether
            // the scan inputs really changed before spawning Python.
            self.store.refresh()
        }
        fsRefreshDebounce = item
        var delay: TimeInterval = 3
        if let last = lastFSTriggeredRefresh {
            delay = max(delay, last.addingTimeInterval(120).timeIntervalSinceNow)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopSessionMonitoring()
        notchController?.stop()
        notchController = nil
        fsRefreshDebounce?.cancel()
        fsRefreshDebounce = nil
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
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
            popover.animates = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring popover window to front
            popover.contentViewController?.view.window?.makeKey()
            // Non-forced kick on open — fingerprint makes it nearly free (see showPopover).
            store.refresh()
        }
    }
}

// MARK: - Menu-bar status-item content (SwiftUI)

/// Holds the current menu-bar value string. AppDelegate is the sole writer (it defers
/// updates while the popover is open); the hosting view re-renders on change.
final class MenuBarModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

/// Reports the intrinsic width of the menu-bar content up to AppDelegate so it can
/// size the (manually-lengthed) status item.
private struct MenuBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

/// The status-item content: the session-aware Claude mark (spins while busy, carries
/// the amber/green attention dot) + the current value. The mark is brand orange
/// (`.ccBrand`) — the SAME single color scheme as the notch and popover header, no
/// per-surface variants. The value text stays `.primary` (adaptive) for menu-bar
/// legibility, mirroring the notch's orange-mark + neutral-value pairing.
struct MenuBarContentView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var model: MenuBarModel
    var onWidth: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            SessionAwareClaudeLogo(sessionStore: sessionStore,
                                   size: 16, color: .ccBrand, dotSize: 5)
            Text(model.text)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundColor(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .fixedSize()
        // Measure the intrinsic (fixedSize) content — NOT the button fill — so
        // resizing the status item to this width can't feed back into the measurement.
        .background(GeometryReader { geo in
            Color.clear.preference(key: MenuBarWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(MenuBarWidthKey.self) { onWidth($0) }
    }
}

/// NSHostingView that lets every mouse event fall through to the status-bar button
/// beneath it, so clicks still toggle the popover (the content is presentational).
final class PassthroughStatusHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
