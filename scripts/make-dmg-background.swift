// Draws the disk image window background: an arrow from the app icon to the Applications folder.
// Usage: swift scripts/make-dmg-background.swift <out-dir>   (writes bg.png and bg@2x.png)
// Icon centers must match icon_locations in scripts/dmg-settings.py.
import AppKit

let size = NSSize(width: 640, height: 400)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Arrow between the icons (centers at x 160 and 480, y 190 from the top).
    let y = size.height - 180
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y))
    arrow.line(to: NSPoint(x: 366, y: y))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    NSColor(white: 0.62, alpha: 1).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: y))
    head.line(to: NSPoint(x: 360, y: y + 16))
    head.line(to: NSPoint(x: 360, y: y - 16))
    head.close()
    NSColor(white: 0.62, alpha: 1).setFill()
    head.fill()

    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let caption = NSAttributedString(string: "Double-click LocalFlow to install, or drag it to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 0.35, alpha: 1),
        .paragraphStyle: para,
    ])
    caption.draw(in: NSRect(x: 0, y: 52, width: size.width, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: "\(outDir)/bg.png")
render(scale: 2, to: "\(outDir)/bg@2x.png")
