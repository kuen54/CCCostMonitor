import Foundation

// MARK: - Model class (pure core)
//
// Single source of truth for the model-class taxonomy the Python script emits
// (`totals_by_model` / `daily_breakdown.*.models` keys). Replaces the formerly
// duplicated `order` arrays and `names` dictionaries in parsing/merging sites.
// CaseIterable order IS the display/iteration order (Fable above Opus, then
// Sonnet/Haiku, non-Claude models last) — keep it in sync with the Python
// script's classify_model() classes.
//
// Color/icon mapping deliberately lives in the UI layer (Views.swift extension
// on ModelUsage): SwiftUI types must not enter the pure core.
enum ModelClass: String, CaseIterable {
    case fable
    case opus
    case sonnet
    case haiku
    case other

    /// Human-facing label ("fable" → "Fable", …). Matches the former
    /// `names` dictionaries verbatim.
    var displayName: String {
        switch self {
        case .fable:  return "Fable"
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .other:  return "Other"
        }
    }

    /// Forgiving parse for keys coming from JSON. Returns nil for unknown
    /// classes — call sites skip those, exactly like the old `order` loop did.
    static func parse(_ key: String) -> ModelClass? {
        ModelClass(rawValue: key)
    }
}
