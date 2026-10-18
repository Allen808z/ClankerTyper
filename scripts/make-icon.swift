// Draws ClankerTyper's app icon: sound bars flowing into a text cursor (voice becomes text)
// on a blue rounded square, following the macOS icon grid (824 pt body on a 1024 pt canvas).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create the drawing surface")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// Body: rounded square with a soft drop shadow, like other Mac app icons.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let plate = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(calibratedRed: 0.18, green: 0.36, blue: 0.92, alpha: 1).setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [
    NSColor(calibratedRed: 0.40, green: 0.62, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.15, green: 0.33, blue: 0.90, alpha: 1),
])!.draw(in: plate, angle: -90)

// Glyph: four sound bars, then a text cursor (I-beam), centered as one group.
NSColor.white.setFill()
let barWidth: CGFloat = 58
let gap: CGFloat = 34
let barHeights: [CGFloat] = [170, 310, 430, 250]
let caretGap: CGFloat = 70
let caretStem: CGFloat = 42
let caretHeight: CGFloat = 470
let caretSerif: CGFloat = 130

let barsWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
let groupWidth = barsWidth + caretGap + caretSerif
var x = (CGFloat(size) - groupWidth) / 2
let centerY = CGFloat(size) / 2

for height in barHeights {
    let bar = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

let caretCenter = x - gap + caretGap + caretSerif / 2
let stem = NSRect(x: caretCenter - caretStem / 2, y: centerY - caretHeight / 2, width: caretStem, height: caretHeight)
NSBezierPath(roundedRect: stem, xRadius: caretStem / 2, yRadius: caretStem / 2).fill()
for y in [centerY + caretHeight / 2 - caretStem, centerY - caretHeight / 2] {
    let serif = NSRect(x: caretCenter - caretSerif / 2, y: y, width: caretSerif, height: caretStem)
    NSBezierPath(roundedRect: serif, xRadius: caretStem / 2, yRadius: caretStem / 2).fill()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode the icon") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
