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

// MARK: - SwiftUI Views

// ── Claude logo as SwiftUI Shape ──
struct ClaudeLogoShape: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        let s = min(rect.width, rect.height) / 24.0
        var p = SwiftUI.Path()
        // Official Claude logo SVG path (SimpleIcons, CC0)
        p.move(to: CGPoint(x: 4.7144*s, y: 15.9555*s))
        p.addLine(to: CGPoint(x: 9.4318*s, y: 13.3084*s))
        p.addLine(to: CGPoint(x: 9.5108*s, y: 13.0777*s))
        p.addLine(to: CGPoint(x: 9.4318*s, y: 12.9502*s))
        p.addLine(to: CGPoint(x: 9.2011*s, y: 12.9502*s))
        p.addLine(to: CGPoint(x: 8.4118*s, y: 12.9016*s))
        p.addLine(to: CGPoint(x: 5.7162*s, y: 12.8287*s))
        p.addLine(to: CGPoint(x: 3.3787*s, y: 12.7316*s))
        p.addLine(to: CGPoint(x: 1.1141*s, y: 12.6102*s))
        p.addLine(to: CGPoint(x: 0.5434*s, y: 12.4887*s))
        p.addLine(to: CGPoint(x: 0.0091*s, y: 11.7845*s))
        p.addLine(to: CGPoint(x: 0.0637*s, y: 11.4323*s))
        p.addLine(to: CGPoint(x: 0.5434*s, y: 11.1105*s))
        p.addLine(to: CGPoint(x: 1.2294*s, y: 11.1713*s))
        p.addLine(to: CGPoint(x: 2.7473*s, y: 11.2745*s))
        p.addLine(to: CGPoint(x: 5.0240*s, y: 11.4323*s))
        p.addLine(to: CGPoint(x: 6.6754*s, y: 11.5295*s))
        p.addLine(to: CGPoint(x: 9.1222*s, y: 11.7845*s))
        p.addLine(to: CGPoint(x: 9.5108*s, y: 11.7845*s))
        p.addLine(to: CGPoint(x: 9.5654*s, y: 11.6266*s))
        p.addLine(to: CGPoint(x: 9.4318*s, y: 11.5295*s))
        p.addLine(to: CGPoint(x: 9.3286*s, y: 11.4323*s))
        p.addLine(to: CGPoint(x: 6.9730*s, y: 9.8356*s))
        p.addLine(to: CGPoint(x: 4.4230*s, y: 8.1477*s))
        p.addLine(to: CGPoint(x: 3.0874*s, y: 7.1763*s))
        p.addLine(to: CGPoint(x: 2.3649*s, y: 6.6845*s))
        p.addLine(to: CGPoint(x: 2.0006*s, y: 6.2231*s))
        p.addLine(to: CGPoint(x: 1.8428*s, y: 5.2153*s))
        p.addLine(to: CGPoint(x: 2.4985*s, y: 4.4928*s))
        p.addLine(to: CGPoint(x: 3.3788*s, y: 4.5535*s))
        p.addLine(to: CGPoint(x: 3.6034*s, y: 4.6142*s))
        p.addLine(to: CGPoint(x: 4.4959*s, y: 5.3002*s))
        p.addLine(to: CGPoint(x: 6.4023*s, y: 6.7756*s))
        p.addLine(to: CGPoint(x: 8.8916*s, y: 8.6092*s))
        p.addLine(to: CGPoint(x: 9.2559*s, y: 8.9127*s))
        p.addLine(to: CGPoint(x: 9.4016*s, y: 8.8095*s))
        p.addLine(to: CGPoint(x: 9.4198*s, y: 8.7367*s))
        p.addLine(to: CGPoint(x: 9.2558*s, y: 8.4634*s))
        p.addLine(to: CGPoint(x: 7.9019*s, y: 6.0167*s))
        p.addLine(to: CGPoint(x: 6.4569*s, y: 3.5274*s))
        p.addLine(to: CGPoint(x: 5.8134*s, y: 2.4954*s))
        p.addLine(to: CGPoint(x: 5.6434*s, y: 1.8760*s))
        p.addCurve(to: CGPoint(x: 5.5402*s, y: 1.1475*s),
                   control1: CGPoint(x: 5.5827*s, y: 1.6210*s),
                   control2: CGPoint(x: 5.5402*s, y: 1.4086*s))
        p.addLine(to: CGPoint(x: 6.2870*s, y: 0.1335*s))
        p.addLine(to: CGPoint(x: 6.6997*s, y: 0.0*s))
        p.addLine(to: CGPoint(x: 7.6954*s, y: 0.1336*s))
        p.addLine(to: CGPoint(x: 8.1144*s, y: 0.4978*s))
        p.addLine(to: CGPoint(x: 8.7336*s, y: 1.9125*s))
        p.addLine(to: CGPoint(x: 9.7354*s, y: 4.1407*s))
        p.addLine(to: CGPoint(x: 11.2897*s, y: 7.1703*s))
        p.addLine(to: CGPoint(x: 11.7450*s, y: 8.0688*s))
        p.addLine(to: CGPoint(x: 11.9879*s, y: 8.9006*s))
        p.addLine(to: CGPoint(x: 12.0789*s, y: 9.1556*s))
        p.addLine(to: CGPoint(x: 12.2368*s, y: 9.1556*s))
        p.addLine(to: CGPoint(x: 12.2368*s, y: 9.0099*s))
        p.addLine(to: CGPoint(x: 12.3643*s, y: 7.3039*s))
        p.addLine(to: CGPoint(x: 12.6011*s, y: 5.2092*s))
        p.addLine(to: CGPoint(x: 12.8318*s, y: 2.5135*s))
        p.addLine(to: CGPoint(x: 12.9107*s, y: 1.7546*s))
        p.addLine(to: CGPoint(x: 13.2871*s, y: 0.8439*s))
        p.addLine(to: CGPoint(x: 14.0339*s, y: 0.3521*s))
        p.addLine(to: CGPoint(x: 14.6167*s, y: 0.6314*s))
        p.addLine(to: CGPoint(x: 15.0964*s, y: 1.3174*s))
        p.addLine(to: CGPoint(x: 15.0296*s, y: 1.7607*s))
        p.addLine(to: CGPoint(x: 14.7443*s, y: 3.6124*s))
        p.addLine(to: CGPoint(x: 14.1857*s, y: 6.5145*s))
        p.addLine(to: CGPoint(x: 13.8214*s, y: 8.4574*s))
        p.addLine(to: CGPoint(x: 14.0339*s, y: 8.4574*s))
        p.addLine(to: CGPoint(x: 14.2768*s, y: 8.2145*s))
        p.addLine(to: CGPoint(x: 15.2603*s, y: 6.9092*s))
        p.addLine(to: CGPoint(x: 16.9117*s, y: 4.8449*s))
        p.addLine(to: CGPoint(x: 17.6403*s, y: 4.0253*s))
        p.addLine(to: CGPoint(x: 18.4903*s, y: 3.1207*s))
        p.addLine(to: CGPoint(x: 19.0367*s, y: 2.6896*s))
        p.addLine(to: CGPoint(x: 20.0688*s, y: 2.6896*s))
        p.addLine(to: CGPoint(x: 20.8278*s, y: 3.8189*s))
        p.addLine(to: CGPoint(x: 20.4878*s, y: 4.9846*s))
        p.addLine(to: CGPoint(x: 19.4253*s, y: 6.3324*s))
        p.addLine(to: CGPoint(x: 18.5449*s, y: 7.4738*s))
        p.addLine(to: CGPoint(x: 17.2821*s, y: 9.1738*s))
        p.addLine(to: CGPoint(x: 16.4928*s, y: 10.5338*s))
        p.addLine(to: CGPoint(x: 16.5657*s, y: 10.6431*s))
        p.addLine(to: CGPoint(x: 16.7539*s, y: 10.6248*s))
        p.addLine(to: CGPoint(x: 19.6074*s, y: 10.0178*s))
        p.addLine(to: CGPoint(x: 21.1495*s, y: 9.7384*s))
        p.addLine(to: CGPoint(x: 22.9891*s, y: 9.4227*s))
        p.addLine(to: CGPoint(x: 23.8209*s, y: 9.8113*s))
        p.addLine(to: CGPoint(x: 23.9119*s, y: 10.2059*s))
        p.addLine(to: CGPoint(x: 23.5841*s, y: 11.0134*s))
        p.addLine(to: CGPoint(x: 21.6171*s, y: 11.4991*s))
        p.addLine(to: CGPoint(x: 19.3099*s, y: 11.9605*s))
        p.addLine(to: CGPoint(x: 15.8735*s, y: 12.7741*s))
        p.addLine(to: CGPoint(x: 15.8310*s, y: 12.8045*s))
        p.addLine(to: CGPoint(x: 15.8796*s, y: 12.8652*s))
        p.addLine(to: CGPoint(x: 17.4278*s, y: 13.0109*s))
        p.addLine(to: CGPoint(x: 18.0896*s, y: 13.0473*s))
        p.addLine(to: CGPoint(x: 19.7106*s, y: 13.0473*s))
        p.addLine(to: CGPoint(x: 22.7281*s, y: 13.2720*s))
        p.addLine(to: CGPoint(x: 23.5173*s, y: 13.7940*s))
        p.addLine(to: CGPoint(x: 23.9909*s, y: 14.4316*s))
        p.addLine(to: CGPoint(x: 23.9119*s, y: 14.9173*s))
        p.addLine(to: CGPoint(x: 22.6977*s, y: 15.5366*s))
        p.addLine(to: CGPoint(x: 21.0584*s, y: 15.1480*s))
        p.addLine(to: CGPoint(x: 17.2334*s, y: 14.2373*s))
        p.addLine(to: CGPoint(x: 15.9221*s, y: 13.9094*s))
        p.addLine(to: CGPoint(x: 15.7399*s, y: 13.9094*s))
        p.addLine(to: CGPoint(x: 15.7399*s, y: 14.0187*s))
        p.addLine(to: CGPoint(x: 16.8328*s, y: 15.0873*s))
        p.addLine(to: CGPoint(x: 18.8363*s, y: 16.8965*s))
        p.addLine(to: CGPoint(x: 21.3438*s, y: 19.2279*s))
        p.addLine(to: CGPoint(x: 21.4713*s, y: 19.8047*s))
        p.addLine(to: CGPoint(x: 21.1495*s, y: 20.2601*s))
        p.addLine(to: CGPoint(x: 20.8095*s, y: 20.2115*s))
        p.addLine(to: CGPoint(x: 18.6056*s, y: 18.5540*s))
        p.addLine(to: CGPoint(x: 17.7556*s, y: 17.8072*s))
        p.addLine(to: CGPoint(x: 15.8310*s, y: 16.1862*s))
        p.addLine(to: CGPoint(x: 15.7035*s, y: 16.1862*s))
        p.addLine(to: CGPoint(x: 15.7035*s, y: 16.3562*s))
        p.addLine(to: CGPoint(x: 16.1467*s, y: 17.0058*s))
        p.addLine(to: CGPoint(x: 18.4903*s, y: 20.5272*s))
        p.addLine(to: CGPoint(x: 18.6117*s, y: 21.6079*s))
        p.addLine(to: CGPoint(x: 18.4417*s, y: 21.9600*s))
        p.addLine(to: CGPoint(x: 17.8346*s, y: 22.1725*s))
        p.addLine(to: CGPoint(x: 17.1667*s, y: 22.0511*s))
        p.addLine(to: CGPoint(x: 15.7946*s, y: 20.1265*s))
        p.addLine(to: CGPoint(x: 14.3800*s, y: 17.9590*s))
        p.addLine(to: CGPoint(x: 13.2386*s, y: 16.0162*s))
        p.addLine(to: CGPoint(x: 13.0989*s, y: 16.0952*s))
        p.addLine(to: CGPoint(x: 12.4249*s, y: 23.3504*s))
        p.addLine(to: CGPoint(x: 12.1093*s, y: 23.7207*s))
        p.addLine(to: CGPoint(x: 11.3807*s, y: 24.0000*s))
        p.addLine(to: CGPoint(x: 10.7736*s, y: 23.5386*s))
        p.addLine(to: CGPoint(x: 10.4518*s, y: 22.7918*s))
        p.addLine(to: CGPoint(x: 10.7736*s, y: 21.3165*s))
        p.addLine(to: CGPoint(x: 11.1622*s, y: 19.3919*s))
        p.addLine(to: CGPoint(x: 11.4779*s, y: 17.8619*s))
        p.addLine(to: CGPoint(x: 11.7632*s, y: 15.9615*s))
        p.addLine(to: CGPoint(x: 11.9332*s, y: 15.3301*s))
        p.addLine(to: CGPoint(x: 11.9211*s, y: 15.2876*s))
        p.addLine(to: CGPoint(x: 11.7814*s, y: 15.3058*s))
        p.addLine(to: CGPoint(x: 10.3486*s, y: 17.2730*s))
        p.addLine(to: CGPoint(x: 8.1690*s, y: 20.2176*s))
        p.addLine(to: CGPoint(x: 6.4447*s, y: 22.0632*s))
        p.addLine(to: CGPoint(x: 6.0319*s, y: 22.2272*s))
        p.addLine(to: CGPoint(x: 5.3155*s, y: 21.8568*s))
        p.addLine(to: CGPoint(x: 5.3822*s, y: 21.1950*s))
        p.addLine(to: CGPoint(x: 5.7830*s, y: 20.6061*s))
        p.addLine(to: CGPoint(x: 8.1690*s, y: 17.5704*s))
        p.addLine(to: CGPoint(x: 9.6079*s, y: 15.6884*s))
        p.addLine(to: CGPoint(x: 10.5369*s, y: 14.6016*s))
        p.addLine(to: CGPoint(x: 10.5307*s, y: 14.4437*s))
        p.addLine(to: CGPoint(x: 10.4761*s, y: 14.4437*s))
        p.addLine(to: CGPoint(x: 4.1376*s, y: 18.5601*s))
        p.addLine(to: CGPoint(x: 3.0083*s, y: 18.7058*s))
        p.addLine(to: CGPoint(x: 2.5226*s, y: 18.2504*s))
        p.addLine(to: CGPoint(x: 2.5834*s, y: 17.5037*s))
        p.addLine(to: CGPoint(x: 2.8141*s, y: 17.2608*s))
        p.addLine(to: CGPoint(x: 4.7205*s, y: 15.9494*s))
        p.closeSubpath()
        return p
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
    var loc: ((String) -> String)? = nil

    // in/out use saturated teal & coral; cache_read/cache_write use desaturated tints of same hues
    static let typeEntries: [(String, Color, KeyPath<PeriodUsage, Int>)] = [
        ("tkIn",  Color(red: 0.10, green: 0.60, blue: 0.65), \.totalInput),      // teal
        ("tkOut", Color(red: 0.90, green: 0.40, blue: 0.30), \.totalOutput),      // coral
        ("tkCR",  Color(red: 0.55, green: 0.78, blue: 0.80), \.totalCacheRead),   // desaturated teal
        ("tkCW",  Color(red: 0.92, green: 0.70, blue: 0.62), \.totalCacheWrite),  // desaturated coral
    ]

    var body: some View {
        let l = loc ?? { i18n[.en]?[$0] ?? $0 }
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
                        Text(l(key))
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
    let loc: (String) -> String

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
    var loc: ((String) -> String)? = nil

    var body: some View {
        let l = loc ?? { i18n[.en]?[$0] ?? $0 }
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
                TokenChip(label: l("tkIn"), value: model.inputTokens, color: TokenTypeBar.typeEntries[0].1)
                TokenChip(label: l("tkOut"), value: model.outputTokens, color: TokenTypeBar.typeEntries[1].1)
                TokenChip(label: l("tkCR"), value: model.cacheRead, color: TokenTypeBar.typeEntries[2].1)
                TokenChip(label: l("tkCW"), value: model.cacheWrite, color: TokenTypeBar.typeEntries[3].1)
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

// ── Period card ──
struct PeriodCard: View {
    let icon: String
    let title: String
    let usage: PeriodUsage
    var showStats: Bool = false
    var loc: ((String) -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title + cost
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatCost(usage.cost))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // Cost proportion bar
            if !usage.models.isEmpty {
                CostBar(models: usage.models, total: usage.cost)
                    .padding(.vertical, 2)
            }

            // Model breakdown
            ForEach(usage.models.filter { $0.cost >= 0.005 }) { m in
                ModelRow(model: m)
            }

            // Stats footer (month only)
            if showStats {
                HStack(spacing: 12) {
                    Label("\(formatNumber(usage.totalMessages))", systemImage: "message")
                    Label(formatTokens(usage.totalTokens, loc), systemImage: "number")
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

// ── Period card (tokens) ──
struct TokenPeriodCard: View {
    let icon: String
    let title: String
    let usage: PeriodUsage
    var showStats: Bool = false
    var loc: ((String) -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title + total tokens
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatTokensShort(usage.totalTokens))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // Token type distribution bar (in / out / cache_r / cache_w)
            if usage.totalTokens > 0 {
                TokenTypeBar(usage: usage, loc: loc)
                    .padding(.vertical, 2)
            }

            // Model proportion bar
            if !usage.models.isEmpty {
                TokenBar(models: usage.models, total: usage.totalTokens)
                    .padding(.bottom, 2)
            }

            // Model breakdown
            ForEach(usage.models.filter { $0.totalTokens > 0 }) { m in
                TokenModelRow(model: m, loc: loc)
            }

            // Stats footer (month only)
            if showStats {
                HStack(spacing: 12) {
                    Label("\(formatNumber(usage.totalMessages))", systemImage: "message")
                    Label(formatCost(usage.cost), systemImage: "dollarsign.circle")
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
    let loc: (String) -> String

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
    let loc: (String) -> String

    var body: some View {
        VStack(spacing: 8) {
            if let q = store.subscriptionQuota {
                SubWindowRow(label: loc("sub5hLabel"),
                             usedPercent: q.five_hour.displayPercent,
                             resetAt: q.fiveHourResetDate, loc: loc)
                SubWindowRow(label: loc("sub7dLabel"),
                             usedPercent: q.seven_day.displayPercent,
                             resetAt: q.sevenDayResetDate, loc: loc)
                // Max plans expose a separate Sonnet 7-day cap. Show it only when the
                // API actually returns a bucket with activity or a reset time.
                if let sonnet = q.seven_day_sonnet,
                   sonnet.displayPercent > 0 || sonnet.resets_at != nil {
                    SubWindowRow(label: loc("sub7dSonnetLabel"),
                                 usedPercent: sonnet.displayPercent,
                                 resetAt: q.sevenDaySonnetResetDate, loc: loc)
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
                    Text(store.loc("title"))
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
                    Label(tab.label(store.loc), systemImage: tab.icon).tag(tab)
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
    }

    @ViewBuilder
    private var contentSection: some View {
            if store.selectedTab == .subscription {
                SubscriptionView(store: store, loc: store.loc)
            } else if store.isCurrentMonth {
                if let today = store.today, let week = store.week, let month = store.month {
                    VStack(spacing: 8) {
                        if store.selectedTab == .cost {
                            PeriodCard(icon: "calendar", title: store.loc("today"), usage: today)
                            PeriodCard(icon: "calendar.badge.clock", title: store.loc("thisWeek"), usage: week)
                            PeriodCard(icon: "chart.bar", title: store.loc("thisMonth"), usage: month, showStats: true, loc: store.loc)
                        } else {
                            TokenPeriodCard(icon: "calendar", title: store.loc("today"), usage: today, loc: store.loc)
                            TokenPeriodCard(icon: "calendar.badge.clock", title: store.loc("thisWeek"), usage: week, loc: store.loc)
                            TokenPeriodCard(icon: "chart.bar", title: store.loc("thisMonth"), usage: month, showStats: true, loc: store.loc)
                        }
                        if let daily = store.dailyBreakdown, !daily.isEmpty {
                            DailyChart(data: daily, mode: store.selectedTab,
                                       year: store.viewingYear, month: store.viewingMonth,
                                       loc: store.loc)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                } else if store.isLoading {
                    loadingView
                } else {
                    errorView
                }
            } else {
                if let month = store.month {
                    VStack(spacing: 8) {
                        if store.selectedTab == .cost {
                            PeriodCard(icon: "chart.bar", title: store.loc("monthlyTotal"),
                                       usage: month, showStats: true, loc: store.loc)
                        } else {
                            TokenPeriodCard(icon: "chart.bar", title: store.loc("monthlyTotal"),
                                            usage: month, showStats: true, loc: store.loc)
                        }
                        if let daily = store.dailyBreakdown, !daily.isEmpty {
                            DailyChart(data: daily, mode: store.selectedTab,
                                       year: store.viewingYear, month: store.viewingMonth,
                                       loc: store.loc)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                } else if store.isLoading {
                    loadingView
                } else {
                    noDataView
                }
            }
    }

    // ── Footer ──
    private var footer: some View {
        HStack(spacing: 12) {
                if let time = store.lastUpdate, store.isCurrentMonth {
                    Text(String(format: store.loc("updated"),
                                timeAgo(time, store.loc)))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                } else if !store.isCurrentMonth {
                    Text(store.loc("cachedData"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Language switcher
                LanguageSwitcher(store: store)

                Button(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(store.loc("refresh"))
                .keyboardShortcut("r", modifiers: .command)

                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(store.loc("quit"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(store.loc("loading"))
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
            Text(store.loc("loadFailed"))
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
            Text(store.loc("noMonthData"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }
}
