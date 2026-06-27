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
    // Latest desired menu-bar title. While the popover is open we defer applying it to
    // the button (a resizing anchor makes NSPopover drift left); popoverDidClose flushes it.
    private var latestMenuTitle = " … "

    // Notch display mode. When displayMode == .notch the controller owns the notch
    // panel + its whole lifecycle; the displayMode sink below is the SINGLE writer of
    // statusItem.isVisible and the only place the controller is built/torn down.
    private var notchController: NotchController?
    private var displayModeCancellable: AnyCancellable?

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

        // Official Claude logo SVG path data (from SimpleIcons, CC0 licensed) —
        // command list lives in ClaudeLogo.swift (shared with the popover header
        // and the app-icon generator). Built in SVG space, flipped by `transform`.
        let path = ClaudeLogo.nsBezierPath { x, y in NSPoint(x: x, y: y) }

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
        // Initial visibility set synchronously to avoid a launch-time flash of the
        // icon in notch mode; the displayMode sink below remains the single owner.
        statusItem.isVisible = (store.displayMode == .menubar)
        if let button = statusItem.button {
            button.image = makeClaudeIcon()
            button.imagePosition = .imageLeft
            button.title = " … "
            button.action = #selector(togglePopover)
            button.target = self
        }
        // Status item stays variableLength (sizes to content — the idiomatic menu-bar
        // behavior). Popover drift is prevented by freezing the title while the popover
        // is open (see the title sink + popoverDidClose), not by pinning the width.

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
        cancellable = Publishers.CombineLatest4(
            store.$currentMonthData, store.$selectedTab, store.$language, store.$subscriptionQuota)
            .combineLatest(store.$timeTodaySeconds)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined, _ in
                let (monthData, _, _, _) = combined
                guard let self = self, monthData != nil else { return }
                // Single source of truth: store.menuBarValue (shared with the notch
                // idle label) computes the per-tab string. Guard on monthData so a
                // transient nil can never overwrite a good title with "…".
                let display = " \(self.store.menuBarValue) "
                self.latestMenuTitle = display
                // Don't resize the status button while the popover is open — a resizing
                // anchor makes NSPopover creep left. popoverDidClose applies the latest.
                if !self.popover.isShown {
                    self.statusItem.button?.title = display
                }
            }

        // Load cached data instantly, then refresh in background
        store.loadCacheForCurrentMonth()
        store.refresh()

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
        statusItem.button?.title = latestMenuTitle
    }

    // Animate the open, but stop animating once shown so per-tab content-height
    // changes resize the popover instantly instead of jittering the rows above.
    func popoverDidShow(_ notification: Notification) {
        popover.animates = false
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
