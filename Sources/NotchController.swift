import AppKit
import SwiftUI

// MARK: - Notch UI (AppKit layer)
//
// The "brain" of the notch display mode: screen/notch geometry, screen resolution
// with a synthetic-notch fallback (we render on non-notch displays, boring.notch
// style — we do NOT fall back to the menu bar here; AppDelegate owns that choice),
// the single fixed-footprint NSPanel, the screen-change/wake rebuild lifecycle, the
// SkyLight fullscreen float, and the global+local mouse monitor that is the SINGLE
// authority for open/close (dwell + grace) and for gating mouse passthrough.
//
// Main-thread only (a plain NSObject, like AppDelegate). macOS 13 safe — no macOS-14
// APIs. Adapted from TheBoredTeam/boring.notch + MrKai77/DynamicNotchKit.

// MARK: - NSScreen geometry

extension NSScreen {
    /// True only on a REAL notched display (both the top safe-area inset and the two
    /// auxiliary top areas resolve). boring.notch uses safeAreaInsets.top>0;
    /// DynamicNotchKit uses the auxiliary areas — requiring both is strictly safer.
    var hasNotch: Bool {
        safeAreaInsets.top > 0
            && auxiliaryTopLeftArea != nil
            && auxiliaryTopRightArea != nil
    }

    /// Physical notch size (points), or nil on a non-notched display.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea?.width,
              let right = auxiliaryTopRightArea?.width
        else { return nil }
        return CGSize(width: frame.width - left - right, height: safeAreaInsets.top)
    }

    /// Menu-bar height = full frame top minus the visible (menu-bar-excluded) top.
    var menubarHeight: CGFloat { frame.maxY - visibleFrame.maxY }

    /// Physical notch rect in GLOBAL (bottom-left origin) coordinates, centered and
    /// flush to the very top. nil on non-notch displays.
    var notchRect: NSRect? {
        guard let size = notchSize else { return nil }
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    var displayID: CGDirectDisplayID? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(n.uint32Value)
    }

    /// Is this the built-in (laptop) panel? Used to prefer it for the synthetic
    /// fallback and to detect clamshell (no built-in present).
    var isBuiltin: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

// MARK: - Resolved target screen

/// The fully-resolved screen + geometry the notch UI lives on for this configuration.
struct NotchScreen {
    let screen: NSScreen
    /// true => drawn on a NON-notch display (synthetic pill).
    let isSynthetic: Bool
    /// Idle hover/hit rect: the real notch rect, or a synthetic top-center rect.
    let notchRect: NSRect
    /// Size of the closed pill the SwiftUI content draws at the top.
    let closedNotchSize: CGSize
}

/// Pick the screen the notch UI lives on: a real notched screen if any, else a
/// SYNTHETIC top-center pill on the built-in screen (then NSScreen.main, then the
/// first screen for clamshell). We render on non-notch displays like boring.notch.
func resolveNotchScreen(syntheticWidth: CGFloat = 200) -> NotchScreen? {
    if let notched = NSScreen.screens.first(where: { $0.hasNotch }),
       let rect = notched.notchRect, let size = notched.notchSize {
        return NotchScreen(screen: notched, isSynthetic: false,
                           notchRect: rect, closedNotchSize: size)
    }
    guard let screen = NSScreen.screens.first(where: { $0.isBuiltin })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    else { return nil }

    let height = max(24, screen.menubarHeight)
    let rect = NSRect(x: screen.frame.midX - syntheticWidth / 2,
                      y: screen.frame.maxY - height,
                      width: syntheticWidth, height: height)
    return NotchScreen(screen: screen, isSynthetic: true,
                       notchRect: rect,
                       closedNotchSize: CGSize(width: syntheticWidth, height: height))
}

// MARK: - NotchPanel (the one canonical window)

/// Borderless, non-activating, clear floating panel pinned above the menu bar so it
/// can overlap the physical notch. Config is boring.notch's, with `isInteractive`
/// gating `canBecomeKey` so the EXPANDED popover (⌘R, the 🌐/⋯ NSMenus, quit) can take
/// key focus, while `.nonactivatingPanel` keeps it from activating our app / stealing
/// the front app's menu bar.
final class NotchPanel: NSPanel {
    /// Drives canBecomeKey. false for the idle pill (a stray click never grabs the
    /// keyboard); true while expanded so PopoverView's controls receive key events.
    var isInteractive = false

    static let notchStyleMask: NSWindow.StyleMask =
        [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]

    convenience init(contentRect: NSRect) {
        self.init(contentRect: contentRect, styleMask: NotchPanel.notchStyleMask,
                  backing: .buffered, defer: false)
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask,
                   backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        // So a key panel keeps receiving mouseMoved (the local monitor tracks the
        // cursor leaving an OPEN panel).
        acceptsMouseMovedEvents = true
        // Force dark regardless of system Appearance → the hosted SwiftUI resolves
        // colorScheme == .dark, so PopoverView is forced dark for free.
        appearance = NSAppearance(named: .darkAqua)
        // ABOVE the menu bar AND its system extras (clock / Control Center / 3rd-party
        // status items). .mainMenu+3 sits BELOW the extras, so the right-shoulder value
        // got covered by them; .screenSaver (what DynamicNotchKit uses) is above the
        // whole menu bar so our content always shows on top.
        level = .screenSaver
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }

    func positionAtTopCenter(of screen: NSScreen) {
        let f = screen.frame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height))
    }

    func enableFullscreenFloat() { FullscreenSpace.shared.add(self) }
    func disableFullscreenFloat() { FullscreenSpace.shared.remove(self) }
}

// MARK: - FullscreenSpace (SkyLight private-API helper, graceful)

/// Moves the panel into a dedicated always-on-top SkyLight "space" so it floats over
/// native-fullscreen apps (`.canJoinAllSpaces` alone is unreliable there). Symbols are
/// resolved with dlopen/dlsym at RUNTIME; if any are missing on a future macOS,
/// `isAvailable == false` and every method is a silent no-op (never crashes — falls
/// back to the collectionBehavior). Mirrors boring.notch's SkyLight path.
final class FullscreenSpace {
    static let shared = FullscreenSpace()

    private typealias F_MainConn = @convention(c) () -> Int32
    private typealias F_SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_AddRemove = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias F_RemoveFrom = @convention(c) (Int32, CFArray, CFArray) -> Int32

    let isAvailable: Bool
    private let connection: Int32
    private let space: Int32
    private let addRemove: F_AddRemove?
    private let removeFrom: F_RemoveFrom?
    private static let absoluteLevel: Int32 = Int32.max

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW) else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn = sym("SLSMainConnectionID", F_MainConn.self),
              let create = sym("SLSSpaceCreate", F_SpaceCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", F_SetLevel.self),
              let show = sym("SLSShowSpaces", F_ShowSpaces.self),
              let addRem = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", F_AddRemove.self),
              let remFrom = sym("SLSRemoveWindowsFromSpaces", F_RemoveFrom.self)
        else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        let conn = mainConn()
        let sid = create(conn, 1, 0)
        _ = setLevel(conn, sid, FullscreenSpace.absoluteLevel)
        _ = show(conn, [sid] as CFArray)
        connection = conn; space = sid; addRemove = addRem; removeFrom = remFrom; isAvailable = true
    }

    func add(_ window: NSWindow) {
        guard isAvailable, let addRemove = addRemove else { return }
        _ = addRemove(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func remove(_ window: NSWindow) {
        guard isAvailable, let removeFrom = removeFrom else { return }
        _ = removeFrom(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}

// MARK: - NotchController

/// Owns the panel's whole life. Builds it on the resolved screen, rebuilds (teardown +
/// recreate) on screen-change / wake, runs the global+local mouse monitor that opens
/// (dwell) when the cursor enters the notch and closes (grace) when it leaves, and
/// gates `ignoresMouseEvents` so the idle pill is hittable only over the notch while
/// everything else passes through.
final class NotchController: NSObject {
    private let store: UsageStore
    private let onQuit: () -> Void
    let vm = NotchViewModel()

    // ONE fixed-size transparent window (boring.notch approach): never resized for
    // open/close/tab. The SwiftUI content sizes itself inside and the black shape grows;
    // the controller uses the measured visible-black size (vm.contentSize) only for
    // hit-testing (hover-close + mouse passthrough) so they track the black, not the
    // bigger transparent window. Must comfortably exceed the tallest/widest open tab.
    private let maxWindowSize = CGSize(width: 600, height: 860)
    private let syntheticWidth: CGFloat = 200
    /// Idle hover zone = notch width plus a shoulder each side (so hovering the icon /
    /// value, which sit just outside the physical notch, also opens it).
    private let hoverShoulder: CGFloat = 84

    private var panel: NotchPanel?
    private var current: NotchScreen?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    init(store: UsageStore, onQuit: @escaping () -> Void) {
        self.store = store
        self.onQuit = onQuit
        super.init()
    }

    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
        installMouseMonitor()
        rebuild(animated: true)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rebuildWork?.cancel(); rebuildWork = nil
        openWork?.cancel(); openWork = nil
        closeWork?.cancel(); closeWork = nil
        removeMouseMonitor()
        teardownPanel()
    }

    /// Debounce the burst of screen-change / wake notifications, then rebuild.
    @objc private func screenParametersChanged() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(animated: false) }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// ALWAYS teardown + recreate re-resolving the screen — never reposition in place
    /// (boring.notch #363 rogue-window bug). Clamshell falls out for free: the resolver
    /// moves to the external display as a synthetic notch and snaps back on lid reopen.
    private func rebuild(animated: Bool) {
        teardownPanel()
        guard let resolved = resolveNotchScreen(syntheticWidth: syntheticWidth) else { return }
        current = resolved

        vm.closedNotchSize = resolved.closedNotchSize
        vm.isSynthetic = resolved.isSynthetic
        vm.isOpen = false

        let frame = panelFrame(for: resolved)
        let panel = NotchPanel(contentRect: frame)
        let host = NSHostingView(rootView: NotchRootView(store: store, vm: vm, onQuit: onQuit))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(frame, display: true)
        self.panel = panel

        // Alpha fade is ONLY for build/teardown — the idle pill is a persistent alpha=1
        // panel; hover-expand never touches alphaValue.
        if animated {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        panel.enableFullscreenFloat()
        applyInteractivity()
    }

    private func teardownPanel() {
        panel?.disableFullscreenFloat()
        panel?.orderOut(nil)
        panel?.close()          // isReleasedWhenClosed == false → ref stays valid
        panel = nil
        current = nil
    }

    /// Top-center placement at the FIXED window size, using `frame` (not visibleFrame)
    /// so the panel extends above the menu bar to overlap the notch. Never resized.
    private func panelFrame(for ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let h = min(maxWindowSize.height, ns.screen.visibleFrame.height - 8)
        let w = min(maxWindowSize.width, f.width)
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    // MARK: Open / close (controller is the single authority)

    private func open() {
        guard !vm.isOpen, let panel = panel else { return }
        vm.isOpen = true
        // canBecomeKey=true so a CLICK into the popover makes it key (⌘R works after a
        // click); we deliberately do NOT makeKey on hover — that would steal keyboard
        // focus from the active app (caret flicker) on every hover-open. Buttons /
        // NSMenus work without key; open() also refreshes, so ⌘R is rarely needed.
        panel.isInteractive = true
        applyInteractivity()
        // Fresh-when-you-look, mirroring the NSPopover open kick. Non-forced: the
        // fingerprint short-circuit makes it ~free when nothing changed.
        store.refresh()
    }

    /// Expand the notch programmatically (AppDelegate's reopen / relaunch path).
    func reveal() { open() }

    private func close() {
        guard vm.isOpen, !vm.preventClose, let panel = panel else { return }
        vm.isOpen = false
        panel.isInteractive = false
        // If a click had made the panel key, release it so the active app's window
        // regains key (caret) instead of us holding focus while collapsed.
        if panel.isKeyWindow { panel.resignKey() }
        applyInteractivity()
    }

    /// Public entry for AppDelegate's reopen/show paths (Spotlight/Finder relaunch).
    func toggle() { vm.isOpen ? close() : scheduleOpenImmediate() }
    private func scheduleOpenImmediate() { open() }

    // MARK: Mouse monitor + interactive gating

    private func installMouseMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in self?.handleMouseMoved()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in self?.handleMouseMoved(); return event
        }
    }

    private func removeMouseMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func handleMouseMoved() {
        guard let ns = current else { return }
        let mouse = NSEvent.mouseLocation
        let onOurScreen = ns.screen.frame.contains(mouse)

        if vm.isOpen {
            // Close once the cursor leaves the VISIBLE popover (not the bigger window).
            if !onOurScreen || !contentRect(ns).contains(mouse) {
                scheduleClose()
            } else {
                cancelClose()
            }
        } else {
            // Open once the cursor dwells inside the notch hover zone.
            if onOurScreen && hoverRect(ns).contains(mouse) {
                scheduleOpen()
            } else {
                cancelOpen()
            }
        }
        applyInteractivity()
    }

    private func scheduleOpen() {
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let ns = self.current else { return }
            self.openWork = nil
            // Re-check the cursor is still in the hover zone before committing.
            if ns.screen.frame.contains(NSEvent.mouseLocation),
               self.hoverRect(ns).contains(NSEvent.mouseLocation) {
                self.open()
            }
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.openDwell, execute: work)
    }

    private func cancelOpen() { openWork?.cancel(); openWork = nil }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let ns = self.current else { return }
            self.closeWork = nil
            // Re-check the cursor is still outside the visible popover (it may have
            // returned during the grace window). close() itself honors keepVisible.
            if !self.contentRect(ns).contains(NSEvent.mouseLocation) {
                self.close()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.closeGrace, execute: work)
    }

    private func cancelClose() { closeWork?.cancel(); closeWork = nil }

    /// The idle hover/hit zone: the notch plus a shoulder each side (a bit wider than
    /// the closed pill so hovering the icon/value opens it). When open, the whole panel
    /// frame is the hit zone (handled in handleMouseMoved).
    private func hoverRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let w = ns.closedNotchSize.width + 2 * hoverShoulder
        let h = ns.closedNotchSize.height
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    /// The VISIBLE popover rect in screen coords (top-center, sized to the measured black
    /// content). Hover-close + passthrough use this so they track the popover, not the
    /// bigger transparent window. Falls back to the hover zone before the first measure.
    private func contentRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let size = vm.contentSize
        guard size.width > 1, size.height > 1 else { return hoverRect(ns) }
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Passthrough via the panel's all-or-nothing ignoresMouseEvents, gated to the
    /// VISIBLE black so the big transparent window never blocks clicks:
    ///  • OPEN → interactive only over the popover rect; clicks outside it pass through
    ///           (menu-bar extras / apps below stay usable; click-outside closes).
    ///  • IDLE → interactive only over the notch hover zone; everything else passes
    ///           through. Hover-to-open is detected by the global monitor regardless.
    private func applyInteractivity() {
        guard let panel = panel, let ns = current else { return }
        let mouse = NSEvent.mouseLocation
        if vm.isOpen {
            panel.ignoresMouseEvents = !contentRect(ns).contains(mouse)
        } else {
            panel.ignoresMouseEvents = !hoverRect(ns).contains(mouse)
        }
    }
}
