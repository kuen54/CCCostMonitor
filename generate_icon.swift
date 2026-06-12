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

    // Claude logo path data shared with the app (Sources/ClaudeLogo.swift —
    // build.sh compiles it into this standalone tool alongside this file).
    let path = ClaudeLogo.nsBezierPath { x, y in p(x, y) }
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
// Wrapped in @main (not top-level statements) because build.sh compiles this file
// together with Sources/ClaudeLogo.swift — in a multi-file swiftc invocation only
// a file literally named main.swift may contain top-level code.

@main
enum GenerateIcon {
    static func main() {
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
    }
}
