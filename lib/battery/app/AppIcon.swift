// AppIcon.swift — draws lib/battery/app/AppIcon.png, the BatteryBar app icon,
// in the style of the MonitorBar and VoxBar icons: a rounded square with a
// gradient, a white object, a dark screen inside, mint details.
// Not part of the app build. Run it again after a change:
//   swift lib/battery/app/AppIcon.swift lib/battery/app/AppIcon.png

import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// The palette of the other two icons; only the background hue is new.
let white = color(0xF1F5FB)
let mint = color(0x55EBB9)
let screenTop = color(0x232B47), screenBottom = color(0x10131D)
let backgroundTop = color(0x2BC4B0), backgroundBottom = color(0x0B6B6E)

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
NSGraphicsContext.current = context

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func withShadow(blur: CGFloat, offset: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// Background: the macOS icon grid, an 824 px square with a soft drop shadow.
let tile = rounded(NSRect(x: 100, y: 100, width: 824, height: 824), 185)
withShadow(blur: 28, offset: 12, alpha: 0.3) { white.setFill(); tile.fill() }
NSGradient(starting: backgroundTop, ending: backgroundBottom)!.draw(in: tile, angle: -90)

// Battery body: a white frame around a dark screen, and the terminal on the right.
let body = NSRect(x: 196, y: 332, width: 576, height: 360)
let terminal = rounded(NSRect(x: body.maxX + 6, y: body.midY - 68, width: 58, height: 136), 26)
withShadow(blur: 20, offset: 8, alpha: 0.25) {
    white.setFill()
    rounded(body, 64).fill()
    terminal.fill()
}
let screen = rounded(body.insetBy(dx: 28, dy: 28), 40)
NSGradient(starting: screenTop, ending: screenBottom)!.draw(in: screen, angle: -90)

// Charge: three mint bars, like the level bars of the VoxBar microphone.
let bars = body.insetBy(dx: 72, dy: 72)
let gap: CGFloat = 36
let barWidth = (bars.width - 2 * gap) / 3
mint.setFill()
for index in 0..<3 {
    let x = bars.minX + CGFloat(index) * (barWidth + gap)
    rounded(NSRect(x: x, y: bars.minY, width: barWidth, height: bars.height), 28).fill()
}

NSGraphicsContext.current = nil
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("no png") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
