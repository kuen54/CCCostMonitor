import SwiftUI
import AppKit

// Shared view primitives: model-class palette, the localizer environment, logo shape, usage bars.
// Extracted from the former single-file Views.swift (v3.0.2 split; no behavior change).

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

// ── Session-aware Claude logo (shared: notch pill · popover header · menu bar) ──
//
// The Claude mark that SPINS while any live session is busy (breathes under
// reduce-motion instead) and carries the attention dot at its top-trailing corner:
// amber = a session is waiting for input, green = a turn finished unseen (amber
// outranks green; nil → no dot). This "is Claude working / does it want me" cue
// used to live only in the notch's CompactNotchView — extracting it here lets the
// popover header and the menu-bar icon render the exact same behavior.
struct SessionAwareClaudeLogo: View {
    @ObservedObject var sessionStore: SessionStore
    /// Logo edge length in points. The dot diameter/offset are passed separately.
    var size: CGFloat = 16
    /// Fill for the mark. Brand orange in the notch/popover; `.primary` in the menu
    /// bar so it stays monochrome and follows the light/dark menu-bar appearance.
    var color: Color = .ccBrand
    var dotSize: CGFloat = 5

    // Own reduce-motion source (the notch tracks it separately for its open/close
    // spring; both observe the same workspace notification, so they never disagree).
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// ~one revolution per 1.4s (the notch's original speed).
    private static let spinDegreesPerSecond: Double = 360.0 / 1.4
    /// Reduce-motion "breathe" full cycle length (seconds).
    private static let breathePeriod: Double = 2.6

    private var logoMark: some View {
        ClaudeLogoShape().fill(color).frame(width: size, height: size)
    }

    /// Spins continuously ONLY while busy && !reduceMotion (the TimelineView is torn
    /// down otherwise → no animation / CPU when idle, and no repeatForever "unwind"
    /// jump on stop — it just renders static). Under reduceMotion+busy it breathes
    /// opacity instead of spinning; idle is static.
    @ViewBuilder private var animatedLogo: some View {
        if sessionStore.anyBusy && !reduceMotion {
            TimelineView(.animation) { ctx in
                let angle = (ctx.date.timeIntervalSinceReferenceDate * Self.spinDegreesPerSecond)
                    .truncatingRemainder(dividingBy: 360)
                logoMark.rotationEffect(.degrees(angle))
            }
        } else if sessionStore.anyBusy && reduceMotion {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(2 * Double.pi * t / Self.breathePeriod) + 1) / 2  // 0…1
                logoMark.opacity(0.55 + 0.45 * phase)
            }
        } else {
            logoMark
        }
    }

    /// Attention-dot color by PRIORITY: amber (needs your input) outranks green (a
    /// turn just finished, unseen). Static (no pulse), independent of the spin.
    private var dotColor: Color? {
        if sessionStore.anyWaiting { return .ccStatusWaiting }
        if sessionStore.anyDoneUnseen { return .green }
        return nil
    }

    var body: some View {
        animatedLogo
            .frame(width: size, height: size)   // fixed box → stable overlay anchor
            .overlay(alignment: .topTrailing) {
                if let c = dotColor {
                    Circle()
                        .fill(c)
                        .frame(width: dotSize, height: dotSize)
                        // Thin light ring so the dot reads against a dark notch/menu
                        // bar and the mark it partly overlaps.
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 0.8))
                        .offset(x: dotSize * 0.3, y: -dotSize * 0.3)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
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

