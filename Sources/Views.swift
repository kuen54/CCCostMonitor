import SwiftUI
import AppKit

// MARK: - Model class UI mapping
//
// Color/icon stay in the UI layer (SwiftUI Color must not enter the pure core,
// see Core_ModelClass.swift). Raw-string cases match ModelClass.rawValue.

/// Single source of truth for the model-class palette: usage bars/chips
/// (ModelUsage.color) and the Time tab's interval capsules share it.
/// nil / unknown ids fall back to the non-Claude gray.
func modelClassColor(_ id: String?) -> Color {
    switch id {
    case "fable":  return Color(red: 0.92, green: 0.55, blue: 0.20) // orange — top tier above Opus
    case "opus":   return Color(red: 0.56, green: 0.27, blue: 0.96) // purple
    case "sonnet": return Color(red: 0.24, green: 0.52, blue: 0.98) // blue
    case "haiku":  return Color(red: 0.20, green: 0.78, blue: 0.45) // green
    default:       return Color(red: 0.65, green: 0.65, blue: 0.65) // gray — non-Claude (Kimi/Qwen/etc.) / untagged
    }
}

extension ModelUsage {
    var color: Color { modelClassColor(id) }

    var icon: String {
        switch id {
        case "fable":  return "circle.fill"
        case "opus":   return "circle.fill"
        case "sonnet": return "circle.fill"
        case "haiku":  return "circle.fill"
        default:       return "circle"
        }
    }
}

// MARK: - Localizer environment
//
// Injected once at the root (PopoverView) from the store's @Published language;
// every subview reads it via @Environment(\.localizer). Localizer is Equatable
// (wraps the language), so a language switch produces a new environment value and
// SwiftUI re-renders all readers. The default is the system-detected language —
// the same default the app uses on first launch — so there is no silent-English
// path even if a view were ever hosted without the injection.
private struct LocalizerKey: EnvironmentKey {
    static let defaultValue = Localizer(language: AppLanguage.fromSystem())
}

extension EnvironmentValues {
    var localizer: Localizer {
        get { self[LocalizerKey.self] }
        set { self[LocalizerKey.self] = newValue }
    }
}

// MARK: - SwiftUI Views

// ── Claude logo as SwiftUI Shape ──
struct ClaudeLogoShape: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        // Official Claude logo SVG path (SimpleIcons, CC0) — data in ClaudeLogo.swift
        ClaudeLogo.swiftUIPath(scale: min(rect.width, rect.height) / 24.0)
    }
}

// ── Proportion bar (generic — works for cost or tokens) ──
struct ProportionBar: View {
    let segments: [(color: Color, fraction: CGFloat)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.fraction > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seg.color)
                            .frame(width: max(3, seg.fraction * geo.size.width))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

// ── Cost proportion bar (convenience wrapper) ──
struct CostBar: View {
    let models: [ModelUsage]
    let total: Double

    var body: some View {
        ProportionBar(segments: models.map { m in
            (color: m.color, fraction: total > 0 ? CGFloat(m.cost / total) : 0)
        })
    }
}

// ── Token proportion bar (by model) ──
struct TokenBar: View {
    let models: [ModelUsage]
    let total: Int

    var body: some View {
        ProportionBar(segments: models.map { m in
            (color: m.color, fraction: total > 0 ? CGFloat(Double(m.totalTokens) / Double(total)) : 0)
        })
    }
}

// ── Token type proportion bar (in / out / cache_r / cache_w) ──
struct TokenTypeBar: View {
    let usage: PeriodUsage
    @Environment(\.localizer) private var loc

    // in/out use saturated teal & coral; cache_read/cache_write use desaturated tints of same hues
    static let typeEntries: [(String, Color, KeyPath<PeriodUsage, Int>)] = [
        ("tkIn",  Color(red: 0.10, green: 0.60, blue: 0.65), \.totalInput),      // teal
        ("tkOut", Color(red: 0.90, green: 0.40, blue: 0.30), \.totalOutput),      // coral
        ("tkCR",  Color(red: 0.55, green: 0.78, blue: 0.80), \.totalCacheRead),   // desaturated teal
        ("tkCW",  Color(red: 0.92, green: 0.70, blue: 0.62), \.totalCacheWrite),  // desaturated coral
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProportionBar(segments: Self.typeEntries.map { (_, color, kp) in
                let val = usage[keyPath: kp]
                return (color: color, fraction: usage.totalTokens > 0
                    ? CGFloat(Double(val) / Double(usage.totalTokens)) : 0)
            })

            // Legend row
            HStack(spacing: 10) {
                ForEach(Array(Self.typeEntries.enumerated()), id: \.offset) { _, item in
                    let (key, color, kp) = item
                    HStack(spacing: 3) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(loc(key))
                            .font(.system(size: 9))
                            .foregroundColor(color.opacity(0.9))
                        Text(formatTokensShort(usage[keyPath: kp]))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// ── Daily bar chart ──
struct DailyChart: View {
    let data: [DailyUsage]
    let mode: DisplayTab
    let year: Int
    let month: Int
    @Environment(\.localizer) private var loc

    @State private var hoveredDay: Int? = nil

    private var daysInMonth: Int {
        let cal = AppDate.gregorian
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let start = cal.date(from: comps),
              let next = cal.date(byAdding: .month, value: 1, to: start),
              let last = cal.date(byAdding: .day, value: -1, to: next) else { return 30 }
        return cal.component(.day, from: last)
    }

    private var dayLookup: [Int: DailyUsage] {
        Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })
    }

    private var maxValue: Double {
        data.map { mode == .cost ? $0.cost : Double($0.totalTokens) }.max() ?? 1
    }

    // Which day numbers to show as x-axis labels
    private var labelDays: Set<Int> {
        let total = daysInMonth
        var labels: Set<Int> = [1]
        for d in stride(from: 5, through: total - 3, by: 5) { labels.insert(d) }
        labels.insert(total)
        return labels
    }

    private let chartHeight: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title + hover tooltip
            HStack(spacing: 4) {
                Text(loc("daily"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if let day = hoveredDay, let usage = dayLookup[day] {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(String(format: "%d/%d", month, day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    if mode == .cost {
                        Text(formatCost(usage.cost))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    } else {
                        Text(formatTokensShort(usage.totalTokens))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    // Model breakdown chips
                    ForEach(usage.models.filter {
                        mode == .cost ? $0.cost > 0 : $0.totalTokens > 0
                    }) { m in
                        HStack(spacing: 2) {
                            Circle().fill(m.color).frame(width: 4, height: 4)
                            Text(mode == .cost
                                 ? formatCost(m.cost)
                                 : formatTokensShort(m.totalTokens))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                } else if let day = hoveredDay, dayLookup[day] == nil {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(String(format: "%d/%d", month, day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    Text(loc("noData"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(height: 14)

            // Bar chart
            GeometryReader { geo in
                let totalDays = CGFloat(daysInMonth)
                let spacing: CGFloat = 1
                let barWidth = max(2, (geo.size.width - spacing * (totalDays - 1)) / totalDays)
                let ch = geo.size.height

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(1...daysInMonth, id: \.self) { day in
                        barView(day: day, barWidth: barWidth, chartHeight: ch)
                    }
                }
            }
            .frame(height: chartHeight)

            // X-axis labels
            GeometryReader { geo in
                let totalDays = CGFloat(daysInMonth)
                let spacing: CGFloat = 1
                let barWidth = (geo.size.width - spacing * (totalDays - 1)) / totalDays
                let step = barWidth + spacing

                ZStack(alignment: .leading) {
                    ForEach(Array(labelDays.sorted()), id: \.self) { day in
                        Text("\(day)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                            .position(
                                x: step * CGFloat(day - 1) + barWidth / 2,
                                y: 5
                            )
                    }
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Bar Chart Helpers

    @ViewBuilder
    private func barView(day: Int, barWidth: CGFloat, chartHeight: CGFloat) -> some View {
        if let usage = dayLookup[day] {
            let value = mode == .cost ? usage.cost : Double(usage.totalTokens)
            let height = maxValue > 0 ? CGFloat(value / maxValue) * chartHeight : 0
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                stackedBar(usage: usage, totalHeight: max(2, height), barWidth: barWidth,
                           highlighted: hoveredDay == day)
            }
            .frame(width: barWidth)
            .contentShape(Rectangle())
            .onHover { h in hoveredDay = h ? day : nil }
        } else {
            VStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: barWidth, height: 1)
            }
            .frame(width: barWidth)
            .contentShape(Rectangle())
            .onHover { h in hoveredDay = h ? day : nil }
        }
    }

    @ViewBuilder
    private func stackedBar(usage: DailyUsage, totalHeight: CGFloat, barWidth: CGFloat,
                            highlighted: Bool) -> some View {
        let total = mode == .cost ? usage.cost : Double(usage.totalTokens)
        if total > 0 {
            VStack(spacing: 0) {
                ForEach(usage.models) { model in
                    let modelVal = mode == .cost ? model.cost : Double(model.totalTokens)
                    let fraction = modelVal / total
                    let segHeight = max(0, CGFloat(fraction) * totalHeight)
                    if segHeight > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(model.color)
                            .frame(width: barWidth, height: segHeight)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(
                // Subtle top cap on hover
                highlighted ?
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                    : nil
            )
        }
    }
}

// ── Single model row (cost) ──
struct ModelRow: View {
    let model: ModelUsage

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.color)
                .frame(width: 8, height: 8)
            Text(model.name)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
            Spacer()
            Text(formatCost(model.cost))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// ── Single model row (tokens) ──
struct TokenModelRow: View {
    let model: ModelUsage
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.color)
                    .frame(width: 8, height: 8)
                Text(model.name)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTokensShort(model.totalTokens))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.primary)
            }
            // Token breakdown sub-row
            HStack(spacing: 8) {
                TokenChip(label: loc("tkIn"), value: model.inputTokens, color: TokenTypeBar.typeEntries[0].1)
                TokenChip(label: loc("tkOut"), value: model.outputTokens, color: TokenTypeBar.typeEntries[1].1)
                TokenChip(label: loc("tkCR"), value: model.cacheRead, color: TokenTypeBar.typeEntries[2].1)
                TokenChip(label: loc("tkCW"), value: model.cacheWrite, color: TokenTypeBar.typeEntries[3].1)
            }
            .padding(.leading, 14)
        }
    }
}

// ── Compact token chip ──
struct TokenChip: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(color.opacity(0.8))
            Text(formatTokensShort(value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

// ── Period card (shared chrome for both metrics: cost and tokens) ──
struct PeriodCard: View {
    let metric: DisplayTab        // .cost or .tokens — picks the displayed metric
    let icon: String
    let title: String
    let usage: PeriodUsage
    var showStats: Bool = false
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title + headline value (cost or total tokens)
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(metric == .cost ? formatCost(usage.cost)
                                     : formatTokensShort(usage.totalTokens))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            if metric == .cost {
                // Cost proportion bar
                if !usage.models.isEmpty {
                    CostBar(models: usage.models, total: usage.cost)
                        .padding(.vertical, 2)
                }

                // Model breakdown
                ForEach(usage.models.filter { $0.cost >= 0.005 }) { m in
                    ModelRow(model: m)
                }
            } else {
                // Token type distribution bar (in / out / cache_r / cache_w)
                if usage.totalTokens > 0 {
                    TokenTypeBar(usage: usage)
                        .padding(.vertical, 2)
                }

                // Model proportion bar
                if !usage.models.isEmpty {
                    TokenBar(models: usage.models, total: usage.totalTokens)
                        .padding(.bottom, 2)
                }

                // Model breakdown
                ForEach(usage.models.filter { $0.totalTokens > 0 }) { m in
                    TokenModelRow(model: m)
                }
            }

            // Stats footer (month only) — shows the complementary metric
            if showStats {
                HStack(spacing: 12) {
                    Label("\(formatNumber(usage.totalMessages))", systemImage: "message")
                    if metric == .cost {
                        Label(formatTokens(usage.totalTokens, loc), systemImage: "number")
                    } else {
                        Label(formatCost(usage.cost), systemImage: "dollarsign.circle")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// ── Language switcher (plain button → NSMenu, avoids accent color tinting) ──
struct LanguageSwitcher: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        // nil in menu-bar mode (NSPopover host never injects it) → keepVisible no-ops.
        context.coordinator.notchVM = context.environment.notchViewModel
        btn.contentTintColor = .secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        weak var notchVM: NotchViewModel?
        init(store: UsageStore) { self.store = store }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self
            for lang in AppLanguage.allCases {
                let item = NSMenuItem(title: lang.displayName, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = lang
                if lang == store.language { item.state = .on }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pick(_ item: NSMenuItem) {
            if let lang = item.representedObject as? AppLanguage {
                store.setLanguage(lang)
            }
        }

        // keepVisible: hold the notch panel open while this NSMenu is up (the cursor
        // leaves the notch's hover zone to reach the menu items).
        func menuWillOpen(_ menu: NSMenu) { notchVM?.preventClose = true }
        func menuDidClose(_ menu: NSMenu) { notchVM?.preventClose = false }
    }
}

/// Footer "⋯" menu: the durable-archive toggle + a confirmed clear. Mirrors
/// LanguageSwitcher's NSButton→NSMenu coordinator pattern; localized strings are
/// threaded in from the popover's Localizer (the menu lives in AppKit, outside
/// the SwiftUI environment).
struct OptionsMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.loc = loc
        // nil in menu-bar mode (NSPopover host never injects it) → keepVisible no-ops.
        context.coordinator.notchVM = context.environment.notchViewModel
        btn.contentTintColor = .secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, loc: loc) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        var loc: Localizer
        weak var notchVM: NotchViewModel?
        init(store: UsageStore, loc: Localizer) { self.store = store; self.loc = loc }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self

            // Display location: menu bar vs notch. A disabled header + one
            // checkable item per mode (mirrors the LanguageSwitcher pattern).
            let modeHeader = NSMenuItem(title: loc("displayModeHeader"), action: nil, keyEquivalent: "")
            modeHeader.isEnabled = false
            menu.addItem(modeHeader)
            for mode in DisplayMode.allCases {
                let item = NSMenuItem(title: mode.label(loc),
                                      action: #selector(pickDisplayMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = store.displayMode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())

            let toggle = NSMenuItem(title: loc("archiveToggle"),
                                    action: #selector(toggleArchive), keyEquivalent: "")
            toggle.target = self
            toggle.state = store.archiveHistoryLocally ? .on : .off
            menu.addItem(toggle)

            // Informational (disabled) line: live archived-day count once there's
            // data, else the "what is this" hint for first-timers.
            let count = store.archivedDayCount
            let noteTitle = count > 0 ? String(format: loc("archiveCount"), count) : loc("archiveNote")
            let note = NSMenuItem(title: noteTitle, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)

            menu.addItem(.separator())

            let clear = NSMenuItem(title: loc("archiveClear"),
                                   action: #selector(clearArchive), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pickDisplayMode(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let mode = DisplayMode(rawValue: raw) {
                store.setDisplayMode(mode)
            }
        }

        @objc func toggleArchive() {
            store.setArchiveHistoryLocally(!store.archiveHistoryLocally)
        }

        @objc func clearArchive() {
            // Hold the notch open across the modal; in notch mode also bring the app
            // forward so the alert (from a non-activating panel) isn't buried.
            notchVM?.preventClose = true
            if notchVM != nil { NSApp.activate(ignoringOtherApps: true) }
            defer { notchVM?.preventClose = false }

            let alert = NSAlert()
            alert.messageText = loc("archiveClearTitle")
            alert.informativeText = loc("archiveClearBody")
            alert.alertStyle = .warning
            alert.addButton(withTitle: loc("archiveClearConfirm"))
            alert.addButton(withTitle: loc("archiveClearCancel"))
            // First button (Clear) == NSAlertFirstButtonReturn (1000); compare by
            // rawValue so the constant resolves across SDK variants.
            if alert.runModal().rawValue == 1000 {
                store.clearArchive()
            }
        }

        // keepVisible: hold the notch panel open while the ⋯ NSMenu is up.
        func menuWillOpen(_ menu: NSMenu) { notchVM?.preventClose = true }
        func menuDidClose(_ menu: NSMenu) { notchVM?.preventClose = false }
    }
}

// MARK: - Subscription tab

/// One subscription window rendered with a "remaining" framing (how much quota is
/// LEFT, not how much is used) — that's the question subscription users actually ask.
/// Anthropic's API reports `utilization` (percent used); remaining = 100 - used.
struct SubWindowRow: View {
    let label: String
    let usedPercent: Int          // 0-100+ as reported by the API
    let resetAt: Date?
    @Environment(\.localizer) private var loc

    private var remaining: Int { max(0, 100 - usedPercent) }
    private var remainingFraction: CGFloat { max(0, min(1, CGFloat(remaining) / 100.0)) }

    /// Green when there's plenty left, amber when getting low, red when nearly out.
    private var color: Color {
        switch remaining {
        case 30...:  return Color(red: 0.20, green: 0.78, blue: 0.45)  // green
        case 10..<30: return Color(red: 0.95, green: 0.70, blue: 0.25) // amber
        default:      return Color(red: 0.90, green: 0.40, blue: 0.30) // coral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if let r = resetAt {
                    Text(String(format: loc("subResetFmt"), shortDuration(r)))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: loc("subRemaining"), "\(remaining)%"))
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundColor(color)
                Spacer()
                Text(String(format: loc("subUsedFmt"), usedPercent))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            // Remaining bar (fills with what's LEFT)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * remainingFraction))
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func shortDuration(_ date: Date) -> String {
        let s = max(0, date.timeIntervalSinceNow)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 {
            let h = Int(s / 3600), m = Int((s.truncatingRemainder(dividingBy: 3600)) / 60)
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(Int(s / 86400))d"
    }
}

/// Dedicated tab: remaining subscription quota across the 5-hour and weekly windows.
/// Sourced from Anthropic's official OAuth usage endpoint (the real numbers Claude
/// Code's own /status uses) rather than estimated from local logs.
struct SubscriptionView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(spacing: 8) {
            if let q = store.subscriptionQuota {
                SubWindowRow(label: loc("sub5hLabel"),
                             usedPercent: q.five_hour.displayPercent,
                             resetAt: q.fiveHourResetDate)
                SubWindowRow(label: loc("sub7dLabel"),
                             usedPercent: q.seven_day.displayPercent,
                             resetAt: q.sevenDayResetDate)
                // Max plans expose a separate Sonnet 7-day cap. Show it only when the
                // API actually returns a bucket with activity or a reset time.
                if let sonnet = q.seven_day_sonnet,
                   sonnet.displayPercent > 0 || sonnet.resets_at != nil {
                    SubWindowRow(label: loc("sub7dSonnetLabel"),
                                 usedPercent: sonnet.displayPercent,
                                 resetAt: q.sevenDaySonnetResetDate)
                }
                if q.extra_usage?.is_enabled == true {
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(loc("subExtraOn"))
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 2)
                }
            } else if store.quotaError != nil {
                stateMessage(icon: "exclamationmark.triangle", text: errorText)
            } else {
                // Has a token but quota not loaded yet.
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc("subWaitData"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .frame(height: 80)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func stateMessage(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(.secondary)
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var errorText: String {
        switch store.quotaError {
        case .unauthorized:    return loc("quotaTokenExpired")
        case .rateLimited:     return loc("quotaRateLimited")
        case .decodeFailure:   return loc("quotaDecodeFail")
        case .networkFailure, nil:
            return loc("quotaFetchFail")
        }
    }
}

// MARK: - Time tab (active usage time)

/// Inner Week / Month / Year switcher + the three time charts.
/// - Week follows the EXISTING top month navigator (viewingTimeData) and owns
///   a ◀▶ week nav among the weeks overlapping the viewed month; the selected
///   week lives in the store (survives tab switches, reset by month nav).
/// - Month follows the EXISTING top month navigator (viewingTimeData); no
///   second navigator inside the tab.
/// - Year owns its ◀▶ year nav and lazy-loads via --time-year.
struct TimeTabView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(spacing: 8) {
            TabSelector(isNotch: store.displayMode == .notch,
                        items: TimeRange.allCases,
                        selection: $store.timeRange,
                        label: { $0.label(loc) })

            switch store.timeRange {
            case .week:
                if let data = store.viewingTimeData {
                    WeekTimeChart(store: store, timeData: data)
                } else {
                    timeStateView
                }
            case .month:
                if let data = store.viewingTimeData {
                    MonthTimeChart(timeData: data,
                                   year: store.viewingYear, month: store.viewingMonth)
                } else {
                    timeStateView
                }
            case .year:
                YearHeatmap(store: store)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// nil time data = the scan output predates the Time feature (old script /
    /// pre-feature cache): spinner while the background refresh runs, "no data"
    /// otherwise.
    @ViewBuilder
    private var timeStateView: some View {
        VStack(spacing: 8) {
            if store.isLoading {
                ProgressView().controlSize(.small)
                Text(loc("loading"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 20)).foregroundColor(.secondary)
                Text(loc("noData"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}

/// Monday-first localized short weekday symbols (DateFormatter's
/// shortWeekdaySymbols is Sunday-first → rotate). Human-facing → locale-aware.
private func mondayFirstWeekdaySymbols(_ loc: Localizer) -> [String] {
    let df = DateFormatter()
    df.locale = Locale(identifier: loc.language.rawValue)
    let symbols = df.shortWeekdaySymbols ?? []
    guard symbols.count == 7 else { return Array(repeating: "", count: 7) }
    return (0..<7).map { symbols[($0 + 1) % 7] }
}

// ── Week view: Apple-Health-sleep-style timeline, 7 rows Mon–Sun ──
// Shows the store's selected week within the VIEWED month (viewingTimeData):
// own ◀▶ nav among the weeks overlapping that month; out-of-month days render
// dimmed (the month view's idiom), their intervals drawn only when the payload
// happens to carry them (current week's prev-month tail from the cross-week
// merge) — never fabricated.
struct WeekTimeChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData
    @Environment(\.localizer) private var loc

    private struct HoveredInterval {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil

    private let rowHeight: CGFloat = 20
    private let labelWidth: CGFloat = 34
    private let totalWidth: CGFloat = 40
    private let gridHours = [0, 6, 12, 18, 24]

    private var monthPrefix: String {
        String(format: "%04d-%02d-", store.viewingYear, store.viewingMonth)
    }
    /// Monday-aligned weeks overlapping the viewed month — the ◀▶ nav range
    /// (same list the month view's rows derive from).
    private var weeks: [Date] {
        TimeLogic.weeksOfMonth(year: store.viewingYear, month: store.viewingMonth)
    }
    private var selectedWeekIndex: Int? {
        store.resolvedWeekMonday.flatMap { TimeLogic.weekIndex(of: $0, in: weeks) }
    }
    private var dayKeys: [String] {
        store.resolvedWeekMonday.map(TimeLogic.weekDayKeys) ?? []
    }
    /// Stats/render scope: in-month days always; out-of-month days only when
    /// the payload actually carries them (no fabricated zeros).
    private var renderedDayKeys: [String] {
        dayKeys.filter { $0.hasPrefix(monthPrefix) || timeData.days[$0] != nil }
    }
    private var todayKey: String { AppDate.dayKey(Date()) }
    private var weekTotal: Int {
        TimeLogic.totalSeconds(in: timeData.days, dayKeys: renderedDayKeys)
    }
    /// Daily-avg divisor: the week containing today averages over elapsed days
    /// Mon..today (a Tuesday isn't averaged over 7 days); a fully past week
    /// over the days that rendered data (min 1); a future week renders 0s.
    private var avgDivisor: Int {
        if let todayIndex = dayKeys.firstIndex(of: todayKey) {
            return todayIndex + 1
        }
        // "yyyy-MM-dd" keys compare chronologically as strings.
        guard let first = dayKeys.first, first <= todayKey else { return 1 }
        return max(1, renderedDayKeys.count)
    }
    /// Monday-first row labels (shared with the month view's column headers).
    private var weekdaySymbols: [String] { mondayFirstWeekdaySymbols(loc) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            weekNav
            summaryHeader
            hoverStrip
            VStack(spacing: 2) {
                ForEach(Array(dayKeys.enumerated()), id: \.element) { index, key in
                    weekRow(index: index, dayKey: key)
                }
            }
            axisLabels
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // ◀ 6/1 – 6/7 ▶ — week navigation within the viewed month (the year nav's
    // disabled idiom at both ends; months change via the top month navigator).
    private var weekNav: some View {
        let index = selectedWeekIndex
        let atFirst = (index ?? 0) <= 0
        let atLast = index.map { $0 >= weeks.count - 1 } ?? true
        return HStack {
            Button(action: { store.navigateTimeWeek(offset: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(atFirst)
            .opacity(atFirst ? 0.3 : 1)

            Spacer()

            // Numeric M/d span — locale-neutral by design, no i18n key needed.
            Text("\(shortDate(dayKeys.first ?? "")) – \(shortDate(dayKeys.last ?? ""))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button(action: { store.navigateTimeWeek(offset: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(atLast)
            .opacity(atLast ? 0.3 : 1)
        }
    }

    // Header summary: week total / daily avg / longest session.
    private var summaryHeader: some View {
        HStack(spacing: 18) {
            stat(loc("timeWeekTotal"), TimeLogic.formatDurationShort(weekTotal))
            stat(loc("timeDailyAvg"), TimeLogic.formatDurationShort(weekTotal / avgDivisor))
            stat(loc("timeLongest"), TimeLogic.formatDurationShort(
                TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: renderedDayKeys)))
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
    }

    // Fixed-height hover readout (same idiom as DailyChart's header tooltip):
    // interval start–end + duration, no layout shift on hover.
    private var hoverStrip: some View {
        HStack(spacing: 4) {
            if let h = hovered {
                Text(shortDate(h.dayKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                Text("\(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(height: 12)
    }

    /// "M/d" from a day key — same compact style as DailyChart's hover date.
    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    private func weekRow(index: Int, dayKey: String) -> some View {
        let inMonth = dayKey.hasPrefix(monthPrefix)
        let day = timeData.days[dayKey]
        let total = day?.totalSeconds ?? 0
        // Today-row highlight is implicitly scoped to the selected week: the
        // todayKey only appears in dayKeys when that week contains today.
        let isToday = dayKey == todayKey
        return HStack(spacing: 6) {
            Text(weekdaySymbols.indices.contains(index) ? weekdaySymbols[index] : "")
                .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                .foregroundColor(isToday ? .primary : .secondary)
                .frame(width: labelWidth, alignment: .leading)
            timeline(day: day, dayKey: dayKey, dimmed: !inMonth)
                .frame(height: rowHeight)
            // Out-of-month days without payload show no total — a "0m" there
            // would fabricate data the payload never carried.
            Text(inMonth || day != nil ? TimeLogic.formatDurationShort(total) : "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(total > 0 ? .primary : .secondary.opacity(0.6))
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .background(
            isToday
                ? RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04))
                : nil
        )
    }

    // 0–24h timeline: gridlines + one capsule per gap-merged interval. Dimmed
    // rows (out-of-month days) get the month view's neutral cell wash; their
    // capsules still draw when the payload carries the day.
    private func timeline(day: DayTimeUsage?, dayKey: String, dimmed: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                if dimmed {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.025))
                        .frame(width: max(0, w - 2), height: rowHeight - 2)
                        .offset(x: 1)
                }
                ForEach(gridHours, id: \.self) { h in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)
                        .offset(x: min(w - 1, w * CGFloat(h) / 24.0))
                }
                ForEach(Array((day?.intervals ?? []).enumerated()), id: \.offset) { _, interval in
                    intervalCapsule(interval, dayKey: dayKey, width: w)
                }
            }
        }
    }

    private func intervalCapsule(_ interval: ActiveInterval, dayKey: String,
                                 width w: CGFloat) -> some View {
        // Zero-duration intervals are truthful in DATA (isolated single event);
        // the renderer pads to the 2-minute equivalent — and never below 2pt,
        // since 2 min of a 24h axis is sub-point at this width.
        let capWidth = max(2, w * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = min(max(0, w * CGFloat(interval.startSec) / 86400.0), w - capWidth)
        return Capsule()
            .fill(modelClassColor(interval.model).opacity(0.85))
            .frame(width: capWidth, height: 8)
            .offset(x: x)
            .onHover { h in
                hovered = h ? HoveredInterval(dayKey: dayKey, interval: interval) : nil
            }
    }

    // Hour labels under the rows; clear spacers mirror the label/total columns
    // so the 0/6/12/18/24 marks line up with the rows' gridlines.
    private var axisLabels: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    ForEach(gridHours, id: \.self) { h in
                        Text("\(h)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                            .position(x: min(max(w * CGFloat(h) / 24.0, 4), w - 7), y: 5)
                    }
                }
            }
            .frame(height: 10)
            Color.clear.frame(width: totalWidth, height: 1)
        }
    }
}

// ── Month view: week-per-row timeline (the week view's visual language;
// each row spans Mon 00:00 → Sun 24:00, every day column internally 0–24h) ──
// Month navigation = the EXISTING top month navigator; this chart only renders
// whatever month viewingTimeData currently holds.
struct MonthTimeChart: View {
    let timeData: TimeData
    let year: Int
    let month: Int
    @Environment(\.localizer) private var loc

    private struct HoveredInterval {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil

    private let rowHeight: CGFloat = 20
    private let labelWidth: CGFloat = 34
    private let totalWidth: CGFloat = 40

    private var monthPrefix: String { String(format: "%04d-%02d-", year, month) }
    private var todayKey: String { AppDate.dayKey(Date()) }

    /// Monday-aligned weeks covering the month, each entry 7 day keys. The
    /// first/last rows may reach into neighbor months; those cells render
    /// dimmed (see timeline) because next-month head days aren't even in this
    /// month's payload — drawing only prev-month tails would be lopsided.
    /// Same week list the Week sub-view navigates (TimeLogic.weeksOfMonth).
    private var weeks: [[String]] {
        TimeLogic.weeksOfMonth(year: year, month: month).map(TimeLogic.weekDayKeys)
    }

    /// In-month day keys only — the stats/render scope. The payload may carry
    /// prev-month tail keys from the cross-week merge; they must not leak in.
    private var monthDayKeys: [String] {
        timeData.days.keys.filter { $0.hasPrefix(monthPrefix) }
    }

    private var monthTotal: Int {
        TimeLogic.totalSeconds(in: timeData.days, dayKeys: monthDayKeys)
    }

    /// Mean over ACTIVE days only — same semantics as the bar chart's old
    /// average line: zero-usage days would drag the figure down to noise.
    private var activeDays: Int {
        monthDayKeys.filter { (timeData.days[$0]?.totalSeconds ?? 0) > 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryHeader
            hoverStrip
            weekdayHeader
            VStack(spacing: 2) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, dayKeys in
                    weekRow(dayKeys: dayKeys)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // Header summary: month total / daily avg (active days) / longest session.
    private var summaryHeader: some View {
        HStack(spacing: 18) {
            stat(loc("timeMonthTotal"), TimeLogic.formatDurationShort(monthTotal))
            stat(loc("timeDailyAvg"),
                 TimeLogic.formatDurationShort(activeDays > 0 ? monthTotal / activeDays : 0))
            stat(loc("timeLongest"), TimeLogic.formatDurationShort(
                TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: monthDayKeys)))
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
    }

    // Fixed-height hover readout (the week view's idiom): interval date +
    // start–end + duration, no layout shift on hover.
    private var hoverStrip: some View {
        HStack(spacing: 4) {
            if let h = hovered {
                Text(shortDate(h.dayKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                Text("\(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(height: 12)
    }

    /// "M/d" from a day key — same compact style as the week view.
    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    /// Localized Mon-first column headers, centered over each day column.
    private var weekdayHeader: some View {
        let symbols = mondayFirstWeekdaySymbols(loc)
        return HStack(spacing: 6) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                let dayW = geo.size.width / 7
                ZStack(alignment: .leading) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(symbols[i])
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                            .position(x: dayW * (CGFloat(i) + 0.5), y: 5)
                    }
                }
            }
            .frame(height: 10)
            Color.clear.frame(width: totalWidth, height: 1)
        }
    }

    private func weekRow(dayKeys: [String]) -> some View {
        let inMonthKeys = dayKeys.filter { $0.hasPrefix(monthPrefix) }
        let total = TimeLogic.totalSeconds(in: timeData.days, dayKeys: inMonthKeys)
        return HStack(spacing: 6) {
            Text(shortDate(dayKeys.first ?? ""))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            timeline(dayKeys: dayKeys)
                .frame(height: rowHeight)
            Text(TimeLogic.formatDurationShort(total))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(total > 0 ? .primary : .secondary.opacity(0.6))
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    // Mon 00:00 → Sun 24:00 timeline: day-boundary gridlines, dimmed
    // out-of-month cells, today's cell highlighted, one capsule per interval.
    private func timeline(dayKeys: [String]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dayW = w / 7
            ZStack(alignment: .leading) {
                ForEach(Array(dayKeys.enumerated()), id: \.offset) { i, key in
                    if !key.hasPrefix(monthPrefix) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.025))
                            .frame(width: max(0, dayW - 2), height: rowHeight - 2)
                            .offset(x: dayW * CGFloat(i) + 1)
                    } else if key == todayKey {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.045))
                            .frame(width: max(0, dayW - 2), height: rowHeight - 2)
                            .offset(x: dayW * CGFloat(i) + 1)
                    }
                }
                ForEach(0...7, id: \.self) { i in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)
                        .offset(x: min(w - 1, dayW * CGFloat(i)))
                }
                ForEach(Array(dayKeys.enumerated()), id: \.offset) { i, key in
                    if key.hasPrefix(monthPrefix), let day = timeData.days[key] {
                        ForEach(Array(day.intervals.enumerated()), id: \.offset) { _, interval in
                            intervalCapsule(interval, dayKey: key, dayIndex: i, dayWidth: dayW)
                        }
                    }
                }
            }
        }
    }

    private func intervalCapsule(_ interval: ActiveInterval, dayKey: String,
                                 dayIndex: Int, dayWidth: CGFloat) -> some View {
        // Week-view min-width padding scaled to a 1/7-width day cell: 2 min of
        // one day is sub-point here, so the 1.5pt floor carries the hover
        // hit-target.
        let capWidth = max(1.5, dayWidth * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = dayWidth * CGFloat(dayIndex)
            + min(max(0, dayWidth * CGFloat(interval.startSec) / 86400.0), dayWidth - capWidth)
        return Capsule()
            .fill(modelClassColor(interval.model).opacity(0.85))
            .frame(width: capWidth, height: 8)
            .offset(x: x)
            .onHover { h in
                hovered = h ? HoveredInterval(dayKey: dayKey, interval: interval) : nil
            }
    }
}

// ── Year view: GitHub-style heatmap, 53 cols × 7 rows, Monday-first ──
struct YearHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoveredKey: String? = nil

    private let cellSize: CGFloat = 7
    private let cellSpacing: CGFloat = 1

    private var currentYear: Int { AppDate.gregorian.component(.year, from: Date()) }

    /// GitHub contribution-graph greens, levels 1–4. Hand-picked per scheme
    /// (GitHub does the same — the light ramp is illegible on dark backgrounds)
    /// rather than opacity-derived, hence the explicit ramps.
    private static let lightRamp: [Color] = [
        Color(red: 0.608, green: 0.914, blue: 0.659), // #9be9a8
        Color(red: 0.251, green: 0.769, blue: 0.388), // #40c463
        Color(red: 0.188, green: 0.631, blue: 0.306), // #30a14e
        Color(red: 0.129, green: 0.431, blue: 0.224), // #216e39
    ]
    private static let darkRamp: [Color] = [
        Color(red: 0.055, green: 0.267, blue: 0.161), // #0e4429
        Color(red: 0.000, green: 0.427, blue: 0.196), // #006d32
        Color(red: 0.149, green: 0.651, blue: 0.255), // #26a641
        Color(red: 0.224, green: 0.827, blue: 0.325), // #39d353
    ]

    /// 5 fixed heat levels: 0 → faint neutral, 1–4 → GitHub-green ramp.
    static func levelColor(_ level: Int, dark: Bool) -> Color {
        guard (1...4).contains(level) else { return Color.primary.opacity(0.06) }
        return (dark ? darkRamp : lightRamp)[level - 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            yearNav
            if let days = store.yearTimeDays {
                hoverStrip(days)
                grid(days)
                legend
            } else {
                // nil = year fetch in flight (failures publish an empty dict,
                // so this can't spin forever).
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc("timeLoadingYear"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 90)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
        // Lazy first load — idempotent against the store's per-year cache (the
        // timeRange didSet triggers the same call when switching to Year).
        .onAppear { store.loadYearTime(store.viewingTimeYear) }
    }

    // ◀ 2026 ▶ — the Year sub-view owns its navigation (independent of the
    // top month navigator). Future years are unreachable.
    private var yearNav: some View {
        HStack {
            Button(action: { store.navigateTimeYear(offset: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Spacer()

            Text(String(store.viewingTimeYear))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button(action: { store.navigateTimeYear(offset: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(store.viewingTimeYear >= currentYear)
            .opacity(store.viewingTimeYear >= currentYear ? 0.3 : 1)
        }
    }

    // Fixed-height hover readout: localized date + active duration.
    private func hoverStrip(_ days: [String: Int]) -> some View {
        HStack(spacing: 4) {
            if let key = hoveredKey {
                Text(displayDate(key))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                Text(TimeLogic.formatDurationShort(days[key] ?? 0))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            Spacer()
        }
        .frame(height: 12)
    }

    private func displayDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.locale = Locale(identifier: loc.language.rawValue)
        return df.string(from: date)
    }

    private func grid(_ days: [String: Int]) -> some View {
        let year = store.viewingTimeYear
        let startMonday = TimeLogic.yearGridStartMonday(year: year)
        let yearPrefix = String(format: "%04d-", year)
        return VStack(alignment: .leading, spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<53, id: \.self) { col in
                        cell(col: col, row: row, startMonday: startMonday,
                             yearPrefix: yearPrefix, days: days)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(col: Int, row: Int, startMonday: Date?, yearPrefix: String,
                      days: [String: Int]) -> some View {
        let key = startMonday.flatMap {
            TimeLogic.dayKey(col: col, row: row, startMonday: $0)
        }
        if let key = key, key.hasPrefix(yearPrefix) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.levelColor(TimeLogic.heatLevel(days[key] ?? 0),
                                      dark: colorScheme == .dark))
                .frame(width: cellSize, height: cellSize)
                .onHover { h in hoveredKey = h ? key : nil }
        } else {
            // Out-of-year cell (before Jan 1 / after Dec 31) — keeps the
            // 53×7 frame without drawing.
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    // Legend bottom-right: Less ▢▢▢▢▢ More (localized).
    private var legend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text(loc("timeLess"))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.levelColor(level, dark: colorScheme == .dark))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(loc("timeMore"))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

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

    /// Cost + Tokens + Time always; the Plan tab only when the user has
    /// subscription auth. Explicit arrays, NOT DisplayTab.allCases: display
    /// order (cost, tokens, time, subscription) differs from rawValue order —
    /// `time = 3` was APPENDED so persisted rawValues never remap.
    private var visibleTabs: [DisplayTab] {
        store.hasOAuthToken ? [.cost, .tokens, .time, .subscription] : [.cost, .tokens, .time]
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
                    ClaudeLogoShape()
                        .fill(Color(red: 0.851, green: 0.467, blue: 0.341)) // Claude brand orange (#D97757)
                        .frame(width: 14, height: 14)
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
        // The Time tab needs room for a 53-column heatmap and a 0–24h timeline;
        // the other tabs keep the original compact width.
        .frame(width: store.selectedTab == .time ? 480 : 360)
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
                if let time = store.lastUpdate, store.isCurrentMonth {
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
