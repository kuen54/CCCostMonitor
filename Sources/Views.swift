import SwiftUI
import AppKit

// PopoverView (the root popover) + the segmented tab selectors. The cards / charts /
// session / plan / menu views were split into Views_*.swift (v3.0.2).

// MARK: - Segmented tab selector

/// Pure-SwiftUI segmented control used in the NOTCH. The native `NSSegmentedControl`
/// (what `Picker(.segmented)` wraps) mis-measures its height on first appearance inside
/// the borderless, NON-KEY notch NSPanel — it renders too tall until a real click (which
/// keys the panel) forces a relayout. SwiftUI-level fixes (`.frame(height:)`, `.id`
/// rebuild) can't help because the bug lives in the hosted AppKit control; drawing it
/// ourselves sidesteps it entirely. The notch is always dark, so fixed colors are fine.
struct NotchSegmentedControl<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Text(label(item))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : Color.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = item }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.07)))
    }
}

/// Tab selector: the custom dark control in the notch, the native segmented Picker in the
/// menu bar (where it renders fine and matches the system look).
struct TabSelector<Value: Hashable>: View {
    let isNotch: Bool
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        if isNotch {
            NotchSegmentedControl(items: items, selection: $selection, label: label)
        } else {
            Picker("", selection: $selection) {
                ForEach(items, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onQuit: () -> Void

    /// Root of the localizer environment: derived from the store's @Published
    /// language, so 🌐 switches re-evaluate this body, produce a new (Equatable)
    /// Localizer, and the .environment injection re-renders every reader live.
    private var loc: Localizer { Localizer(language: store.language) }

    /// Measured height of the content section (cards + chart). Drives the scroll
    /// area's frame so the popover hugs its content when short and caps when tall.
    @State private var contentHeight: CGFloat = 0

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Cap so the whole popover always fits below the menu bar. If the content
    /// outgrows the screen, NSPopover silently repositions the popover sideways
    /// (arrow detaches from the status item) — scrolling instead prevents that.
    private var maxContentHeight: CGFloat {
        // visibleFrame already excludes the menu bar and Dock.
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        // Fixed chrome around the scroll area: header + month nav + tab picker
        // above, divider + footer below, plus popover arrow/margins.
        return max(240, screenH - 190)
    }

    /// Cost + Tokens + Time + Session always; the Plan tab only when the user has
    /// subscription auth. Explicit arrays, NOT DisplayTab.allCases: display order
    /// (cost, tokens, time, session, subscription) differs from rawValue order —
    /// `time = 3` and `session = 4` were APPENDED so persisted rawValues never remap.
    private var visibleTabs: [DisplayTab] {
        store.hasOAuthToken
            ? [.cost, .tokens, .time, .session, .subscription]
            : [.cost, .tokens, .time, .session]
    }

    /// Notch-only spring for the per-tab WIDTH flip (360↔480). In the notch the black
    /// shape grows symmetrically from the center, so a spring reads well. Menu bar gets
    /// nil here, so tabs switch INSTANTLY: an animated NSPopover resize jitters the rows
    /// above and a width animation overshoots, exposing the window backing as a black
    /// flash — so the menu-bar popover snaps with no animation. Reduce-motion aware.
    private var notchWidthAnimation: Animation? {
        guard store.displayMode == .notch else { return nil }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? NotchAnimations.reduced : NotchAnimations.open
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                HStack(spacing: 6) {
                    // Inherits the notch/menu-bar mark's behavior: spins while a
                    // session is busy, shows the amber/green attention dot.
                    SessionAwareClaudeLogo(sessionStore: store.sessionStore,
                                           size: 14, color: .ccBrand, dotSize: 5)
                    Text(loc("title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // ── Month Navigator (top-level, highest hierarchy) ──
            HStack {
                Button(action: { store.navigateMonth(offset: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(store.viewingMonthLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { store.navigateMonth(offset: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(store.isCurrentMonth)
                .opacity(store.isCurrentMonth ? 0.3 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // ── Tab selector (Cost / Tokens / Time / Plan) ──
            // The Plan tab is only shown to subscription (OAuth) users — API-key users
            // (Bedrock / Vertex / Console) have no 5h/weekly quota to display.
            TabSelector(isNotch: store.displayMode == .notch,
                        items: visibleTabs,
                        selection: $store.selectedTab,
                        label: { $0.label(loc) })
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // ── Content (sized to fit, scrolls only when taller than the screen) ──
            // Subscription quota lives in its own "Plan" tab; the Cost/Token tabs
            // stay focused on spend.
            ScrollView(showsIndicators: false) {
                contentSection
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geo.size.height)
                    })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 1), maxContentHeight))

            Divider()
                .padding(.horizontal, 10)

            footer
        }
        // The Time tab needs room for a 53-column heatmap and a 0–24h timeline,
        // and the Session tab reads better wide for grouped path lists; the other
        // tabs keep the original compact width.
        .frame(width: (store.selectedTab == .time || store.selectedTab == .session) ? 480 : 360)
        // Notch: spring the width flip so it grows symmetrically from the notch center.
        // Menu bar: nil → tabs switch instantly (no NSPopover resize animation). See
        // notchWidthAnimation.
        .animation(notchWidthAnimation, value: store.selectedTab)
        // Single injection point: every subview resolves strings via
        // @Environment(\.localizer) from here on down.
        .environment(\.localizer, loc)
    }

    @ViewBuilder
    private var contentSection: some View {
            if store.selectedTab == .time {
                TimeTabView(store: store)
            } else if store.selectedTab == .session {
                SessionTabView(sessionStore: store.sessionStore)
            } else if store.selectedTab == .subscription {
                SubscriptionView(store: store)
            } else if store.isCurrentMonth {
                if let today = store.today, let week = store.week, let month = store.month {
                    cardsWithChart {
                        PeriodCard(metric: store.selectedTab, icon: "calendar",
                                   title: loc("today"), usage: today)
                        PeriodCard(metric: store.selectedTab, icon: "calendar.badge.clock",
                                   title: loc("thisWeek"), usage: week)
                        PeriodCard(metric: store.selectedTab, icon: "chart.bar",
                                   title: loc("thisMonth"), usage: month,
                                   showStats: true)
                    }
                } else if store.isLoading {
                    loadingView
                } else {
                    errorView
                }
            } else {
                if let month = store.month {
                    cardsWithChart {
                        PeriodCard(metric: store.selectedTab, icon: "chart.bar",
                                   title: loc("monthlyTotal"), usage: month,
                                   showStats: true)
                    }
                } else if store.isLoading {
                    loadingView
                } else {
                    noDataView
                }
            }
    }

    /// Shared layout for the current-month and historical-month branches: the
    /// period cards (cost or tokens per the selected tab) followed by the daily
    /// chart, with the section's paddings.
    @ViewBuilder
    private func cardsWithChart<Cards: View>(@ViewBuilder cards: () -> Cards) -> some View {
        VStack(spacing: 8) {
            cards()
            if let daily = store.dailyBreakdown, !daily.isEmpty {
                DailyChart(data: daily, mode: store.selectedTab,
                           year: store.viewingYear, month: store.viewingMonth)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // ── Footer ──
    private var footer: some View {
        HStack(spacing: 12) {
                if store.selectedTab == .subscription {
                    // The Plan tab shows OAuth quota, not the local JSONL scan, so
                    // bind its OWN fetch time (`quotaUpdatedAt`) — never `lastUpdate`
                    // (which is always "just now" after any scan) or the month-scoped
                    // "cached data" label (quota isn't month-scoped). Nil until the
                    // first successful fetch, in which case show nothing (the tab
                    // itself renders a loading spinner).
                    if let qt = store.quotaUpdatedAt {
                        Text(String(format: loc("updated"), timeAgo(qt, loc)))
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                } else if let time = store.lastUpdate, store.isCurrentMonth {
                    Text(String(format: loc("updated"),
                                timeAgo(time, loc)))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                } else if !store.isCurrentMonth {
                    Text(loc("cachedData"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Language switcher
                LanguageSwitcher(store: store)

                // Options (archive history toggle + clear)
                OptionsMenu(store: store, loc: loc)

                // Manual refresh ALWAYS runs a real scan: force bypasses the
                // fingerprint short-circuit (the user is explicitly asking).
                Button(action: { store.refresh(force: true) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(loc("refresh"))
                .keyboardShortcut("r", modifiers: .command)

                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(loc("quit"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(loc("loading"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text(loc("loadFailed"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }

    private var noDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(loc("noMonthData"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }
}
