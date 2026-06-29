// Render real SwiftUI popover views to PNGs with synthetic data, via
// ImageRenderer — so the README screenshots are pixel-faithful to the app
// (native segmented controls, real cards, real fonts). Compiled together with
// Sources/*.swift (minus main.swift) by docs/render.sh. Mock data only.
import SwiftUI
import AppKit

// ── synthetic data builders ──
func m(_ id: String, _ name: String, _ cost: Double, _ msgs: Int,
       _ i: Int, _ o: Int, _ cr: Int, _ cw: Int) -> ModelUsage {
    ModelUsage(id: id, name: name, cost: cost, messages: msgs,
               inputTokens: i, outputTokens: o, cacheRead: cr, cacheWrite: cw)
}

// scaled copies of one model mix for Today / Week / Month
func period(_ scale: Double) -> PeriodUsage {
    let models = [
        m("opus", "Opus", 196.4*scale, 612, Int(8_900_000*scale), Int(241_000*scale), Int(74_800_000*scale), Int(9_900_000*scale)),
        m("sonnet", "Sonnet", 7.1*scale, 84, Int(640_000*scale), Int(38_000*scale), Int(3_100_000*scale), Int(520_000*scale)),
        m("haiku", "Haiku", 1.3*scale, 41, Int(120_000*scale), Int(18_000*scale), Int(940_000*scale), Int(260_000*scale)),
    ]
    let cost = models.reduce(0){$0+$1.cost}
    let msgs = models.reduce(0){$0+$1.messages}
    let tk = models.reduce(0){$0+$1.totalTokens}
    return PeriodUsage(cost: cost, models: models, totalMessages: msgs, totalTokens: tk)
}

func dailyMock(year: Int, month: Int) -> [DailyUsage] {
    let vals: [Double] = [3,5,16,77,20,12,38,355,295,420,210,180,498,520,470,90,260,120,
                          180,90,60,63,46,74,37,48,215,330,233,54,290]
    return (0..<vals.count).map { i in
        let v = vals[i]
        // token fields populated too — the tokens-mode chart stacks by each
        // model's totalTokens, so zero-token models would render empty bars.
        func tk(_ s: Double) -> (Int,Int,Int,Int) {
            (Int(v*s*4_000), Int(v*s*900), Int(v*s*470_000), Int(v*s*85_000))
        }
        let o = tk(0.95), so = tk(0.04), h = tk(0.01)
        let mm = [m("opus","Opus", v*0.95, 0, o.0,o.1,o.2,o.3),
                  m("sonnet","Sonnet", v*0.04, 0, so.0,so.1,so.2,so.3),
                  m("haiku","Haiku", v*0.01, 0, h.0,h.1,h.2,h.3)]
        let tot = mm.reduce(0){$0+$1.totalTokens}
        return DailyUsage(dateString: String(format:"%04d-%02d-%02d",year,month,i+1),
                          day: i+1, cost: v, totalTokens: tot, models: mm)
    }
}

func iv(_ sh: Double, _ eh: Double, _ model: String?) -> ActiveInterval {
    ActiveInterval(startSec: Int(sh*3600), endSec: Int(eh*3600), model: model)
}
func day(_ ivs: [ActiveInterval]) -> DayTimeUsage {
    DayTimeUsage(intervals: ivs, totalSeconds: ivs.reduce(0){$0+$1.durationSeconds})
}

// Current-week dates (so the Week view, which keys off "today", finds data).
func dayKey(_ d: Date) -> String {
    let c = Calendar(identifier: .gregorian)
    let p = c.dateComponents([.year,.month,.day], from: d)
    return String(format:"%04d-%02d-%02d", p.year!, p.month!, p.day!)
}

func timeMock() -> (TimeData, [String:Int]) {
    let cal = Calendar(identifier: .gregorian)
    let today = Date()
    // Monday of this week
    let wd = cal.component(.weekday, from: today)            // 1=Sun..7=Sat
    let backToMon = (wd + 5) % 7
    let monday = cal.date(byAdding: .day, value: -backToMon, to: today)!
    let O="opus", S="sonnet", H="haiku", N:String?=nil
    let patterns: [[ActiveInterval]] = [
        [iv(9.2,10.1,O), iv(10.4,12.0,O), iv(14.1,16.3,S), iv(21.0,22.4,O)],
        [iv(8.8,9.2,H), iv(9.5,12.6,O), iv(13.5,14.0,N), iv(15.0,18.1,O), iv(20.5,21.0,S)],
        [iv(10.0,10.3,N), iv(11.0,13.2,O), iv(14.0,17.5,O), iv(22.0,23.1,S)],
        [iv(9.0,9.1,N), iv(9.6,12.0,O), iv(13.0,13.4,H), iv(14.2,19.0,O)],
        [iv(8.5,9.0,S), iv(9.3,11.5,O), iv(13.0,16.8,O), iv(17.2,17.5,N), iv(21.5,23.4,O)],
        [iv(11.0,12.5,O), iv(15.3,16.0,H)],
        [iv(20.0,20.4,S), iv(21.0,22.8,O)],
    ]
    var days: [String:DayTimeUsage] = [:]
    for i in 0..<7 {
        let d = cal.date(byAdding: .day, value: i, to: monday)!
        days[dayKey(d)] = day(patterns[i])
    }
    // Fill the rest of the current month with lighter activity for the Month view.
    let comps = cal.dateComponents([.year,.month], from: today)
    let monthStart = cal.date(from: comps)!
    let range = cal.range(of: .day, in: .month, for: today)!
    for dnum in range {
        let d = cal.date(byAdding: .day, value: dnum-1, to: monthStart)!
        let k = dayKey(d)
        if days[k] == nil {
            let r = Double((dnum*37)%11)/11.0
            if r > 0.3 {
                days[k] = day([iv(9+r*2, 11+r*4, O), iv(15+r, 16+r*2, r>0.7 ? S : O)])
            }
        }
    }
    // Year heatmap: per-day total seconds, ramping through the year, weekends light.
    var year: [String:Int] = [:]
    let y = comps.year!
    for mo in 1...12 {
        let mc = DateComponents(year: y, month: mo)
        let md = cal.date(from: mc)!
        let mr = cal.range(of: .day, in: .month, for: md)!
        for dnum in mr {
            let d = cal.date(from: DateComponents(year:y,month:mo,day:dnum))!
            if d > today { continue }
            let weekday = cal.component(.weekday, from: d)
            let weekend = (weekday==1||weekday==7)
            let base = 0.2 + 0.7*(Double(mo)/12.0)
            let noise = Double((dnum*53+mo*17)%100)/100.0
            var hrs = base*noise*(weekend ? 0.4 : 1.0)*8
            if mo < 4 { hrs *= 0.3 }
            year[dayKey(d)] = Int(hrs*3600)
        }
    }
    return (TimeData(gapMinutes: 10, days: days), year)
}

@MainActor
func makeStore(tab: DisplayTab, range: TimeRange = .week) -> UsageStore {
    let s = UsageStore()
    let cal = Calendar(identifier: .gregorian)
    let now = cal.dateComponents([.year,.month], from: Date())
    s.language = .en
    s.isLoading = false
    s.hasOAuthToken = true
    s.selectedTab = tab
    s.viewingYear = now.year!
    s.viewingMonth = now.month!
    s.viewingTimeYear = now.year!
    s.today = period(0.12)
    s.week = period(0.7)
    s.month = period(1.0)
    s.currentMonthData = s.month
    s.dailyBreakdown = dailyMock(year: now.year!, month: now.month!)
    s.lastUpdate = Date()
    let (td, year) = timeMock()
    s.currentTimeData = td
    s.viewingTimeData = td
    s.yearTimeDays = year
    s.timeRange = range
    s.subscriptionQuota = OAuthUsage(
        five_hour: OAuthUsageWindow(utilization: 62, resets_at: nil),
        seven_day: OAuthUsageWindow(utilization: 38, resets_at: nil),
        extra_usage: nil, seven_day_sonnet: OAuthUsageWindow(utilization: 81, resets_at: nil))
    return s
}

// macOS-style segmented control replica. The real app uses `.pickerStyle(.segmented)`
// (an NSSegmentedControl), which ImageRenderer cannot rasterize off-screen — this
// SwiftUI replica matches its look so the screenshots stay faithful.
struct SegmentedBar: View {
    let items: [(label: String, icon: String?)]
    let selected: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 4) {
                    if let ic = it.icon {
                        Image(systemName: ic).font(.system(size: 11, weight: .regular))
                    }
                    Text(it.label).font(.system(size: 12.5, weight: i == selected ? .semibold : .regular))
                }
                .foregroundColor(i == selected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == selected ? Color(nsColor: .controlColor) : .clear)
                        .shadow(color: .black.opacity(i == selected ? 0.12 : 0), radius: 1, y: 0.5)
                        .padding(1.5)
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}

// Replica of YearHeatmap: the real one's .onAppear calls loadYearTime (which
// nils yearTimeDays into a loading state and would need the private per-year
// cache to serve mock data) and its nav uses NSButton-backed Buttons. This
// reuses the REAL YearHeatmap.levelColor + TimeLogic grid math (identical
// colors/layout), takes mock days directly, and uses plain (renderable) arrows.
struct DemoYearHeatmap: View {
    let year: Int
    let days: [String: Int]
    let loc: Localizer
    private let cell: CGFloat = 7, sp: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading).foregroundColor(.primary)
                Spacer()
                Text(String(year)).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing).foregroundColor(.primary).opacity(0.3)
            }
            Color.clear.frame(height: 12)  // hover-strip spacer (matches real layout)
            let startMonday = TimeLogic.yearGridStartMonday(year: year)
            let yearPrefix = String(format: "%04d-", year)
            VStack(alignment: .leading, spacing: sp) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: sp) {
                        ForEach(0..<53, id: \.self) { col in
                            let key = startMonday.flatMap { TimeLogic.dayKey(col: col, row: row, startMonday: $0) }
                            if let key = key, key.hasPrefix(yearPrefix) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(YearHeatmap.levelColor(TimeLogic.heatLevel(days[key] ?? 0), dark: false))
                                    .frame(width: cell, height: cell)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer()
                Text(loc("timeLess")).font(.system(size: 8)).foregroundColor(.secondary)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(YearHeatmap.levelColor(l, dark: false)).frame(width: cell, height: cell)
                }
                Text(loc("timeMore")).font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}

// Replica of TimeTabView using the SegmentedBar (the real one's native Picker
// can't render off-screen) + the REAL week/month charts and a faithful year
// heatmap.
struct DemoTimeTab: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer
    var body: some View {
        VStack(spacing: 8) {
            SegmentedBar(items: TimeRange.allCases.map { ($0.label(loc), nil) },
                         selected: store.timeRange.rawValue)
            switch store.timeRange {
            case .week:  WeekTimeChart(store: store, timeData: store.viewingTimeData!)
            case .month: MonthTimeChart(timeData: store.viewingTimeData!,
                                        year: store.viewingYear, month: store.viewingMonth)
            case .year:  DemoYearHeatmap(year: store.viewingTimeYear,
                                         days: store.yearTimeDays ?? [:], loc: loc)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .environment(\.localizer, loc)
    }
}

// Faithful reproduction of PopoverView chrome (header / month-nav / segmented
// tabs / content / footer), minus the dynamic-height ScrollView and the
// NSViewRepresentable language button — so ImageRenderer gets a clean,
// naturally-sized layout. Content uses the REAL cards/charts.
struct DemoPopover: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer
    /// Panel background. Default = the menu-bar popover material; the notch demo passes
    /// `.clear` so its own black layer shows through.
    var bg: Color = Color(nsColor: .windowBackgroundColor)
    /// In the notch we use the app's REAL custom segmented control (pure SwiftUI, so it
    /// rasterizes); the menu-bar shots keep the native-look SegmentedBar replica.
    var notch: Bool = false
    private var visibleTabs: [DisplayTab] { [.cost, .tokens, .time, .subscription] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ClaudeLogoShape().fill(Color(red:0.851,green:0.467,blue:0.341))
                    .frame(width: 14, height: 14)
                Text(loc("title")).font(.system(size: 13, weight: .bold)).foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            HStack {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28, alignment: .leading).foregroundColor(.primary)
                Spacer()
                Text(store.viewingMonthLabel).font(.system(size: 14, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28, alignment: .trailing).foregroundColor(.primary).opacity(0.3)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)

            Group {
                if notch {
                    TabSelector(isNotch: true, items: visibleTabs,
                                selection: $store.selectedTab, label: { $0.label(loc) })
                } else {
                    SegmentedBar(items: visibleTabs.map { ($0.label(loc), $0.icon) },
                                 selected: visibleTabs.firstIndex(of: store.selectedTab) ?? 0)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)

            content

            Divider().padding(.horizontal, 10)

            HStack(spacing: 12) {
                Text(String(format: loc("updated"), loc("justNow")))
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
                Spacer()
                Image(systemName: "globe").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "power").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: store.selectedTab == .time ? 480 : 360)
        .background(bg)
        .environment(\.localizer, loc)
    }

    @ViewBuilder private var content: some View {
        if store.selectedTab == .time {
            DemoTimeTab(store: store, loc: loc)
        } else if store.selectedTab == .subscription {
            SubscriptionView(store: store)
        } else {
            VStack(spacing: 8) {
                PeriodCard(metric: store.selectedTab, icon: "calendar", title: loc("today"), usage: store.today!)
                PeriodCard(metric: store.selectedTab, icon: "calendar.badge.clock", title: loc("thisWeek"), usage: store.week!)
                PeriodCard(metric: store.selectedTab, icon: "chart.bar", title: loc("thisMonth"), usage: store.month!, showStats: true)
                DailyChart(data: store.dailyBreakdown!, mode: store.selectedTab, year: store.viewingYear, month: store.viewingMonth)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
    }
}

// The notch experience: the expanded popover dropping straight out of the display notch
// at the top-center of the screen, interrupting the menu bar. ONE black element flush
// with the top edge (not a floating blob). Reuses the REAL NotchShape + the dark popover
// (custom segmented control, black layer) the app draws in the notch.
struct DemoNotch: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    private let menuBarHeight: CGFloat = 28

    private var wallpaper: some View {
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.12, blue: 0.30),
                     Color(red: 0.42, green: 0.20, blue: 0.46),
                     Color(red: 0.86, green: 0.46, blue: 0.35)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Faint menu bar of the FOREGROUND app, so the black panel reads as the NOTCH
    // interrupting the top of the screen (not a card floating in space). The popover
    // covers its center (where the physical notch is).
    private var menuBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "apple.logo")
            Text("Terminal").fontWeight(.semibold)
            Spacer()
            Image(systemName: "battery.100")
            Image(systemName: "wifi")
            Text("Wed 16:30")
        }
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .frame(height: menuBarHeight)
        .background(Color.black.opacity(0.22))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            // The notch panel: flush with the very top edge, hanging down. Its top band
            // (the camera strip) overlaps the menu bar; the "CC Monitor" header sits
            // clearly below the bar. Margins mirror NotchRootView so the popover floats
            // inside the black instead of running edge-to-edge (hMargin 18, bottom 14).
            DemoPopover(store: store, loc: loc, bg: .clear, notch: true)
                .padding(.horizontal, 18)
                .padding(.top, menuBarHeight)   // header lands a row below the menu bar
                .padding(.bottom, 14)
                .background(Color.black)
                .clipShape(NotchShape(topCornerRadius: 10, bottomCornerRadius: 22))
                .environment(\.colorScheme, .dark)
        }
        .frame(width: 720, height: 772)
    }
}

@MainActor
func render(_ name: String, _ view: some View, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let img = r.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("FAILED \(name)"); return
    }
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        .appendingPathComponent("\(name).png")
    try? png.write(to: out)
    print("wrote \(name).png \(Int(img.size.width))x\(Int(img.size.height))")
}

@main
struct RenderApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let loc = Localizer(language: .en)
        render("cost", DemoPopover(store: makeStore(tab: .cost), loc: loc))
        render("tokens", DemoPopover(store: makeStore(tab: .tokens), loc: loc))
        render("plan", DemoPopover(store: makeStore(tab: .subscription), loc: loc))
        render("time-week", DemoPopover(store: makeStore(tab: .time, range: .week), loc: loc))
        render("time-month", DemoPopover(store: makeStore(tab: .time, range: .month), loc: loc))
        render("time-year", DemoPopover(store: makeStore(tab: .time, range: .year), loc: loc))
        render("notch", DemoNotch(store: makeStore(tab: .cost), loc: loc))
    }
}
