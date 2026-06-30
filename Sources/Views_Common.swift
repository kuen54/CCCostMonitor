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

