import SwiftUI
import AppKit

// MARK: - Notch UI (SwiftUI layer)
//
// boring.notch's approach: ONE fixed-size transparent window; inside it ONE shared
// black+clip layer wrapping BOTH states. The black's size is INTRINSIC (it hugs its
// content), so opening — where the content swaps from the small compact pill to the
// PopoverView — animates the black GROWING out of the notch. Margins come from padding
// the content BEFORE the shared .background(.black); per-tab sizing comes from
// .fixedSize() on PopoverView (it hugs each tab's natural width/height, like the
// menu-bar popover); tab switches morph because we animate on store.selectedTab too.
//
// macOS 13 SAFE: spring(response:dampingFraction:blendDuration:) (macOS 12+), single-
// param .onChange/.onReceive, .scale/.opacity transitions. NO macOS-14 APIs.

// MARK: - NotchShape (verbatim from TheBoredTeam/boring.notch)

/// The notch silhouette. Top corners curve inward and the side walls are INSET by
/// `topCornerRadius` from the bounding box — so content must be padded by at least that
/// much (plus the desired margin) or it gets clipped. `animatableData` rides the radii.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    static let closed: (top: CGFloat, bottom: CGFloat) = (6, 11)
    static let open: (top: CGFloat, bottom: CGFloat) = (11, 19)

    init(topCornerRadius: CGFloat? = nil, bottomCornerRadius: CGFloat? = nil) {
        self.topCornerRadius = topCornerRadius ?? NotchShape.closed.top
        self.bottomCornerRadius = bottomCornerRadius ?? NotchShape.closed.bottom
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

// MARK: - Animation constants (boring.notch's numbers, macOS-12-compatible form)

enum NotchAnimations {
    static let open  = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    static let close = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    static let reduced = Animation.linear(duration: 0.12)
}

/// Hysteresis timings (boring.notch defaults). Used by the AppKit controller.
enum NotchTiming {
    static let openDwell:  TimeInterval = 0.18
    static let closeGrace: TimeInterval = 0.12
}

// MARK: - Content size measurement (for the controller's hit-testing only)

/// The measured size of the visible black layer (compact pill or padded popover). The
/// window is fixed-size and bigger; the controller uses this to know the VISIBLE rect so
/// hover-close / mouse-passthrough track the black, not the transparent window.
private struct NotchContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

/// Measured width of the idle value text — used to shift the compact pill so the notch
/// gap stays centered over the physical notch even though the value block is wider than
/// the icon block (otherwise a bbox-centered pill drifts the value over the camera).
private struct NotchValueWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

// MARK: - Shared view model

/// Owned by NotchController, observed by NotchRootView. `isOpen` is written ONLY by the
/// controller. `contentSize` is the measured visible-black size (controller reads it for
/// hit-testing). `preventClose` is the keepVisible flag set by the footer NSMenu/NSAlert
/// coordinators. Main-thread only.
final class NotchViewModel: ObservableObject {
    @Published var isOpen: Bool = false
    @Published var contentSize: CGSize = .zero
    @Published var closedNotchSize: CGSize = .zero
    @Published var isSynthetic: Bool = false
    var preventClose: Bool = false
}

// MARK: - Environment plumbing for the shared footer menus

private struct NotchViewModelKey: EnvironmentKey {
    static let defaultValue: NotchViewModel? = nil
}

extension EnvironmentValues {
    var notchViewModel: NotchViewModel? {
        get { self[NotchViewModelKey.self] }
        set { self[NotchViewModelKey.self] = newValue }
    }
}

// MARK: - COMPACT content (the idle pill): icon hugs left shoulder, value hugs right

/// Intrinsic-width pill: Claude logo just left of the notch, value just right, with the
/// physical-notch-width clear gap between them. No background/clip here — the shared
/// parent layer owns the black, so closed and open are one continuous shape that grows.
struct CompactNotchView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    /// Icon block width = outerPad + icon(16) + innerPad. Kept in sync with the layout
    /// below so NotchRootView can compute the gap-centering offset.
    static let iconBlockWidth: CGFloat = 14 + 16 + 10
    static let innerPad: CGFloat = 10
    static let outerPad: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            // Brand-orange mark: spins while any session is busy, carries the amber/
            // green attention dot. Shared with the popover header and menu-bar icon.
            SessionAwareClaudeLogo(sessionStore: sessionStore,
                                   size: 16, color: .ccBrand, dotSize: 5)
                .padding(.leading, Self.outerPad)
                .padding(.trailing, Self.innerPad)

            // The physical notch (real black camera housing) sits in this gap.
            Color.clear.frame(width: max(8, notchWidth))

            Text(store.menuBarValue)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()   // never truncate the value — the pill widens to fit it
                .background(GeometryReader { geo in
                    Color.clear.preference(key: NotchValueWidthKey.self, value: geo.size.width)
                })
                .padding(.leading, Self.innerPad)
                .padding(.trailing, Self.outerPad)
        }
        .frame(height: max(24, notchHeight))
        .fixedSize()
    }
}

// MARK: - Root notch view (one shared black layer that GROWS from the notch)

struct NotchRootView: View {
    @ObservedObject var store: UsageStore
    // Plain `let`, NOT @ObservedObject: NotchRootView only forwards this down to
    // CompactNotchView (which observes it itself). Observing here would re-run this
    // body — and re-evaluate the embedded PopoverView while open — on every ~2s
    // session tick, the exact churn batch C removes. The compact logo-spin/dot
    // still update via CompactNotchView's own subscription.
    let sessionStore: SessionStore
    @ObservedObject var vm: NotchViewModel
    let onQuit: () -> Void

    /// Inner margin around the popover: at least the open top-corner radius (the
    /// NotchShape walls are inset by that) plus breathing room, so nothing is clipped.
    private let hMargin: CGFloat = 18
    /// Visible gap between the physical notch's bottom edge and the popover's first
    /// content row (the "CC Monitor" header). Small so the header hugs the notch.
    private let notchHeaderGap: CGFloat = 6
    /// PopoverView's own header top padding (`.padding(.top, 14)`). We subtract it from
    /// the notch offset so that transparent band overlaps the black notch instead of
    /// stacking on top and pushing the header far below the camera.
    private let popoverInnerTopPadding: CGFloat = 14
    private let bottomMargin: CGFloat = 14

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Measured idle value-text width (drives the compact gap-centering offset).
    @State private var valueWidth: CGFloat = 0

    /// Shift the compact pill so the notch gap lands dead-center over the physical notch.
    /// The value block (innerPad + value + outerPad) is wider than the icon block, so a
    /// bbox-centered pill would drift the value over the camera; this re-centers the gap.
    private var compactGapOffset: CGFloat {
        let valueBlock = CompactNotchView.innerPad + valueWidth + CompactNotchView.outerPad
        return (valueBlock - CompactNotchView.iconBlockWidth) / 2
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isOpen {
                // Hugs each tab's intrinsic width (360 / 480) and height (like the
                // menu-bar popover); padded so it floats inside the black with margins.
                PopoverView(store: store, onQuit: onQuit)
                    .environment(\.notchViewModel, vm)
                    .fixedSize()
                    .padding(.horizontal, hMargin)
                    // Drop the header just below the physical notch: the camera's height
                    // minus PopoverView's own top padding (which harmlessly overlaps the
                    // black notch) plus a small gap, so "CC Monitor" hugs the notch.
                    .padding(.top, max(8, vm.closedNotchSize.height
                                          + notchHeaderGap - popoverInnerTopPadding))
                    .padding(.bottom, bottomMargin)
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            } else {
                CompactNotchView(store: store,
                                 sessionStore: sessionStore,
                                 notchWidth: vm.closedNotchSize.width,
                                 notchHeight: vm.closedNotchSize.height)
            }
        }
        // SHARED black (and measurement) — one continuous shape under both states, so
        // the open/close size change IS the grow out of the notch.
        .background(GeometryReader { geo in
            Color.black.preference(key: NotchContentSizeKey.self, value: geo.size)
        })
        .clipShape(NotchShape(
            topCornerRadius: vm.isOpen ? NotchShape.open.top : NotchShape.closed.top,
            bottomCornerRadius: vm.isOpen ? NotchShape.open.bottom
                                          : (vm.isSynthetic ? 16 : NotchShape.closed.bottom)))
        // Center the gap over the physical notch when collapsed; the expanded popover is
        // symmetric, so no shift when open.
        .offset(x: vm.isOpen ? 0 : compactGapOffset)
        // FILL the window and center the (intrinsic-width) content at the top, so the
        // dynamic-width bar is centered on the notch. (A fixed maxWidth here left the
        // root narrower than the window, mis-positioning it and clipping the right side.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The intrinsic-size change IS the animation: grow/shrink on open/close, and
        // morph between tabs (360<->480 / varying height) — unlike the NSPopover, the
        // SwiftUI frame animates cleanly, so we WANT the spring here.
        .animation(currentAnimation, value: vm.isOpen)
        .animation(reduceMotion ? NotchAnimations.reduced : NotchAnimations.open, value: store.selectedTab)
        .preferredColorScheme(.dark)
        .onPreferenceChange(NotchContentSizeKey.self) { size in
            if size != .zero { vm.contentSize = size }
        }
        .onPreferenceChange(NotchValueWidthKey.self) { w in
            if w > 0 { valueWidth = w }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private var currentAnimation: Animation? {
        if reduceMotion { return NotchAnimations.reduced }
        return vm.isOpen ? NotchAnimations.open : NotchAnimations.close
    }
}
