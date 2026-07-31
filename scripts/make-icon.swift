#!/usr/bin/env swift
// Generates CIDeck's app icon: a centred "CI" monogram on a blue→indigo squircle,
// laid out on the macOS Big Sur icon grid (transparent margin + continuous corners).
//
//   swift scripts/make-icon.swift            # writes Resources/AppIcon.iconset + .icns
//
// Requires macOS (AppKit) + iconutil (bundled with Xcode CLT).
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

/// Draws the icon at `px` × `px` into a fresh bitmap and returns its PNG data.
func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Big Sur grid: ~10% transparent margin, ~22.4% continuous corner radius.
    let margin = size * 0.094
    let rect = CGRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow so the tile lifts off light and dark wallpapers alike.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Blue → indigo gradient background.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let gradient = NSGradient(colors: [color(0x4C, 0x8D, 0xFF), color(0x1E, 0x4F, 0xD8)])!
    gradient.draw(in: rect, angle: -90)
    // Subtle top highlight for depth.
    let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
    gloss.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)
    ctx.restoreGState()

    // Centred "CI" monogram, heavy rounded, with a little tracking.
    let text = "CI"
    let fontSize = rect.width * 0.46
    let base = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                      size: fontSize) ?? base
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
    shadow.shadowBlurRadius = size * 0.02
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: fontSize * 0.02,
        .shadow: shadow,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    var bounds = str.boundingRect(with: .zero, options: .usesLineFragmentOrigin)
    bounds.origin.x = rect.midX - bounds.width/2
    bounds.origin.y = rect.midY - bounds.height/2 + size * 0.006
    str.draw(with: bounds, options: .usesLineFragmentOrigin)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Standard iconset entries: (base points, scale).
let entries: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (pt, scale) in entries {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(pt * scale).write(to: iconset.appendingPathComponent(name))
}
print("Wrote \(iconset.path)")

// Build .icns + a 1024 preview PNG.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", root.appendingPathComponent("Resources/AppIcon.icns").path, iconset.path]
try! task.run(); task.waitUntilExit()
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print("Wrote Resources/AppIcon.icns + AppIcon.png")
