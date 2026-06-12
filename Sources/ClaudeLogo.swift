import AppKit
import SwiftUI

// ── Claude logo path data (single source of truth) ──
//
// Official Claude logo SVG path from SimpleIcons (https://simpleicons.org/?q=claude),
// CC0 licensed, viewBox 0 0 24 24 (y axis top-down, SVG convention).
//
// Rendered in three places, all from this one command list:
//   - menu-bar template image (AppDelegate.makeClaudeIcon, NSBezierPath)
//   - popover header (Views.ClaudeLogoShape, SwiftUI Path)
//   - app icon generator (generate_icon.swift — compiled STANDALONE by build.sh
//     together with this file, so keep imports to what both contexts tolerate)
enum ClaudeLogo {
    enum Command {
        case move(CGFloat, CGFloat)
        case line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, c1x: CGFloat, c1y: CGFloat, c2x: CGFloat, c2y: CGFloat)
        case close
    }

    // Unified from three formerly-duplicated copies (Views, AppDelegate,
    // generate_icon). The old generate_icon copy had command #42 flattened to a
    // straight line where the others curve to the same endpoint; this file keeps
    // the curve. Icon output was verified byte-identical either way (the ~0.34px
    // difference quantizes away in the 90x90 ASCII grid).
    static let commands: [Command] = [
        .move(4.7144, 15.9555),
        .line(9.4318, 13.3084),
        .line(9.5108, 13.0777),
        .line(9.4318, 12.9502),
        .line(9.2011, 12.9502),
        .line(8.4118, 12.9016),
        .line(5.7162, 12.8287),
        .line(3.3787, 12.7316),
        .line(1.1141, 12.6102),
        .line(0.5434, 12.4887),
        .line(0.0091, 11.7845),
        .line(0.0637, 11.4323),
        .line(0.5434, 11.1105),
        .line(1.2294, 11.1713),
        .line(2.7473, 11.2745),
        .line(5.0240, 11.4323),
        .line(6.6754, 11.5295),
        .line(9.1222, 11.7845),
        .line(9.5108, 11.7845),
        .line(9.5654, 11.6266),
        .line(9.4318, 11.5295),
        .line(9.3286, 11.4323),
        .line(6.9730, 9.8356),
        .line(4.4230, 8.1477),
        .line(3.0874, 7.1763),
        .line(2.3649, 6.6845),
        .line(2.0006, 6.2231),
        .line(1.8428, 5.2153),
        .line(2.4985, 4.4928),
        .line(3.3788, 4.5535),
        .line(3.6034, 4.6142),
        .line(4.4959, 5.3002),
        .line(6.4023, 6.7756),
        .line(8.8916, 8.6092),
        .line(9.2559, 8.9127),
        .line(9.4016, 8.8095),
        .line(9.4198, 8.7367),
        .line(9.2558, 8.4634),
        .line(7.9019, 6.0167),
        .line(6.4569, 3.5274),
        .line(5.8134, 2.4954),
        .line(5.6434, 1.8760),
        .curve(5.5402, 1.1475, c1x: 5.5827, c1y: 1.6210, c2x: 5.5402, c2y: 1.4086),
        .line(6.2870, 0.1335),
        .line(6.6997, 0.0),
        .line(7.6954, 0.1336),
        .line(8.1144, 0.4978),
        .line(8.7336, 1.9125),
        .line(9.7354, 4.1407),
        .line(11.2897, 7.1703),
        .line(11.7450, 8.0688),
        .line(11.9879, 8.9006),
        .line(12.0789, 9.1556),
        .line(12.2368, 9.1556),
        .line(12.2368, 9.0099),
        .line(12.3643, 7.3039),
        .line(12.6011, 5.2092),
        .line(12.8318, 2.5135),
        .line(12.9107, 1.7546),
        .line(13.2871, 0.8439),
        .line(14.0339, 0.3521),
        .line(14.6167, 0.6314),
        .line(15.0964, 1.3174),
        .line(15.0296, 1.7607),
        .line(14.7443, 3.6124),
        .line(14.1857, 6.5145),
        .line(13.8214, 8.4574),
        .line(14.0339, 8.4574),
        .line(14.2768, 8.2145),
        .line(15.2603, 6.9092),
        .line(16.9117, 4.8449),
        .line(17.6403, 4.0253),
        .line(18.4903, 3.1207),
        .line(19.0367, 2.6896),
        .line(20.0688, 2.6896),
        .line(20.8278, 3.8189),
        .line(20.4878, 4.9846),
        .line(19.4253, 6.3324),
        .line(18.5449, 7.4738),
        .line(17.2821, 9.1738),
        .line(16.4928, 10.5338),
        .line(16.5657, 10.6431),
        .line(16.7539, 10.6248),
        .line(19.6074, 10.0178),
        .line(21.1495, 9.7384),
        .line(22.9891, 9.4227),
        .line(23.8209, 9.8113),
        .line(23.9119, 10.2059),
        .line(23.5841, 11.0134),
        .line(21.6171, 11.4991),
        .line(19.3099, 11.9605),
        .line(15.8735, 12.7741),
        .line(15.8310, 12.8045),
        .line(15.8796, 12.8652),
        .line(17.4278, 13.0109),
        .line(18.0896, 13.0473),
        .line(19.7106, 13.0473),
        .line(22.7281, 13.2720),
        .line(23.5173, 13.7940),
        .line(23.9909, 14.4316),
        .line(23.9119, 14.9173),
        .line(22.6977, 15.5366),
        .line(21.0584, 15.1480),
        .line(17.2334, 14.2373),
        .line(15.9221, 13.9094),
        .line(15.7399, 13.9094),
        .line(15.7399, 14.0187),
        .line(16.8328, 15.0873),
        .line(18.8363, 16.8965),
        .line(21.3438, 19.2279),
        .line(21.4713, 19.8047),
        .line(21.1495, 20.2601),
        .line(20.8095, 20.2115),
        .line(18.6056, 18.5540),
        .line(17.7556, 17.8072),
        .line(15.8310, 16.1862),
        .line(15.7035, 16.1862),
        .line(15.7035, 16.3562),
        .line(16.1467, 17.0058),
        .line(18.4903, 20.5272),
        .line(18.6117, 21.6079),
        .line(18.4417, 21.9600),
        .line(17.8346, 22.1725),
        .line(17.1667, 22.0511),
        .line(15.7946, 20.1265),
        .line(14.3800, 17.9590),
        .line(13.2386, 16.0162),
        .line(13.0989, 16.0952),
        .line(12.4249, 23.3504),
        .line(12.1093, 23.7207),
        .line(11.3807, 24.0000),
        .line(10.7736, 23.5386),
        .line(10.4518, 22.7918),
        .line(10.7736, 21.3165),
        .line(11.1622, 19.3919),
        .line(11.4779, 17.8619),
        .line(11.7632, 15.9615),
        .line(11.9332, 15.3301),
        .line(11.9211, 15.2876),
        .line(11.7814, 15.3058),
        .line(10.3486, 17.2730),
        .line(8.1690, 20.2176),
        .line(6.4447, 22.0632),
        .line(6.0319, 22.2272),
        .line(5.3155, 21.8568),
        .line(5.3822, 21.1950),
        .line(5.7830, 20.6061),
        .line(8.1690, 17.5704),
        .line(9.6079, 15.6884),
        .line(10.5369, 14.6016),
        .line(10.5307, 14.4437),
        .line(10.4761, 14.4437),
        .line(4.1376, 18.5601),
        .line(3.0083, 18.7058),
        .line(2.5226, 18.2504),
        .line(2.5834, 17.5037),
        .line(2.8141, 17.2608),
        .line(4.7205, 15.9494),
        .close,
    ]

    /// Builds an NSBezierPath, mapping every SVG-space point through `transform`
    /// (callers own the scaling and the SVG top-down → AppKit bottom-up flip).
    static func nsBezierPath(transform: (CGFloat, CGFloat) -> NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        for cmd in commands {
            switch cmd {
            case let .move(x, y):
                path.move(to: transform(x, y))
            case let .line(x, y):
                path.line(to: transform(x, y))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                path.curve(to: transform(x, y),
                           controlPoint1: transform(c1x, c1y),
                           controlPoint2: transform(c2x, c2y))
            case .close:
                path.close()
            }
        }
        return path
    }

    /// Builds a SwiftUI Path scaled by `s` points per SVG unit (SVG orientation,
    /// which matches SwiftUI's top-down coordinate space — no flip needed).
    static func swiftUIPath(scale s: CGFloat) -> SwiftUI.Path {
        var p = SwiftUI.Path()
        for cmd in commands {
            switch cmd {
            case let .move(x, y):
                p.move(to: CGPoint(x: x * s, y: y * s))
            case let .line(x, y):
                p.addLine(to: CGPoint(x: x * s, y: y * s))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                p.addCurve(to: CGPoint(x: x * s, y: y * s),
                           control1: CGPoint(x: c1x * s, y: c1y * s),
                           control2: CGPoint(x: c2x * s, y: c2y * s))
            case .close:
                p.closeSubpath()
            }
        }
        return p
    }
}
