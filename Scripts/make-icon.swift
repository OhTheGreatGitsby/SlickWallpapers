// Renders Resources/AppIcon.icns — the selector in miniature.
// Usage: swift Scripts/make-icon.swift   (run from the repo root)
import AppKit

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

func slant(_ r: CGRect, skew: CGFloat) -> CGPath {
    // CoreGraphics is y-up: top edge at maxY, leaning like "\".
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX - skew, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX + skew, y: r.minY))
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt body centred in 1024, continuous-corner squircle.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0x0B0E1C))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
linear(ctx, [color(0x1A1440), color(0x0A0D1F), color(0x05060E)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100))
// Nebula glows
for (center, radius, hex, alpha) in [(CGPoint(x: 300, y: 760), 420.0, 0x5B3BFF, 0.35), (CGPoint(x: 760, y: 260), 380.0, 0xFF3D7F, 0.28)] as [(CGPoint, CGFloat, UInt32, CGFloat)] {
    let g = CGGradient(colorsSpace: cs, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
// Stars (deterministic)
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1) }
for _ in 0..<70 {
    let r = 1.5 + rnd() * 3
    ctx.setFillColor(color(0xFFFFFF, 0.25 + rnd() * 0.6))
    ctx.fillEllipse(in: CGRect(x: 100 + rnd() * 824, y: 100 + rnd() * 824, width: r, height: r))
}

// Cards
let h: CGFloat = 470, w = h * 0.84, skew = h * 0.30
let cy: CGFloat = 512
func card(_ cx: CGFloat, scale: CGFloat, colors: [CGColor], dim: CGFloat, border: Bool) {
    let cw = w * scale, ch = h * scale
    let rect = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
    let path = slant(rect, skew: skew * scale)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.6))
    ctx.addPath(path)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linear(ctx, colors, CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY))
    // soft highlight blob
    let g = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)] as CFArray, locations: nil)!
    let hc = CGPoint(x: rect.midX - cw * 0.1, y: rect.maxY - ch * 0.28)
    ctx.drawRadialGradient(g, startCenter: hc, startRadius: 0, endCenter: hc, endRadius: cw * 0.7, options: [])
    ctx.setFillColor(color(0x000000, dim))
    ctx.fill(rect)
    ctx.restoreGState()

    if border {
        ctx.addPath(path)
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.setLineWidth(15)
        ctx.setLineJoin(.miter)
        ctx.strokePath()
    }
}

card(512 - h * 0.6, scale: 0.86, colors: [color(0x2EC5FF), color(0x3A3DFF), color(0x1B1A6B)], dim: 0.28, border: false)
card(512 + h * 0.6, scale: 0.86, colors: [color(0x8CFFB5), color(0x16A39A), color(0x0B3A55)], dim: 0.28, border: false)
card(512, scale: 1, colors: [color(0xFFB13B), color(0xFF4D4D), color(0xD8237A)], dim: 0, border: true)
ctx.restoreGState()

// Export
let image = ctx.makeImage()!
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ px: Int, _ name: String) throws {
    let out = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.interpolationQuality = .high
    out.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    try write(base, "icon_\(base)x\(base).png")
    try write(base * 2, "icon_\(base)x\(base)@2x.png")
}
try write(512, "../../docs/icon.png")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
