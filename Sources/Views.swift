import SwiftUI
import AppKit

// MARK: - Model class UI mapping
//
// Color/icon stay in the UI layer (SwiftUI Color must not enter the pure core,
// see Core_ModelClass.swift). Raw-string cases match ModelClass.rawValue.
extension ModelUsage {
    var color: Color {
        switch id {
        case "fable":  return Color(red: 0.92, green: 0.55, blue: 0.20) // orange — top tier above Opus
        case "opus":   return Color(red: 0.56, green: 0.27, blue: 0.96) // purple
        case "sonnet": return Color(red: 0.24, green: 0.52, blue: 0.98) // blue
        case "haiku":  return Color(red: 0.20, green: 0.78, blue: 0.45) // green
        case "other":  return Color(red: 0.65, green: 0.65, blue: 0.65) // gray — non-Claude (Kimi/Qwen/etc.)
        default:       return .gray
        }
    }

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
        btn.contentTintColor = .secondaryLabelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    class Coordinator: NSObject {
        let store: UsageStore
        init(store: UsageStore) { self.store = store }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
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

    /// Cost + Tokens always; the Plan tab only when the user has subscription auth.
    private var visibleTabs: [DisplayTab] {
        store.hasOAuthToken ? DisplayTab.allCases : [.cost, .tokens]
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                HStack(spacing: 6) {
                    ClaudeLogoShape()
                        .fill(Color(red: 0.851, green: 0.467, blue: 0.341))
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

            // ── Tab Picker (Cost / Tokens / Plan) ──
            // The Plan tab is only shown to subscription (OAuth) users — API-key users
            // (Bedrock / Vertex / Console) have no 5h/weekly quota to display.
            Picker("", selection: $store.selectedTab) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Label(tab.label(loc), systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        .frame(width: 360)
        // Switch tabs instantly. Without this, SwiftUI animates the content-height
        // change when selectedTab flips, which ripples up and makes the month-nav row
        // jitter as the popover resizes. nil animation = instant swap, no resize wobble.
        .animation(nil, value: store.selectedTab)
        // Single injection point: every subview resolves strings via
        // @Environment(\.localizer) from here on down.
        .environment(\.localizer, loc)
    }

    @ViewBuilder
    private var contentSection: some View {
            if store.selectedTab == .subscription {
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
