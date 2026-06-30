import SwiftUI
import AppKit

// Cost / Tokens cards + the daily bar chart.
// Extracted from the former single-file Views.swift (v3.0.2 split; no behavior change).

// ── Daily bar chart ──
struct DailyChart: View {
    let data: [DailyUsage]
    let mode: DisplayTab
    let year: Int
    let month: Int
    @Environment(\.localizer) private var loc

    @State private var hoveredDay: Int? = nil

    private var daysInMonth: Int { AppDate.daysInMonth(year: year, month: month) ?? 30 }

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

