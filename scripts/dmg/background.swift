import AppKit

// A Retina background sized in points to match the Finder window.
let size = NSSize(width: 640, height: 420)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 840,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let ink = NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.18, alpha: 1)
let muted = NSColor(calibratedRed: 0.40, green: 0.44, blue: 0.42, alpha: 1)
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 28, y: y, width: 584, height: 52), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: style
    ])
}
text("Make room for your voice.", y: 328, size: 28, weight: .semibold, color: ink)
text("Drag Omil to Applications to install.", y: 290, size: 15, weight: .regular, color: muted)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 285, y: 205))
arrow.line(to: NSPoint(x: 355, y: 205))
arrow.move(to: NSPoint(x: 343, y: 217))
arrow.line(to: NSPoint(x: 355, y: 205))
arrow.line(to: NSPoint(x: 343, y: 193))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
muted.setStroke()
arrow.stroke()
text("Then eject this disk and open Omil from Applications.", y: 44, size: 13, weight: .regular, color: muted)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
