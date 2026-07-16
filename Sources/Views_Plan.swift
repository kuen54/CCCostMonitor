import SwiftUI
import AppKit

// Subscription (Plan) tab.
// Extracted from the former single-file Views.swift (v3.0.2 split; no behavior change).

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
                // Per-model weekly caps. Anthropic now delivers these in the `limits`
                // array (a `weekly_scoped` entry per model — e.g. the separate Fable
                // cap subscription users recently got). Render one remaining bar each.
                ForEach(Array(q.scopedModelLimits.enumerated()), id: \.offset) { _, lim in
                    SubWindowRow(
                        label: String(format: loc("sub7dScopedFmt"), lim.modelDisplayName ?? ""),
                        usedPercent: lim.displayPercent,
                        resetAt: lim.resetDate)
                }
                // Legacy flat Sonnet-only 7-day cap (pre-`limits` accounts, Max plans).
                // Shown only when the newer array didn't already surface a Sonnet-scoped
                // bar, so the model never renders twice.
                if let sonnet = q.seven_day_sonnet,
                   sonnet.displayPercent > 0 || sonnet.resets_at != nil,
                   !q.scopedModelLimits.contains(where: {
                       $0.modelDisplayName?.caseInsensitiveCompare("Sonnet") == .orderedSame }) {
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
                if store.quotaError != nil {
                    // Last-known bars are showing, but the latest refresh failed or
                    // the token was rejected. Surface it inline so the numbers
                    // aren't silently trusted as current — paired with the footer's
                    // real quota fetch time, the user sees "updated Nm ago" + why.
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(errorText)
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

