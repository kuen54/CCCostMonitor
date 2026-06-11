import Cocoa
import SwiftUI
import Combine

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store = UsageStore()
    private var refreshTimer: Timer?
    private var cancellable: AnyCancellable?
    // Latest desired menu-bar title. While the popover is open we defer applying it to
    // the button (a resizing anchor makes NSPopover drift left); popoverDidClose flushes it.
    private var latestMenuTitle = " … "

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
        // Always shows current month regardless of which month is being viewed
        cancellable = Publishers.CombineLatest4(
            store.$currentMonthData, store.$selectedTab, store.$language, store.$subscriptionQuota)
            .receive(on: RunLoop.main)
            .sink { [weak self] monthData, tab, _, quota in
                guard let self = self, let monthData = monthData else { return }
                let title: String
                switch tab {
                case .cost:
                    title = formatCost(monthData.cost)
                case .tokens:
                    title = formatTokensShort(monthData.totalTokens)
                case .subscription:
                    // Show what's LEFT in the 5-hour window — the limit subs hit first.
                    if let q = quota {
                        title = "5h \(max(0, 100 - q.five_hour.displayPercent))%"
                    } else {
                        title = formatCost(monthData.cost)
                    }
                }
                let display = " \(title) "
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
        // Ensure the status item is visible in case macOS hid it in overflow
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.animates = true
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
            popover.animates = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring popover window to front
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
