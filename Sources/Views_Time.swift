import SwiftUI
import AppKit

// Time tab + its Week / Month / Year charts.
// Extracted from the former single-file Views.swift (v3.0.2 split; no behavior change).

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
        TimeLogic.renderedDayKeys(dayKeys, monthPrefix: monthPrefix, days: timeData.days)
    }
    private var todayKey: String { AppDate.dayKey(Date()) }
    private var weekTotal: Int {
        TimeLogic.totalSeconds(in: timeData.days, dayKeys: renderedDayKeys)
    }
    /// Daily-avg divisor: the week containing today averages over elapsed days
    /// Mon..today (a Tuesday isn't averaged over 7 days); a fully past week
    /// over the days that rendered data (min 1); a future week renders 0s.
    private var avgDivisor: Int {
        TimeLogic.avgDivisor(dayKeys: dayKeys, todayKey: todayKey, renderedCount: renderedDayKeys.count)
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

