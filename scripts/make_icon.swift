import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make_icon.swift <iconset-path>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "QuotaGlassIcon", code: 1)
    }

    rep.size = NSSize(width: size, height: size)
    let side = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "QuotaGlassIcon", code: 2)
    }
    NSGraphicsContext.current = nsContext
    let context = nsContext.cgContext
    context.clear(rect)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let iconRect = rect.insetBy(dx: side * 0.055, dy: side * 0.055)
    let iconPath = roundedRect(iconRect, side * 0.225)
    context.addPath(iconPath)
    context.clip()

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            color(6, 13, 11).copy(alpha: 1)!,
            color(30, 53, 39).copy(alpha: 1)!,
            color(53, 83, 64).copy(alpha: 1)!,
        ] as CFArray,
        locations: [0, 0.58, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: side * 0.15, y: side * 0.05),
        end: CGPoint(x: side * 0.9, y: side * 0.95),
        options: []
    )

    context.setFillColor(color(255, 255, 255, 0.09))
    context.addPath(roundedRect(iconRect.insetBy(dx: side * 0.105, dy: side * 0.115), side * 0.16))
    context.fillPath()

    context.setStrokeColor(color(255, 255, 255, 0.32))
    context.setLineWidth(max(1, side * 0.014))
    context.addPath(roundedRect(iconRect.insetBy(dx: side * 0.018, dy: side * 0.018), side * 0.205))
    context.strokePath()

    context.setFillColor(color(217, 119, 87))
    context.addEllipse(in: CGRect(x: side * 0.68, y: side * 0.66, width: side * 0.13, height: side * 0.13))
    context.fillPath()

    context.setStrokeColor(color(255, 255, 255))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(side * 0.074)
    context.strokeEllipse(in: CGRect(x: side * 0.285, y: side * 0.345, width: side * 0.39, height: side * 0.39))
    context.move(to: CGPoint(x: side * 0.61, y: side * 0.39))
    context.addLine(to: CGPoint(x: side * 0.75, y: side * 0.25))
    context.strokePath()

    context.setLineWidth(side * 0.035)
    context.setStrokeColor(color(255, 255, 255, 0.86))
    for (index, width) in [0.47, 0.35, 0.24].enumerated() {
        let y = side * (0.22 - CGFloat(index) * 0.065)
        context.move(to: CGPoint(x: side * 0.27, y: y))
        context.addLine(to: CGPoint(x: side * (0.27 + width), y: y))
        context.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "QuotaGlassIcon", code: 3)
    }
    return data
}

for (filename, size) in specs {
    let data = try drawIcon(size: size)
    try data.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
}
