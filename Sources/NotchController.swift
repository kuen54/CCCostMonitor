import AppKit
import SwiftUI
import Combine

// MARK: - Notch UI (AppKit layer)
//
// The "brain" of the notch display mode: screen/notch geometry, screen resolution
// (a synthetic-notch fallback on non-notch displays, boring.notch style — we do NOT
// fall back to the menu bar here; AppDelegate owns that choice), ONE fixed-footprint
// NSPanel PER display, the screen-change/wake rebuild lifecycle, per-display fullscreen
// behavior, and the global+local mouse monitor that is the SINGLE authority for
// open/close (dwell + grace) and for gating mouse passthrough.
//
// Multi-display: we render a panel on EVERY screen (real notch on a notched display,
// a synthetic top-center pill elsewhere). Each panel owns its own NotchViewModel +
// open/close work items so hovering one screen never opens another. The single mouse
// monitor routes each move to the instance under the cursor.
//
// Fullscreen: each panel joins a private SkyLight space so it CAN ride over fullscreen
// apps, but on a screen running a native-fullscreen app the pill behaves like the menu
// bar — HIDDEN by default (alpha 0), REVEALED (alpha 1) only while the cursor is in the
// top reveal band (the same gesture that slides the menu bar down), then it can be
// hover-expanded as usual. On a normal desktop the idle pill is always visible.
//
// Main-thread only (a plain NSObject, like AppDelegate). macOS 13 safe — no macOS-14
// APIs. Adapted from TheBoredTeam/boring.notch + MacroVisionKit + MrKai77/DynamicNotchKit.

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

    /// Stable per-display UUID string. Survives disconnect/reconnect (unlike NSScreenNumber)
    /// and — crucially — equals the "Display Identifier" key returned by the SkyLight
    /// managed-display-spaces query, so it's the join key for per-screen fullscreen
    /// detection. CGDisplayCreateUUIDFromDisplayID is macOS 10.x — 13-safe.
    var displayUUID: String? {
        guard let id = displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Is this the built-in (laptop) panel? Used to prefer it for the synthetic
    /// fallback and to detect clamshell (no built-in present).
    var isBuiltin: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

// MARK: - Resolved target screen

/// The fully-resolved screen + geometry a single notch panel lives on.
struct NotchScreen {
    let screen: NSScreen
    /// true => drawn on a NON-notch display (synthetic pill).
    let isSynthetic: Bool
    /// Idle hover/hit rect: the real notch rect, or a synthetic top-center rect.
    let notchRect: NSRect
    /// Size of the closed pill the SwiftUI content draws at the top.
    let closedNotchSize: CGSize
}

/// Resolve EVERY connected screen to a NotchScreen: real geometry on a notched display,
/// a synthetic top-center pill everywhere else. We render on all displays (boring.notch's
/// "show on all displays"), so the controller builds one panel per element.
func resolveNotchScreens(syntheticWidth: CGFloat = 200) -> [NotchScreen] {
    NSScreen.screens.map { screen in
        if screen.hasNotch, let rect = screen.notchRect, let size = screen.notchSize {
            return NotchScreen(screen: screen, isSynthetic: false,
                               notchRect: rect, closedNotchSize: size)
        }
        let height = max(24, screen.menubarHeight)
        let rect = NSRect(x: screen.frame.midX - syntheticWidth / 2,
                          y: screen.frame.maxY - height,
                          width: syntheticWidth, height: height)
        return NotchScreen(screen: screen, isSynthetic: true,
                           notchRect: rect,
                           closedNotchSize: CGSize(width: syntheticWidth, height: height))
    }
}

// MARK: - NotchPanel (one canonical window PER display)

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
        // `.fullScreenAuxiliary` + the SkyLight float (enableFullscreenFloat) let the
        // panel ride over native-fullscreen apps; `.canJoinAllSpaces` keeps it on every
        // desktop space. The controller gates ALPHA so in fullscreen the pill only shows
        // while the cursor is in the menu-bar reveal band (see applyPanelState).
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }

    func enableFullscreenFloat() { FullscreenSpace.shared.add(self) }
    func disableFullscreenFloat() { FullscreenSpace.shared.remove(self) }
}

// MARK: - FullscreenSpace (SkyLight private-API helper, graceful)

/// Moves a panel into a dedicated always-on-top SkyLight "space" so it floats over
/// native-fullscreen apps (`.fullScreenAuxiliary` alone is unreliable there). Symbols are
/// resolved with dlopen/dlsym at RUNTIME; if any are missing on a future macOS,
/// `isAvailable == false` and every method is a silent no-op (never crashes — falls back
/// to the collectionBehavior). Mirrors boring.notch's SkyLight path. Combined with the
/// controller's per-display alpha gating, "float over fullscreen" becomes "reveal with
/// the menu bar in fullscreen".
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

// MARK: - FullscreenDetector (SkyLight private-API helper, graceful)

/// Per-display native-fullscreen detector via the private SkyLight space database (the
/// same dylib FullscreenSpace uses). `SLSCopyManagedDisplaySpaces` returns one dictionary
/// PER display; a display's active space is "fullscreen" iff that space carries a
/// `TileLayoutManager` sub-dict — boring.notch / MacroVisionKit's ground-truth test, more
/// robust than the ambiguous CGSSpaceType enum (standalone enum says 1, the managed-
/// display dict's "type" says 4). Symbols are dlsym'd at RUNTIME; if any are missing on a
/// future macOS, `isAvailable == false` and `isFullscreen` returns false — i.e. degrade
/// to "treat as not fullscreen" (the pill keeps floating) rather than crash. macOS 13
/// safe (no macOS-14 APIs; yabai/AeroSpace/boring.notch use these across 13–15).
final class FullscreenDetector {
    static let shared = FullscreenDetector()

    private typealias F_MainConn = @convention(c) () -> Int32
    private typealias F_CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    let isAvailable: Bool
    private let connection: Int32
    private let copySpaces: F_CopySpaces?

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW) else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn = sym("SLSMainConnectionID", F_MainConn.self),
              let copy = sym("SLSCopyManagedDisplaySpaces", F_CopySpaces.self)
                      ?? sym("CGSCopyManagedDisplaySpaces", F_CopySpaces.self)
        else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        connection = mainConn()
        copySpaces = copy
        isAvailable = true
    }

    /// True iff the display with this UUID currently shows a native-fullscreen space.
    /// Degrades to false if the SkyLight query is unavailable or the display isn't found
    /// (e.g. "Displays have separate Spaces" off collapses the enumeration).
    func isFullscreen(displayUUID: String) -> Bool {
        guard isAvailable, let copySpaces = copySpaces,
              let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return false }

        for display in displays {
            guard display["Display Identifier"] as? String == displayUUID else { continue }
            guard let current = display["Current Space"] as? [String: Any],
                  let activeID = current["ManagedSpaceID"] as? Int,
                  let spaces = display["Spaces"] as? [[String: Any]]
            else { return false }
            for space in spaces where (space["ManagedSpaceID"] as? Int) == activeID {
                return space["TileLayoutManager"] != nil
            }
            return false
        }
        return false
    }
}

// MARK: - FirstMouseHostingView

/// NSHostingView that responds to the FIRST click even while its window is non-key. The
/// notch panel is intentionally non-key on hover-open (it never steals keyboard focus from
/// the active app), so without this a click on a control would only key the window and be
/// swallowed — the tabs would feel dead until a second interaction.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - NotchInstance (everything that is per-display)

/// One display's worth of notch state. The controller keeps a registry of these keyed by
/// CGDirectDisplayID. Each owns its own panel + view model + open/close work items, so
/// the displays are fully independent (hovering one never opens another).
final class NotchInstance {
    let vm = NotchViewModel()
    let panel: NotchPanel
    let screen: NotchScreen
    /// Whether this display currently runs a native-fullscreen app (drives the
    /// hide-unless-revealed behavior). Updated on activeSpaceDidChange + rebuild.
    var isFullscreen = false
    var openWork: DispatchWorkItem?
    var closeWork: DispatchWorkItem?
    /// Re-applies mouse gating whenever the measured popover size changes, so the clickable
    /// region tracks the growing popover instead of lagging a frame behind it.
    var sizeObserver: AnyCancellable?

    init(panel: NotchPanel, screen: NotchScreen) {
        self.panel = panel
        self.screen = screen
    }
}

// MARK: - NotchController

/// Owns every panel's whole life. Builds one panel per resolved screen, rebuilds
/// (teardown ALL + recreate) on screen-change / wake, tracks per-display fullscreen, runs
/// the single global+local mouse monitor that opens (dwell) when the cursor enters a notch
/// and closes (grace) when it leaves, and — in one place, applyPanelState — sets each
/// panel's alpha (visible / fullscreen-hidden / revealed) and ignoresMouseEvents.
final class NotchController: NSObject {
    private let store: UsageStore
    private let onQuit: () -> Void

    // ONE fixed-size transparent window PER display (boring.notch approach): never resized
    // for open/close/tab. The SwiftUI content sizes itself inside and the black shape
    // grows; the controller uses each instance's measured visible-black size
    // (inst.vm.contentSize) only for hit-testing (hover-close + mouse passthrough) so they
    // track the black, not the bigger transparent window. Must comfortably exceed the
    // tallest/widest open tab.
    private let maxWindowSize = CGSize(width: 600, height: 860)
    private let syntheticWidth: CGFloat = 200
    /// Idle hover zone = notch width plus a shoulder each side (so hovering the icon /
    /// value, which sit just outside the physical notch, also opens it).
    private let hoverShoulder: CGFloat = 84

    /// One instance per display, keyed by its stable CGDirectDisplayID.
    private var instances: [CGDirectDisplayID: NotchInstance] = [:]

    // Process-wide singletons (genuinely shared across displays).
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rebuildWork: DispatchWorkItem?

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
        // Per-display fullscreen enter/exit (and desktop space switches). Cheap; the
        // visual diff is guarded inside applyPanelState (alpha only changes when needed).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        installMouseMonitor()
        rebuild()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rebuildWork?.cancel(); rebuildWork = nil
        removeMouseMonitor()
        teardownAll()
    }

    /// Debounce the burst of screen-change / wake notifications, then rebuild.
    @objc private func screenParametersChanged() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// A space switched on some display — re-read which screens are fullscreen, then
    /// re-apply visibility (hides the pill on a screen that just went fullscreen, shows it
    /// again on exit).
    @objc private func activeSpaceChanged() {
        refreshFullscreenStates()
        applyPanelState()
    }

    /// ALWAYS teardown ALL + recreate from live NSScreen.screens — never reposition in
    /// place (boring.notch #363 rogue-window bug). Because we rebuild the whole registry
    /// from scratch, a disconnected display's panel simply isn't recreated (no orphan),
    /// and clamshell falls out for free.
    private func rebuild() {
        teardownAll()
        let resolved = resolveNotchScreens(syntheticWidth: syntheticWidth)
        guard !resolved.isEmpty else { return }

        for ns in resolved {
            guard let id = ns.screen.displayID else { continue }
            let frame = panelFrame(for: ns)
            let panel = NotchPanel(contentRect: frame)
            let inst = NotchInstance(panel: panel, screen: ns)
            inst.vm.closedNotchSize = ns.closedNotchSize
            inst.vm.isSynthetic = ns.isSynthetic
            inst.vm.isOpen = false
            inst.isFullscreen = ns.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false

            let host = FirstMouseHostingView(rootView: NotchRootView(store: store, vm: inst.vm, onQuit: onQuit))
            host.translatesAutoresizingMaskIntoConstraints = true
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.setFrame(frame, display: true)

            // Start transparent; applyPanelState fades visible panels in to alpha 1 (and
            // leaves fullscreen-hidden ones at 0). Join the SkyLight float space so the
            // pill can ride over fullscreen apps when revealed.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.enableFullscreenFloat()

            instances[id] = inst

            // The open popover's clickable region is gated to its MEASURED size; that
            // measurement arrives a frame after the popover renders (and grows over the
            // open animation), so re-apply the gating on every size change — otherwise the
            // tabs stay un-clickable until an unrelated mouse event re-runs applyPanelState.
            inst.sizeObserver = inst.vm.$contentSize
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in self?.applyPanelState() }
        }
        applyPanelState()
    }

    private func teardownAll() {
        for inst in instances.values {
            inst.sizeObserver?.cancel(); inst.sizeObserver = nil
            inst.openWork?.cancel()
            inst.closeWork?.cancel()
            inst.panel.disableFullscreenFloat()   // pull out of the float space, not just close
            inst.panel.orderOut(nil)
            inst.panel.close()                      // isReleasedWhenClosed == false → ref stays valid
        }
        instances.removeAll()
        // Nothing is open anymore (mode switch / display rebuild / stop) — let the
        // session monitor fall back to its idle cadence.
        syncSessionMonitorActive()
    }

    /// Top-center placement at the FIXED window size, using `frame` (not visibleFrame)
    /// so the panel extends above the menu bar to overlap the notch. Never resized.
    private func panelFrame(for ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let h = min(maxWindowSize.height, ns.screen.visibleFrame.height - 8)
        let w = min(maxWindowSize.width, f.width)
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    // MARK: Fullscreen state

    private func refreshFullscreenStates() {
        for inst in instances.values {
            inst.isFullscreen = inst.screen.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
        }
    }

    /// The menu-bar reveal band at the very top of a screen (full width). In fullscreen
    /// the pill rides this band, so a hover-to-top brings it back together with the menu bar.
    private func revealRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let band = max(ns.closedNotchSize.height, 24)
        return NSRect(x: f.minX, y: f.maxY - band, width: f.width, height: band)
    }

    // MARK: Open / close (controller is the single authority)

    private func open(_ inst: NotchInstance) {
        guard !inst.vm.isOpen else { return }
        inst.vm.isOpen = true
        // canBecomeKey=true so a CLICK into the popover makes it key (⌘R works after a
        // click); we deliberately do NOT makeKey on hover — that would steal keyboard
        // focus from the active app (caret flicker) on every hover-open. Buttons /
        // NSMenus work without key; open() also refreshes, so ⌘R is rarely needed.
        inst.panel.isInteractive = true
        applyPanelState()
        syncSessionMonitorActive()
        // Fresh-when-you-look, mirroring the NSPopover open kick. Non-forced: the
        // fingerprint short-circuit makes it ~free when nothing changed.
        store.refresh()
        // Phase 6: opening the popover (even straight onto the Session tab) NO LONGER
        // clears the green "finished, unseen" cue. Merely looking can't tell which
        // session finished — so the per-session green dots persist until the user
        // genuinely engages (clicks a session row → store.jumpToSession clears that
        // one), or the reducer auto-evicts it (busy/waiting again, gone).
    }

    private func close(_ inst: NotchInstance) {
        guard inst.vm.isOpen, !inst.vm.preventClose else { return }
        inst.vm.isOpen = false
        inst.panel.isInteractive = false
        // If a click had made the panel key, release it so the active app's window
        // regains key (caret) instead of us holding focus while collapsed.
        if inst.panel.isKeyWindow { inst.panel.resignKey() }
        applyPanelState()
        syncSessionMonitorActive()
    }

    /// Keep the session monitor's FAST poll on whenever ANY display's notch is
    /// expanded — the notch equivalent of the menu-bar popoverDidShow/Close
    /// wiring (without this, notch mode never bumps the monitor off its 6 s idle
    /// cadence, so silent process death takes ~6 s instead of ~2 s to notice).
    /// Reference-counted across displays (open on one screen, closed on another →
    /// stays active) rather than a bare per-instance toggle.
    private func syncSessionMonitorActive() {
        store.setSessionMonitorActive(instances.values.contains { $0.vm.isOpen })
    }

    /// Expand the notch programmatically (AppDelegate's reopen / relaunch path). Targets
    /// the display under the cursor, else the built-in/main, else any.
    func reveal() { if let inst = primaryInstance() { open(inst) } }

    /// Public entry for AppDelegate's reopen/show paths (Spotlight/Finder relaunch).
    func toggle() {
        guard let inst = primaryInstance() else { return }
        inst.vm.isOpen ? close(inst) : open(inst)
    }

    /// The instance under the cursor, else the built-in's, else main's, else any. Used by
    /// the relaunch/reveal path where there is no hover to disambiguate.
    private func primaryInstance() -> NotchInstance? {
        let mouse = NSEvent.mouseLocation
        if let hit = instances.values.first(where: { $0.screen.screen.frame.contains(mouse) }) { return hit }
        if let builtin = instances.values.first(where: { $0.screen.screen.isBuiltin }) { return builtin }
        if let mainID = NSScreen.main?.displayID, let onMain = instances[mainID] { return onMain }
        return instances.values.first
    }

    // MARK: Mouse monitor

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

    /// One handler drives every panel. The instance the cursor left schedules its close;
    /// the one it entered schedules its open. In fullscreen the open path is naturally
    /// gated to the top (hoverRect lives in the reveal band, so the pill is revealed there).
    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let onThisScreen = inst.screen.screen.frame.contains(mouse)
            if inst.vm.isOpen {
                // Close once the cursor leaves the VISIBLE popover (not the bigger window).
                if !onThisScreen || !contentRect(inst).contains(mouse) {
                    scheduleClose(inst)
                } else {
                    cancelClose(inst)
                }
            } else {
                // Open once the cursor dwells inside this notch's hover zone.
                if onThisScreen && hoverRect(inst.screen).contains(mouse) {
                    scheduleOpen(inst)
                } else {
                    cancelOpen(inst)
                }
            }
        }
        applyPanelState()
    }

    private func scheduleOpen(_ inst: NotchInstance) {
        guard inst.openWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self, let inst = inst else { return }
            inst.openWork = nil
            // Re-check the cursor is still in the hover zone before committing.
            if inst.screen.screen.frame.contains(NSEvent.mouseLocation),
               self.hoverRect(inst.screen).contains(NSEvent.mouseLocation) {
                self.open(inst)
            }
        }
        inst.openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.openDwell, execute: work)
    }

    private func cancelOpen(_ inst: NotchInstance) { inst.openWork?.cancel(); inst.openWork = nil }

    private func scheduleClose(_ inst: NotchInstance) {
        guard inst.closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self, let inst = inst else { return }
            inst.closeWork = nil
            // Re-check the cursor is still outside the visible popover (it may have
            // returned during the grace window). close() itself honors keepVisible.
            if !self.contentRect(inst).contains(NSEvent.mouseLocation) {
                self.close(inst)
            }
        }
        inst.closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.closeGrace, execute: work)
    }

    private func cancelClose(_ inst: NotchInstance) { inst.closeWork?.cancel(); inst.closeWork = nil }

    /// The idle hover/hit zone: the notch plus a shoulder each side (a bit wider than
    /// the closed pill so hovering the icon/value opens it). When open, the whole content
    /// rect is the hit zone (handled in handleMouseMoved).
    private func hoverRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let w = ns.closedNotchSize.width + 2 * hoverShoulder
        let h = ns.closedNotchSize.height
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    /// The VISIBLE popover rect in screen coords (top-center, sized to the measured black
    /// content) for this instance. Hover-close + passthrough use this so they track the
    /// popover, not the bigger transparent window. Falls back to the hover zone before the
    /// first measure.
    private func contentRect(_ inst: NotchInstance) -> NSRect {
        let f = inst.screen.screen.frame
        let size = inst.vm.contentSize
        guard size.width > 1, size.height > 1 else { return hoverRect(inst.screen) }
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Visibility + passthrough (single place that touches alpha / ignoresMouseEvents)

    /// For every panel: decide whether it should be visible right now, fade alpha to match,
    /// and gate mouse passthrough to its visible black.
    ///  • Not fullscreen → always visible (the idle pill on the desktop).
    ///  • Fullscreen → visible only while OPEN or while the cursor is in the top reveal
    ///    band (rides the menu bar); otherwise hidden (alpha 0).
    private func applyPanelState() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let visible = !inst.isFullscreen
                || inst.vm.isOpen
                || revealRect(inst.screen).contains(mouse)
            setVisible(inst, visible)
            if !visible {
                inst.panel.ignoresMouseEvents = true
            } else if inst.vm.isOpen {
                inst.panel.ignoresMouseEvents = !contentRect(inst).contains(mouse)
            } else {
                inst.panel.ignoresMouseEvents = !hoverRect(inst.screen).contains(mouse)
            }
        }
    }

    /// Fade a panel to visible/hidden. Guarded so a steady cursor doesn't restart the
    /// animation every mouse move; instant under reduce-motion. This single alpha path
    /// gives the build fade-in (0→1), the fullscreen hide (→0), and the hover reveal (→1).
    private func setVisible(_ inst: NotchInstance, _ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(inst.panel.alphaValue - target) > 0.001 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inst.panel.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                inst.panel.animator().alphaValue = target
            }
        }
    }
}
