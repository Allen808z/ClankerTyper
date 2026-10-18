// Draws this project's own app icon (blue rounded square, white cursor-zigzag glyph).
// Usage: swift scripts/make-icon.swift <output.png> [size]
import AppKit

let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "AppIcon.png"
let size = args.count > 2 ? Double(args[2]) ?? 1024 : 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius = size * 0.2237
let plate = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: radius, yRadius: radius)
NSGradient(colors: [
    NSColor(calibratedRed: 0.30, green: 0.58, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.27, blue: 0.86, alpha: 1),
])!.draw(in: plate, angle: -90)

// Cursor-like arrow with a tail, drawn in white.
let s = size
let glyph = NSBezierPath()
glyph.move(to: NSPoint(x: s * 0.36, y: s * 0.62))
glyph.line(to: NSPoint(x: s * 0.56, y: s * 0.36))
glyph.line(to: NSPoint(x: s * 0.68, y: s * 0.52))
glyph.line(to: NSPoint(x: s * 0.76, y: s * 0.40))
glyph.lineWidth = s * 0.07
glyph.lineCapStyle = .round
glyph.lineJoinStyle = .round
NSColor.white.setStroke()
glyph.stroke()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
