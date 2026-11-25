// Draws the app icon: a four-switch pedal with a lit screen (PLAY green and
// STOP red at the bottom, like the bank). Writes a full .iconset:
//   swiftc -o make_icon tools/make_icon.swift && ./make_icon <dir>/AppIcon.iconset
//   iconutil -c icns <dir>/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Background squircle (macOS icon grid: 824 px body inside 1024).
let bg = NSRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bg, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45).cgColor)
NSGradient(starting: rgb(46, 52, 64), ending: rgb(18, 20, 26))!.draw(in: bgPath, angle: -90)
ctx.restoreGState()

// Pedal body.
let body = NSRect(x: 190, y: 190, width: 644, height: 644)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 70, yRadius: 70)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.6).cgColor)
NSGradient(starting: rgb(92, 98, 110), ending: rgb(58, 62, 72))!.draw(in: bodyPath, angle: -90)
ctx.restoreGState()
rgb(255, 255, 255, 0.12).setStroke(); bodyPath.lineWidth = 4; bodyPath.stroke()

// Screen across the middle, showing a song bar.
let screen = NSRect(x: 250, y: 455, width: 524, height: 114)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 18, yRadius: 18)
NSGradient(starting: rgb(10, 14, 22), ending: rgb(24, 32, 46))!.draw(in: screenPath, angle: -90)
rgb(255, 255, 255, 0.10).setStroke(); screenPath.lineWidth = 3; screenPath.stroke()
// "Song title" bar + tempo dots
NSBezierPath(roundedRect: NSRect(x: 282, y: 497, width: 290, height: 30), xRadius: 15, yRadius: 15).fill(with: rgb(120, 200, 255))
for (i, x) in [604.0, 652.0, 700.0].enumerated() {
    NSBezierPath(ovalIn: NSRect(x: x, y: 496, width: 32, height: 32)).fill(with: i == 0 ? rgb(255, 214, 10) : rgb(120, 200, 255, 0.45))
}

// Four footswitches with a light above each: PLAY green, STOP red, prev / next white-blue.
let leds: [NSColor] = [rgb(52, 211, 120), rgb(255, 69, 58), rgb(255, 214, 10), rgb(120, 200, 255)]
let centers: [CGPoint] = [CGPoint(x: 352, y: 300), CGPoint(x: 672, y: 300), CGPoint(x: 352, y: 700), CGPoint(x: 672, y: 700)]
for (c, led) in zip(centers, leds) {
    let r: CGFloat = 66
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r - 10, y: c.y - r - 10, width: 2 * (r + 10), height: 2 * (r + 10)))
    ring.fill(with: rgb(36, 39, 46))
    let knob = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    NSGradient(starting: rgb(232, 235, 240), ending: rgb(140, 146, 156))!.draw(in: knob, angle: -60)
    let cap = NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.62, y: c.y - r * 0.62, width: r * 1.24, height: r * 1.24))
    NSGradient(starting: rgb(200, 204, 212), ending: rgb(160, 166, 176))!.draw(in: cap, angle: 120)
    // LED ring glow around the switch
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: led.cgColor)
    let glow = NSBezierPath(ovalIn: NSRect(x: c.x - r - 10, y: c.y - r - 10, width: 2 * (r + 10), height: 2 * (r + 10)))
    led.setStroke(); glow.lineWidth = 9; glow.stroke()
    ctx.restoreGState()
}
img.unlockFocus()

extension NSBezierPath { func fill(with c: NSColor) { c.setFill(); fill() } }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
print("wrote", dir.path)
