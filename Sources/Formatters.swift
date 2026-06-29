import Foundation

// MARK: - Helpers

func formatCost(_ value: Double) -> String {
    if value >= 100 { return String(format: "$%.0f", value) }
    if value >= 10  { return String(format: "$%.1f", value) }
    return String(format: "$%.2f", value)
}

func formatTokens(_ count: Int, _ loc: Localizer) -> String {
    if count >= 1_000_000 { return String(format: loc("mTokens"), Double(count) / 1_000_000) }
    if count >= 1_000     { return String(format: loc("kTokens"), Double(count) / 1_000) }
    return String(format: loc("nTokens"), count)
}

func formatTokensShort(_ count: Int) -> String {
    if count >= 1_000_000_000 { return String(format: "%.1fb", Double(count) / 1_000_000_000) }
    if count >= 1_000_000 { return String(format: "%.1fm", Double(count) / 1_000_000) }
    if count >= 1_000     { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}

func formatNumber(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func timeAgo(_ date: Date, _ loc: Localizer) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60    { return loc("justNow") }
    if seconds < 3600  { return String(format: loc("mAgo"), seconds / 60) }
    if seconds < 86400 { return String(format: loc("hAgo"), seconds / 3600) }
    return String(format: loc("dAgo"), seconds / 86400)
}
