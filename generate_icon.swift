import Cocoa

// Generate CCCostMonitor app icon: Claude logo rendered with ASCII character texture
// Logo shape filled with colored ASCII chars, background filled with faint ASCII chars

// ── Render Claude logo to a mask bitmap (1.0 = inside logo, 0.0 = outside) ──

func renderLogoMask(size: Int) -> [[Double]] {
    let s = CGFloat(size)
    let padding = s * 0.22
    let logoArea = s - padding * 2
    let scale = logoArea / 24.0

    func p(_ x: Double, _ y: Double) -> NSPoint {
        NSPoint(x: padding + x * scale, y: padding + (24.0 - y) * scale)
    }

    // Use NSBitmapImageRep directly to avoid Retina 2x backing scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    let path = NSBezierPath()
    path.move(to: p(4.7144, 15.9555))
    path.line(to: p(9.4318, 13.3084))
    path.line(to: p(9.5108, 13.0777))
    path.line(to: p(9.4318, 12.9502))
    path.line(to: p(9.2011, 12.9502))
    path.line(to: p(8.4118, 12.9016))
    path.line(to: p(5.7162, 12.8287))
    path.line(to: p(3.3787, 12.7316))
    path.line(to: p(1.1141, 12.6102))
    path.line(to: p(0.5434, 12.4887))
    path.line(to: p(0.0091, 11.7845))
    path.line(to: p(0.0637, 11.4323))
    path.line(to: p(0.5434, 11.1105))
    path.line(to: p(1.2294, 11.1713))
    path.line(to: p(2.7473, 11.2745))
    path.line(to: p(5.0240, 11.4323))
    path.line(to: p(6.6754, 11.5295))
    path.line(to: p(9.1222, 11.7845))
    path.line(to: p(9.5108, 11.7845))
    path.line(to: p(9.5654, 11.6266))
    path.line(to: p(9.4318, 11.5295))
    path.line(to: p(9.3286, 11.4323))
    path.line(to: p(6.9730, 9.8356))
    path.line(to: p(4.4230, 8.1477))
    path.line(to: p(3.0874, 7.1763))
    path.line(to: p(2.3649, 6.6845))
    path.line(to: p(2.0006, 6.2231))
    path.line(to: p(1.8428, 5.2153))
    path.line(to: p(2.4985, 4.4928))
    path.line(to: p(3.3788, 4.5535))
    path.line(to: p(3.6034, 4.6142))
    path.line(to: p(4.4959, 5.3002))
    path.line(to: p(6.4023, 6.7756))
    path.line(to: p(8.8916, 8.6092))
    path.line(to: p(9.2559, 8.9127))
    path.line(to: p(9.4016, 8.8095))
    path.line(to: p(9.4198, 8.7367))
    path.line(to: p(9.2558, 8.4634))
    path.line(to: p(7.9019, 6.0167))
    path.line(to: p(6.4569, 3.5274))
    path.line(to: p(5.8134, 2.4954))
    path.line(to: p(5.6434, 1.8760))
    path.line(to: p(5.5402, 1.1475))
    path.line(to: p(6.2870, 0.1335))
    path.line(to: p(6.6997, 0.0))
    path.line(to: p(7.6954, 0.1336))
    path.line(to: p(8.1144, 0.4978))
    path.line(to: p(8.7336, 1.9125))
    path.line(to: p(9.7354, 4.1407))
    path.line(to: p(11.2897, 7.1703))
    path.line(to: p(11.7450, 8.0688))
    path.line(to: p(11.9879, 8.9006))
    path.line(to: p(12.0789, 9.1556))
    path.line(to: p(12.2368, 9.1556))
    path.line(to: p(12.2368, 9.0099))
    path.line(to: p(12.3643, 7.3039))
    path.line(to: p(12.6011, 5.2092))
    path.line(to: p(12.8318, 2.5135))
    path.line(to: p(12.9107, 1.7546))
    path.line(to: p(13.2871, 0.8439))
    path.line(to: p(14.0339, 0.3521))
    path.line(to: p(14.6167, 0.6314))
    path.line(to: p(15.0964, 1.3174))
    path.line(to: p(15.0296, 1.7607))
    path.line(to: p(14.7443, 3.6124))
    path.line(to: p(14.1857, 6.5145))
    path.line(to: p(13.8214, 8.4574))
    path.line(to: p(14.0339, 8.4574))
    path.line(to: p(14.2768, 8.2145))
    path.line(to: p(15.2603, 6.9092))
    path.line(to: p(16.9117, 4.8449))
    path.line(to: p(17.6403, 4.0253))
    path.line(to: p(18.4903, 3.1207))
    path.line(to: p(19.0367, 2.6896))
    path.line(to: p(20.0688, 2.6896))
    path.line(to: p(20.8278, 3.8189))
    path.line(to: p(20.4878, 4.9846))
    path.line(to: p(19.4253, 6.3324))
    path.line(to: p(18.5449, 7.4738))
    path.line(to: p(17.2821, 9.1738))
    path.line(to: p(16.4928, 10.5338))
    path.line(to: p(16.5657, 10.6431))
    path.line(to: p(16.7539, 10.6248))
    path.line(to: p(19.6074, 10.0178))
    path.line(to: p(21.1495, 9.7384))
    path.line(to: p(22.9891, 9.4227))
    path.line(to: p(23.8209, 9.8113))
    path.line(to: p(23.9119, 10.2059))
    path.line(to: p(23.5841, 11.0134))
    path.line(to: p(21.6171, 11.4991))
    path.line(to: p(19.3099, 11.9605))
    path.line(to: p(15.8735, 12.7741))
    path.line(to: p(15.8310, 12.8045))
    path.line(to: p(15.8796, 12.8652))
    path.line(to: p(17.4278, 13.0109))
    path.line(to: p(18.0896, 13.0473))
    path.line(to: p(19.7106, 13.0473))
    path.line(to: p(22.7281, 13.2720))
    path.line(to: p(23.5173, 13.7940))
    path.line(to: p(23.9909, 14.4316))
    path.line(to: p(23.9119, 14.9173))
    path.line(to: p(22.6977, 15.5366))
    path.line(to: p(21.0584, 15.1480))
    path.line(to: p(17.2334, 14.2373))
    path.line(to: p(15.9221, 13.9094))
    path.line(to: p(15.7399, 13.9094))
    path.line(to: p(15.7399, 14.0187))
    path.line(to: p(16.8328, 15.0873))
    path.line(to: p(18.8363, 16.8965))
    path.line(to: p(21.3438, 19.2279))
    path.line(to: p(21.4713, 19.8047))
    path.line(to: p(21.1495, 20.2601))
    path.line(to: p(20.8095, 20.2115))
    path.line(to: p(18.6056, 18.5540))
    path.line(to: p(17.7556, 17.8072))
    path.line(to: p(15.8310, 16.1862))
    path.line(to: p(15.7035, 16.1862))
    path.line(to: p(15.7035, 16.3562))
    path.line(to: p(16.1467, 17.0058))
    path.line(to: p(18.4903, 20.5272))
    path.line(to: p(18.6117, 21.6079))
    path.line(to: p(18.4417, 21.9600))
    path.line(to: p(17.8346, 22.1725))
    path.line(to: p(17.1667, 22.0511))
    path.line(to: p(15.7946, 20.1265))
    path.line(to: p(14.3800, 17.9590))
    path.line(to: p(13.2386, 16.0162))
    path.line(to: p(13.0989, 16.0952))
    path.line(to: p(12.4249, 23.3504))
    path.line(to: p(12.1093, 23.7207))
    path.line(to: p(11.3807, 24.0000))
    path.line(to: p(10.7736, 23.5386))
    path.line(to: p(10.4518, 22.7918))
    path.line(to: p(10.7736, 21.3165))
    path.line(to: p(11.1622, 19.3919))
    path.line(to: p(11.4779, 17.8619))
    path.line(to: p(11.7632, 15.9615))
    path.line(to: p(11.9332, 15.3301))
    path.line(to: p(11.9211, 15.2876))
    path.line(to: p(11.7814, 15.3058))
    path.line(to: p(10.3486, 17.2730))
    path.line(to: p(8.1690, 20.2176))
    path.line(to: p(6.4447, 22.0632))
    path.line(to: p(6.0319, 22.2272))
    path.line(to: p(5.3155, 21.8568))
    path.line(to: p(5.3822, 21.1950))
    path.line(to: p(5.7830, 20.6061))
    path.line(to: p(8.1690, 17.5704))
    path.line(to: p(9.6079, 15.6884))
    path.line(to: p(10.5369, 14.6016))
    path.line(to: p(10.5307, 14.4437))
    path.line(to: p(10.4761, 14.4437))
    path.line(to: p(4.1376, 18.5601))
    path.line(to: p(3.0083, 18.7058))
    path.line(to: p(2.5226, 18.2504))
    path.line(to: p(2.5834, 17.5037))
    path.line(to: p(2.8141, 17.2608))
    path.line(to: p(4.7205, 15.9494))
    path.close()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    var mask = Array(repeating: Array(repeating: 0.0, count: size), count: size)
    for y in 0..<size {
        for x in 0..<size {
            let c = rep.colorAt(x: x, y: y) ?? NSColor.white
            let brightness = c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114
            mask[y][x] = brightness < 0.5 ? 1.0 : 0.0  // 1.0 = inside logo
        }
    }
    return mask
}

// ── Render icon with ASCII character texture ──

func renderIcon(outputSize: Int) -> NSImage {
    let s = CGFloat(outputSize)
    let maskSize = 512
    let mask = renderLogoMask(size: maskSize)

    // ASCII character grid parameters
    let font = NSFont(name: "Menlo-Bold", size: s * 0.018)
        ?? NSFont.monospacedSystemFont(ofSize: s * 0.018, weight: .bold)
    let sampleAttrs: [NSAttributedString.Key: Any] = [.font: font]
    let charSize = "W".size(withAttributes: sampleAttrs)
    let cols = Int(s / charSize.width)
    let rows = Int(s / charSize.height)

    // Pseudo-random but deterministic character selection
    let asciiChars = Array("@#$%&*+=~?/\\|{}[]()<>!^;:.,`'\"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    func charAt(_ row: Int, _ col: Int) -> Character {
        let hash = (row &* 7919) &+ (col &* 6271) &+ 3571
        return asciiChars[abs(hash) % asciiChars.count]
    }

    // Colors
    let logoColor = NSColor(red: 0.82, green: 0.42, blue: 0.22, alpha: 1.0)   // terracotta
    let bgCharColor = NSColor(white: 0.88, alpha: 1.0)                         // faint gray

    // Use NSBitmapImageRep directly to avoid Retina 2x backing scale
    let iconRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: outputSize, pixelsHigh: outputSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    iconRep.size = NSSize(width: outputSize, height: outputSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: iconRep)!

    // ── Squircle clip ──
    let radius = s * 0.2237
    let squircle = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                                 xRadius: radius, yRadius: radius)
    squircle.addClip()

    // ── Background ──
    NSColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1.0).setFill()
    squircle.fill()

    // ── Draw ASCII character grid ──
    for row in 0..<rows {
        for col in 0..<cols {
            let x = CGFloat(col) * charSize.width
            let y = s - CGFloat(row + 1) * charSize.height  // flip y for AppKit

            // Sample the mask to determine if this cell is inside the logo
            let maskX = Int(CGFloat(col) / CGFloat(cols) * CGFloat(maskSize))
            let maskY = Int(CGFloat(row) / CGFloat(rows) * CGFloat(maskSize))
            let mx = min(max(maskX, 0), maskSize - 1)
            let my = min(max(maskY, 0), maskSize - 1)
            let insideLogo = mask[my][mx] > 0.5

            let color = insideLogo ? logoColor : bgCharColor
            let ch = String(charAt(row, col))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            ch.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    // ── Subtle border ──
    NSColor(white: 0.82, alpha: 1.0).setStroke()
    squircle.lineWidth = s * 0.003
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: NSSize(width: outputSize, height: outputSize))
    img.addRepresentation(iconRep)
    return img
}

// ── Save as PNG ──

func saveAsPNG(_ image: NSImage, to url: URL, size: Int) {
    // Use NSBitmapImageRep directly to avoid Retina 2x backing scale issues
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)  // 1:1 point-to-pixel

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

// ── Main ──

let icon = renderIcon(outputSize: 1024)

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (name, px) in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
] as [(String, Int)] {
    saveAsPNG(icon, to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(name), size: px)
}
print("Generated ASCII-textured icon in \(iconsetPath)")
