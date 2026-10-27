import AppKit
import ImageIO
import UniformTypeIdentifiers
// Draws the Drawer app icon in the Uberdoer style: dark navy squircle with a blue rim glow,
// glossy stacked blue sheets, and a glowing cyan→green diagram on the top sheet.
// Usage: swift make-icon.swift <AppIcon.appiconset dir> [--ios]
// --ios writes a single full-bleed, opaque 1024 icon (iOS applies its own corner mask).

let out = CommandLine.arguments[1]
let ios = CommandLine.arguments.contains("--ios")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// Draws the 1024-pt artwork with the squircle filling `shape`.
func drawIcon(_ ctx: CGContext, shape r: CGRect) {
    let k = r.width / 824 // design units are relative to an 824 squircle
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) } // y up
    let squircle = CGPath(roundedRect: r, cornerWidth: r.width * 0.2237, cornerHeight: r.width * 0.2237, transform: nil)

    // Background
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x141B33), rgb(0x0A0E1C)]), start: p(0, 824), end: p(0, 0), options: [])
    ctx.drawRadialGradient(gradient([rgb(0x2D5BFF, 0.35), rgb(0x2D5BFF, 0)]), startCenter: p(412, 430), startRadius: 0,
                           endCenter: p(412, 430), endRadius: 420 * k, options: [])
    ctx.restoreGState()
    // Rim glow
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.setShadow(offset: .zero, blur: 60 * k, color: rgb(0x3D7BFF, 1))
    ctx.setStrokeColor(rgb(0x5B8CFF, 0.35)); ctx.setLineWidth(8 * k)
    ctx.addPath(squircle); ctx.strokePath()
    ctx.restoreGState()

    // Sheets: rotated rounded rectangles, back to front.
    func sheet(center: CGPoint, size: CGSize, angle: CGFloat, top: CGColor, bottom: CGColor, glow: CGFloat, gloss: Bool) -> CGAffineTransform {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: 46 * k, cornerHeight: 46 * k, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: glow * k, color: rgb(0x1E3DFF, 0.75))
        ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        if gloss {
            // Soft highlight across the upper half and a bright top edge.
            ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.0)]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
            ctx.setStrokeColor(rgb(0xBFE3FF, 0.55)); ctx.setLineWidth(6 * k)
            ctx.addPath(path); ctx.strokePath()
        }
        let t = ctx.ctm
        ctx.restoreGState()
        _ = t
        return CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
    }
    let angle: CGFloat = 0.10
    let size = CGSize(width: 560 * k, height: 400 * k)
    _ = sheet(center: p(440, 300), size: size, angle: angle, top: rgb(0x3048E8), bottom: rgb(0x2A1FA8), glow: 30, gloss: false)
    _ = sheet(center: p(425, 350), size: size, angle: angle, top: rgb(0x3767F2), bottom: rgb(0x2C3BD0), glow: 30, gloss: false)
    let top = sheet(center: p(405, 410), size: size, angle: angle, top: rgb(0x4FA8FF), bottom: rgb(0x2F5BEA), glow: 50, gloss: true)

    // Diagram on the top sheet (coordinates relative to the sheet centre).
    ctx.saveGState()
    ctx.concatenate(top)
    let a = CGPoint(x: 0, y: 95 * k), b = CGPoint(x: -150 * k, y: -90 * k), c = CGPoint(x: 150 * k, y: -90 * k)
    // Glowing connectors
    let connector = CGMutablePath()
    connector.move(to: CGPoint(x: a.x, y: a.y - 40 * k))
    connector.addLine(to: CGPoint(x: a.x, y: 0)); connector.addLine(to: CGPoint(x: b.x, y: 0)); connector.addLine(to: CGPoint(x: b.x, y: b.y + 40 * k))
    connector.move(to: CGPoint(x: a.x, y: 0)); connector.addLine(to: CGPoint(x: c.x, y: 0)); connector.addLine(to: CGPoint(x: c.x, y: c.y + 40 * k))
    ctx.saveGState()
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(26 * k)
    ctx.setShadow(offset: .zero, blur: 30 * k, color: rgb(0x3DFFC8, 0.9))
    ctx.addPath(connector); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x7DF9FF), rgb(0x45E89A)]), start: CGPoint(x: -150 * k, y: 120 * k), end: CGPoint(x: 150 * k, y: -120 * k), options: [])
    ctx.restoreGState()
    // Nodes: glossy pills
    func node(_ center: CGPoint, _ w: CGFloat, _ h: CGFloat, highlight: Bool) {
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: 28 * k, cornerHeight: 28 * k, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 22 * k, color: rgb(0x0A1A80, 0.6))
        ctx.addPath(path); ctx.setFillColor(rgb(0x5FC4FF)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let colors = highlight ? [rgb(0x9CFFF0), rgb(0x48E3A6)] : [rgb(0xB5E6FF), rgb(0x5AAEFF)]
        ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.6)); ctx.setLineWidth(4 * k)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }
    node(a, 170 * k, 92 * k, highlight: true)
    node(b, 150 * k, 86 * k, highlight: false)
    node(c, 150 * k, 86 * k, highlight: false)
    ctx.restoreGState()
}

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    if ios {
        ctx.setFillColor(rgb(0x0F1428)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        drawIcon(ctx, shape: CGRect(x: 0, y: 0, width: s, height: s))
        return ctx.makeImage()!
    }
    let shape = s * 824 / 1024
    drawIcon(ctx, shape: CGRect(x: (s - shape) / 2, y: (s - shape) / 2, width: shape, height: shape))
    return ctx.makeImage()!
}

func write(_ cg: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(name)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

var images: [[String: String]] = []
if ios {
    write(render(1024), "ios-1024.png")
    images.append(["filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
}
let macSizes: [(Int, [Int])] = ios ? [] : [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])]
for (pt, scales) in macSizes {
    for sc in scales {
        let px = pt * sc
        let name = "mac-\(px).png"
        if !FileManager.default.fileExists(atPath: "\(out)/\(name)") { write(render(px), name) }
        images.append(["filename": name, "idiom": "mac", "scale": "\(sc)x", "size": "\(pt)x\(pt)"])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
