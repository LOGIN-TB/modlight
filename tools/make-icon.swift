// Draws Podlight's app icon and writes the macOS AppIcon set.
//   swift tools/make-icon.swift apps/mac/App/Assets.xcassets/AppIcon.appiconset
// A lit bulb on a dark-to-teal field: "light on while you work, off when you don't". No RunPod
// marks: Podlight is independent of RunPod.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: content inset ~10%, rounded rect with ~22.5% corner radius.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(red: 0.05, green: 0.09, blue: 0.16, alpha: 1).cgColor,
                  NSColor(red: 0.04, green: 0.36, blue: 0.42, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Glow behind the bulb.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.55).cgColor, NSColor.clear.cgColor] as CFArray,
                          locations: [0, 1])!
    let center = CGPoint(x: s * 0.5, y: s * 0.56)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.36, options: [])

    // The bulb, as an SF Symbol tinted warm white.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular)
        .applying(.init(paletteColors: [NSColor(red: 1, green: 0.93, blue: 0.7, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "lightbulb.max.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: CGRect(x: (s - size.width) / 2, y: (s - size.height) / 2 + s * 0.02, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon sizes to \(out.path)")
