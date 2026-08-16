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
// bar — HIDDEN by default (alpha 0), REVEALED (alpha 1) only AFTER the cursor pushes the
// very top edge (the gesture that slides the menu bar down) and while it then stays in
// the menu-bar band, at which point it can be hover-expanded as usual. Merely entering
// the band is NOT enough: a fullscreen window owns that band (a browser's tab strip lives
// exactly there), so reacting to it would reveal + expand over content the user is
// aiming at. On a normal desktop the idle pill is always visible and always hoverable.
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
    /// FULLSCREEN ONLY: has the cursor performed the menu-bar summon gesture (touched the
    /// very top edge) and not yet left the menu-bar band? Gates both the pill's reveal and
    /// its hover-expand there, so a fullscreen window's own top chrome (browser tabs) stays
    /// reachable. Always false / ignored on a normal desktop, where the pill is visible and
    /// hovering it must open it. Reset whenever the display's fullscreen state flips.
    var revealArmed = false
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
    /// Thickness of the hot edge at the very top of a fullscreen screen. Touching it is
    /// the same push that slides the system menu bar down, and it is what ARMS the pill
    /// there. Deliberately a thin strip — NOT the whole menu-bar band — because in
    /// fullscreen the band belongs to the app: on a non-notched display the window covers
    /// the screen outright, so a browser's tab strip sits in it (measured: 30pt band, tabs
    /// ~40pt tall → aiming at a tab lands ~20pt down, nowhere near this strip). Thin enough
    /// to never catch a tab, thick enough to be an easy landing strip for a deliberate shove
    /// (the cursor DOES reach frame.maxY exactly, but overshooting onto a display stacked
    /// above must not be the only way to arm).
    private let revealEdge: CGFloat = 8

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

            let host = FirstMouseHostingView(rootView: NotchRootView(store: store, sessionStore: store.sessionStore, vm: inst.vm, onQuit: onQuit))
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
            let wasFullscreen = inst.isFullscreen
            inst.isFullscreen = inst.screen.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            // Entering/leaving fullscreen with the cursor parked anywhere must not inherit
            // a stale arm — a screen that just went fullscreen starts hidden until the user
            // performs the summon gesture again.
            if inst.isFullscreen != wasFullscreen { inst.revealArmed = false }
        }
    }

    /// The menu-bar reveal band at the very top of a screen (full width). In fullscreen
    /// the pill rides this band, so once armed it stays revealed with the menu bar for as
    /// long as the cursor is in it.
    private func revealRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let band = max(ns.closedNotchSize.height, 24)
        return NSRect(x: f.minX, y: f.maxY - band, width: f.width, height: band)
    }

    /// The hot edge at the very top of a screen (full width, `revealEdge` thick).
    private func edgeRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        return NSRect(x: f.minX, y: f.maxY - revealEdge, width: f.width, height: revealEdge)
    }

    /// Mouse hit-test that counts a rect's TOP edge as inside — AppKit's unflipped
    /// `NSMouseInRect` convention (`minY < y <= maxY`), NOT `NSRect.contains`, which is
    /// half-open at maxY. This is load-bearing here: every rect in this file is flush to a
    /// screen's `frame.maxY`, and a pointer shoved against the top of a display reports
    /// EXACTLY `frame.maxY` (measured: warping to the top row of either display yields
    /// `NSEvent.mouseLocation.y == frame.maxY`). `.contains` would therefore exclude the one
    /// position the menu-bar summon gesture actually produces — and would also drop the
    /// screen itself, since the same off-by-one makes `frame.contains` false up there.
    /// Bottom edges stay exclusive, so stacked displays never both claim a shared row.
    private func hit(_ p: NSPoint, _ r: NSRect) -> Bool { NSMouseInRect(p, r, false) }

    /// Mirror the system menu bar's fullscreen behavior for this display: ARM on the top-edge
    /// push, stay armed while the cursor lingers in the menu-bar band (so the user can slide
    /// sideways onto the pill), disarm once it drops out of the band on this screen. Only
    /// meaningful in fullscreen — on a normal desktop the pill is always visible and always
    /// hoverable, so the arm is cleared and never consulted.
    private func updateRevealArm(_ inst: NotchInstance, mouse: NSPoint, onThisScreen: Bool) {
        guard inst.isFullscreen else { inst.revealArmed = false; return }
        if hit(mouse, edgeRect(inst.screen)) {
            inst.revealArmed = true
        } else if onThisScreen, !inst.vm.isOpen, !hit(mouse, revealRect(inst.screen)) {
            // Dropped out of the menu-bar band → the menu bar slides back up, so do we.
            // Never disarm while the popover is up: the cursor is legitimately below the
            // band then, and re-collapsing to a HIDDEN pill mid-use would flicker.
            inst.revealArmed = false
        }
        // Two cases deliberately KEEP the current arm:
        //  • inside the band but off the edge — sticky, exactly like the menu bar, so the
        //    user can slide sideways from the edge onto the pill;
        //  • cursor on another display — a display stacked directly above this one means
        //    the top edge is a crossing, not a clamp, so a shove that overshoots onto the
        //    neighbour must not throw away the arm it just earned. Holding it is harmless:
        //    both the reveal and the hover-open ALSO require the cursor to be back in this
        //    screen's band, which no off-screen position satisfies.
    }

    /// May a hover in the idle hover zone expand this panel right now? Always on a normal
    /// desktop; in fullscreen only once the menu bar has been summoned — otherwise every
    /// trip to a fullscreen window's top chrome would pop the popover open on top of it.
    private func hoverCanOpen(_ inst: NotchInstance) -> Bool {
        !inst.isFullscreen || inst.revealArmed
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
        // genuinely engages (clicks a session row → sessionStore.jump clears that
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
        if let under = instances.values.first(where: { hit(mouse, $0.screen.screen.frame) }) { return under }
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
    /// the one it entered schedules its open. In fullscreen both the reveal and the open
    /// additionally require the menu-bar summon gesture (see updateRevealArm), so crossing
    /// a fullscreen window's top chrome does nothing.
    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let onThisScreen = hit(mouse, inst.screen.screen.frame)
            updateRevealArm(inst, mouse: mouse, onThisScreen: onThisScreen)
            if inst.vm.isOpen {
                // Close once the cursor leaves the VISIBLE popover (not the bigger window).
                if !onThisScreen || !hit(mouse, contentRect(inst)) {
                    scheduleClose(inst)
                } else {
                    cancelClose(inst)
                }
            } else {
                // Open once the cursor dwells inside this notch's hover zone.
                if onThisScreen && hit(mouse, hoverRect(inst.screen)) && hoverCanOpen(inst) {
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
            // Re-check the cursor is still in the hover zone — and, in fullscreen, that the
            // menu bar is still summoned — before committing.
            let mouse = NSEvent.mouseLocation
            if self.hit(mouse, inst.screen.screen.frame),
               self.hit(mouse, self.hoverRect(inst.screen)),
               self.hoverCanOpen(inst) {
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
            if !self.hit(NSEvent.mouseLocation, self.contentRect(inst)) {
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
    ///  • Fullscreen → visible only while OPEN, or while the menu bar has been summoned
    ///    (armed) AND the cursor is still in the top reveal band; otherwise hidden (alpha 0).
    private func applyPanelState() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let visible = !inst.isFullscreen
                || inst.vm.isOpen
                || (inst.revealArmed && hit(mouse, revealRect(inst.screen)))
            setVisible(inst, visible)
            if !visible {
                inst.panel.ignoresMouseEvents = true
            } else if inst.vm.isOpen {
                inst.panel.ignoresMouseEvents = !hit(mouse, contentRect(inst))
            } else {
                inst.panel.ignoresMouseEvents = !hit(mouse, hoverRect(inst.screen))
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
