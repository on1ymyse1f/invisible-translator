import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconSetURL = root
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")
let iconSetURL = root
    .appendingPathComponent("build")
    .appendingPathComponent("AppIcon.iconset")
let resourcesURL = root.appendingPathComponent("Resources")

try FileManager.default.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

struct IconVariant {
    let points: Int
    let scale: Int

    var pixels: Int {
        points * scale
    }

    var assetFilename: String {
        "app-icon-\(points)x\(points)@\(scale)x.png"
    }

    var iconsetFilename: String {
        scale == 1
            ? "icon_\(points)x\(points).png"
            : "icon_\(points)x\(points)@2x.png"
    }
}

let variants = [
    IconVariant(points: 16, scale: 1),
    IconVariant(points: 16, scale: 2),
    IconVariant(points: 32, scale: 1),
    IconVariant(points: 32, scale: 2),
    IconVariant(points: 128, scale: 1),
    IconVariant(points: 128, scale: 2),
    IconVariant(points: 256, scale: 1),
    IconVariant(points: 256, scale: 2),
    IconVariant(points: 512, scale: 1),
    IconVariant(points: 512, scale: 2)
]

func drawIcon(size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
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
        throw NSError(domain: "IconGeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create \(size)x\(size) bitmap"])
    }

    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    guard let context = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
    let scale = CGFloat(size) / 1024.0

    context.clear(rect)
    context.saveGState()

    let cornerRadius = 228.0 * scale
    let backgroundPath = CGPath(
        roundedRect: rect.insetBy(dx: 30 * scale, dy: 30 * scale),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    context.addPath(backgroundPath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.14, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.02, green: 0.13, blue: 0.30, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.55, alpha: 1).cgColor
        ] as CFArray,
        locations: [0.0, 0.52, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 100 * scale, y: 980 * scale),
        end: CGPoint(x: 930 * scale, y: 70 * scale),
        options: []
    )

    context.setBlendMode(.screen)
    let glowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(calibratedRed: 0.13, green: 0.86, blue: 1.0, alpha: 0.38).cgColor,
            NSColor(calibratedRed: 0.13, green: 0.86, blue: 1.0, alpha: 0.0).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glowGradient,
        startCenter: CGPoint(x: 770 * scale, y: 735 * scale),
        startRadius: 20 * scale,
        endCenter: CGPoint(x: 770 * scale, y: 735 * scale),
        endRadius: 490 * scale,
        options: [.drawsAfterEndLocation]
    )
    context.setBlendMode(.normal)

    context.restoreGState()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0.32)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    shadow.set()

    let bubbleRect = CGRect(x: 185 * scale, y: 232 * scale, width: 654 * scale, height: 554 * scale)
    let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 142 * scale, yRadius: 142 * scale)
    NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.34, alpha: 0.86).setFill()
    bubblePath.fill()
    NSColor(calibratedRed: 0.30, green: 0.82, blue: 1.0, alpha: 0.36).setStroke()
    bubblePath.lineWidth = 8 * scale
    bubblePath.stroke()

    let tailPath = NSBezierPath()
    tailPath.move(to: CGPoint(x: 605 * scale, y: 245 * scale))
    tailPath.curve(
        to: CGPoint(x: 745 * scale, y: 150 * scale),
        controlPoint1: CGPoint(x: 620 * scale, y: 185 * scale),
        controlPoint2: CGPoint(x: 672 * scale, y: 150 * scale)
    )
    tailPath.curve(
        to: CGPoint(x: 680 * scale, y: 295 * scale),
        controlPoint1: CGPoint(x: 720 * scale, y: 198 * scale),
        controlPoint2: CGPoint(x: 707 * scale, y: 252 * scale)
    )
    tailPath.close()
    NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.34, alpha: 0.86).setFill()
    tailPath.fill()

    let innerGlow = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 42 * scale, dy: 42 * scale), xRadius: 104 * scale, yRadius: 104 * scale)
    NSColor(calibratedRed: 0.35, green: 0.95, blue: 1.0, alpha: 0.08).setFill()
    innerGlow.fill()

    let cursorPath = NSBezierPath(roundedRect: CGRect(x: 668 * scale, y: 398 * scale, width: 18 * scale, height: 250 * scale), xRadius: 9 * scale, yRadius: 9 * scale)
    NSColor(calibratedRed: 0.42, green: 0.91, blue: 1.0, alpha: 0.95).setFill()
    cursorPath.fill()

    let sparkPath = NSBezierPath(ovalIn: CGRect(x: 720 * scale, y: 690 * scale, width: 42 * scale, height: 42 * scale))
    NSColor(calibratedRed: 0.56, green: 0.92, blue: 1.0, alpha: 0.86).setFill()
    sparkPath.fill()

    let smallSparkPath = NSBezierPath(ovalIn: CGRect(x: 285 * scale, y: 645 * scale, width: 22 * scale, height: 22 * scale))
    NSColor(calibratedRed: 0.77, green: 0.58, blue: 1.0, alpha: 0.72).setFill()
    smallSparkPath.fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: 366 * scale, weight: .semibold)
    let textShadow = NSShadow()
    textShadow.shadowColor = NSColor(calibratedRed: 0.16, green: 0.85, blue: 1.0, alpha: 0.50)
    textShadow.shadowBlurRadius = 22 * scale
    textShadow.shadowOffset = NSSize(width: 0, height: 0)

    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.86, green: 0.98, blue: 1.0, alpha: 1.0),
        .paragraphStyle: paragraph,
        .shadow: textShadow
    ]
    let textRect = CGRect(x: 204 * scale, y: 332 * scale, width: 430 * scale, height: 372 * scale)
    NSString(string: "译").draw(in: textRect, withAttributes: textAttributes)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL, pixels: Int) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(pixels)x\(pixels) icon"])
    }
    try png.write(to: url)
}

for variant in variants {
    let bitmap = try drawIcon(size: variant.pixels)
    try writePNG(bitmap, to: appIconSetURL.appendingPathComponent(variant.assetFilename), pixels: variant.pixels)
    try writePNG(bitmap, to: iconSetURL.appendingPathComponent(variant.iconsetFilename), pixels: variant.pixels)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c",
    "icns",
    iconSetURL.path,
    "-o",
    resourcesURL.appendingPathComponent("AppIcon.icns").path
]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "IconGeneration", code: Int(iconutil.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print("Generated AppIcon.appiconset and Resources/AppIcon.icns")
