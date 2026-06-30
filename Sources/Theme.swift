import SwiftUI

// MARK: - Shared brand / status colors
//
// Single source for the few colors used in MORE than one place, so the notch and
// the popover can't drift apart (they previously hard-coded the brand orange in
// two files and rendered "a session is waiting" in two slightly different ambers).
// Per-chart palettes that live in exactly one view stay inline at their use site.
extension Color {
    /// Claude brand orange (#D97757) — the logo mark in the notch + popover header.
    static let ccBrand = Color(red: 0.851, green: 0.467, blue: 0.341)

    /// "A session is waiting for you" amber (#F2B45C) — the status dot shared by the
    /// Session row and the notch attention dot, kept identical so the two
    /// presentations of the same state can't drift.
    static let ccStatusWaiting = Color(red: 0.949, green: 0.706, blue: 0.361)
}
