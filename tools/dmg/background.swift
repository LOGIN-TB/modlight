// Draws the disk image window background: where to drag Modlight, in German and English.
//   swift tools/dmg/background.swift <out-dir>     → background.png (660×400) and background@2x.png
// Icons are placed by dmgbuild at (165, 210) and (495, 210); the arrow sits between them.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let size = CGSize(width: 660, height: 400)

func render(scale: CGFloat) -> Data {
    let px = Int(size.width * scale), py = Int(size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Soft light field with a hint of Modlight's teal.
    let colors = [NSColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1).cgColor,
                  NSColor(red: 0.89, green: 0.95, blue: 0.96, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])

    // Arrow from the app to Applications (Finder's y runs downwards; ours upwards).
    let y = size.height - 210
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 255, y: y))
    arrow.curve(to: CGPoint(x: 395, y: y), controlPoint1: CGPoint(x: 300, y: y + 28), controlPoint2: CGPoint(x: 350, y: y + 28))
    NSColor(red: 0.04, green: 0.42, blue: 0.48, alpha: 0.9).setStroke()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 381, y: y + 14))
    head.line(to: CGPoint(x: 397, y: y))
    head.line(to: CGPoint(x: 380, y: y - 12))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: color, .paragraphStyle: style]
        NSAttributedString(string: text, attributes: attributes)
            .draw(in: CGRect(x: 0, y: y, width: 660, height: size * 1.4))
    }
    centered("Zum Installieren Modlight in den Programme-Ordner ziehen", y: 336, size: 17, weight: .semibold,
             color: NSColor(red: 0.08, green: 0.16, blue: 0.22, alpha: 1))
    centered("Drag Modlight to Applications to install", y: 312, size: 13, weight: .regular,
             color: NSColor(red: 0.25, green: 0.33, blue: 0.38, alpha: 1))
    centered("Open models, one endpoint · Modlight is not affiliated with RunPod or Venice", y: 22, size: 11, weight: .regular,
             color: NSColor(red: 0.35, green: 0.42, blue: 0.46, alpha: 0.9))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print("wrote background.png and background@2x.png")
