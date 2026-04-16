import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let appRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resourcesURL = appRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let outputURL = resourcesURL.appendingPathComponent("AppIcon.icns")
let previewURL = resourcesURL.appendingPathComponent("AppIcon.png")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

struct IconSize {
    let points: Int
    let scale: Int
    let name: String

    var pixels: Int { points * scale }
}

let sizes: [IconSize] = [
    .init(points: 16, scale: 1, name: "icon_16x16.png"),
    .init(points: 16, scale: 2, name: "icon_16x16@2x.png"),
    .init(points: 32, scale: 1, name: "icon_32x32.png"),
    .init(points: 32, scale: 2, name: "icon_32x32@2x.png"),
    .init(points: 128, scale: 1, name: "icon_128x128.png"),
    .init(points: 128, scale: 2, name: "icon_128x128@2x.png"),
    .init(points: 256, scale: 1, name: "icon_256x256.png"),
    .init(points: 256, scale: 2, name: "icon_256x256@2x.png"),
    .init(points: 512, scale: 1, name: "icon_512x512.png"),
    .init(points: 512, scale: 2, name: "icon_512x512@2x.png"),
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func pathForArrow(from start: CGPoint, to end: CGPoint, bend: CGFloat, size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: start)
    let control = CGPoint(
        x: (start.x + end.x) / 2,
        y: (start.y + end.y) / 2 + bend
    )
    path.curve(to: end, controlPoint1: control, controlPoint2: control)
    path.lineWidth = max(2, size * 0.045)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

func drawIcon(size: Int) -> NSImage {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: dimension, height: dimension).fill()

    let iconRect = NSRect(
        x: dimension * 0.06,
        y: dimension * 0.06,
        width: dimension * 0.88,
        height: dimension * 0.88
    )
    let corner = dimension * 0.21
    let bg = NSBezierPath(roundedRect: iconRect, xRadius: corner, yRadius: corner)
    NSGradient(colors: [color(0x12A474), color(0x066D63)])?.draw(in: bg, angle: -35)

    color(0x043D39, alpha: 0.25).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: dimension * 0.13, y: dimension * 0.13, width: dimension * 0.74, height: dimension * 0.16),
        xRadius: dimension * 0.08,
        yRadius: dimension * 0.08
    ).fill()

    let panelRect = NSRect(
        x: dimension * 0.18,
        y: dimension * 0.25,
        width: dimension * 0.64,
        height: dimension * 0.53
    )
    let panel = NSBezierPath(roundedRect: panelRect, xRadius: dimension * 0.075, yRadius: dimension * 0.075)
    color(0xFFFFFF, alpha: 0.94).setFill()
    panel.fill()

    color(0x073B36, alpha: 0.15).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: panelRect.minX, y: panelRect.maxY - dimension * 0.12, width: panelRect.width, height: dimension * 0.12),
        xRadius: dimension * 0.075,
        yRadius: dimension * 0.075
    ).fill()

    let leftCenter = CGPoint(x: dimension * 0.38, y: dimension * 0.53)
    let rightCenter = CGPoint(x: dimension * 0.62, y: dimension * 0.53)
    let circleRadius = dimension * 0.105

    color(0xFF6B5F).setFill()
    NSBezierPath(ovalIn: NSRect(x: leftCenter.x - circleRadius, y: leftCenter.y - circleRadius, width: circleRadius * 2, height: circleRadius * 2)).fill()
    color(0x20BFD0).setFill()
    NSBezierPath(ovalIn: NSRect(x: rightCenter.x - circleRadius, y: rightCenter.y - circleRadius, width: circleRadius * 2, height: circleRadius * 2)).fill()

    color(0xFFFFFF, alpha: 0.94).setStroke()
    let topArrow = pathForArrow(
        from: CGPoint(x: dimension * 0.44, y: dimension * 0.66),
        to: CGPoint(x: dimension * 0.61, y: dimension * 0.66),
        bend: dimension * 0.055,
        size: dimension
    )
    topArrow.stroke()
    let bottomArrow = pathForArrow(
        from: CGPoint(x: dimension * 0.56, y: dimension * 0.40),
        to: CGPoint(x: dimension * 0.39, y: dimension * 0.40),
        bend: -dimension * 0.055,
        size: dimension
    )
    bottomArrow.stroke()

    let arrowHeadSize = dimension * 0.045
    func drawHead(_ point: CGPoint, _ direction: CGFloat) {
        let head = NSBezierPath()
        head.move(to: point)
        head.line(to: CGPoint(x: point.x - arrowHeadSize * direction, y: point.y + arrowHeadSize * 0.68))
        head.move(to: point)
        head.line(to: CGPoint(x: point.x - arrowHeadSize * direction, y: point.y - arrowHeadSize * 0.68))
        head.lineWidth = max(2, dimension * 0.045)
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }
    drawHead(CGPoint(x: dimension * 0.61, y: dimension * 0.66), 1)
    drawHead(CGPoint(x: dimension * 0.39, y: dimension * 0.40), -1)

    color(0x073B36).setStroke()
    let prompt = NSBezierPath()
    prompt.move(to: CGPoint(x: dimension * 0.28, y: dimension * 0.34))
    prompt.line(to: CGPoint(x: dimension * 0.34, y: dimension * 0.30))
    prompt.line(to: CGPoint(x: dimension * 0.28, y: dimension * 0.26))
    prompt.lineWidth = max(2, dimension * 0.035)
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.stroke()

    color(0x073B36, alpha: 0.8).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: dimension * 0.39, y: dimension * 0.255, width: dimension * 0.20, height: dimension * 0.035),
        xRadius: dimension * 0.017,
        yRadius: dimension * 0.017
    ).fill()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "CodexAuthIcon", code: 1)
    }
    try data.write(to: url)
}

for size in sizes {
    try writePNG(drawIcon(size: size.pixels), to: iconsetURL.appendingPathComponent(size.name))
}
try writePNG(drawIcon(size: 512), to: previewURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "CodexAuthIcon", code: Int(process.terminationStatus))
}

print("Generated \(outputURL.path)")
