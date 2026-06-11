import Cocoa

// ╔══════════════════════════════════════════════════════════════╗
// ║  CC Cost Monitor — macOS Menu Bar App                       ║
// ║  Reads Claude Code session data, shows cost in menu bar     ║
// ╚══════════════════════════════════════════════════════════════╝

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
