import CoreText
import DrawerCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Collects DiagramRenderer's drawing as SVG. While `SVGSurface.current` is set, the renderer's
/// fills, strokes and text go here instead of into the current graphics context.
final class SVGSurface {
    static var current: SVGSurface?

    private var body = ""
    fileprivate var fillColor: NSColor = .black
    fileprivate var strokeColor: NSColor = .black

    /// Runs `draw` with drawing redirected into a new SVG document covering `rect` (diagram coordinates).
    static func render(_ rect: CGRect, metadata: String, _ draw: () -> Void) -> String {
        let surface = SVGSurface()
        let previous = current
        current = surface
        defer { current = previous }
        draw()
        let f = { (v: CGFloat) in Self.number(v) }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(f(rect.width))" height="\(f(rect.height))" viewBox="\(f(rect.minX)) \(f(rect.minY)) \(f(rect.width)) \(f(rect.height))">
        \(metadata)
        <rect x="\(f(rect.minX))" y="\(f(rect.minY))" width="\(f(rect.width))" height="\(f(rect.height))" fill="#FFFFFF"/>
        \(surface.body)</svg>

        """
    }

    // MARK: Primitives

    fileprivate func fill(_ path: NSBezierPath) {
        guard let paint = Self.paint(fillColor) else { return }
        body += "<path d=\"\(Self.pathData(path))\" fill=\"\(paint.color)\"\(paint.opacity.map { " fill-opacity=\"\($0)\"" } ?? "")/>\n"
    }

    fileprivate func stroke(_ path: NSBezierPath) {
        guard let paint = Self.paint(strokeColor), path.lineWidth > 0 else { return }
        var attrs = "fill=\"none\" stroke=\"\(paint.color)\" stroke-width=\"\(Self.number(path.lineWidth))\""
        if let o = paint.opacity { attrs += " stroke-opacity=\"\(o)\"" }
        var count = 0
        path.getLineDash(nil, count: &count, phase: nil)
        if count > 0 {
            var pattern = [CGFloat](repeating: 0, count: count)
            path.getLineDash(&pattern, count: nil, phase: nil)
            attrs += " stroke-dasharray=\"\(pattern.map(Self.number).joined(separator: " "))\""
        }
        if path.lineCapStyle == .round { attrs += " stroke-linecap=\"round\"" }
        if path.lineJoinStyle == .round { attrs += " stroke-linejoin=\"round\"" }
        body += "<path d=\"\(Self.pathData(path))\" \(attrs)/>\n"
    }

    /// Lays text out with Core Text (same line breaks as on screen) and writes one `<text>` per run.
    fileprivate func text(_ string: NSAttributedString, in rect: CGRect) {
        guard string.length > 0 else { return }
        let height: CGFloat = 10_000
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: max(rect.width, 1), height: height), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            let lineRange = CTLineGetStringRange(line)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            let style = string.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
            let dx: CGFloat = switch style?.alignment {
            case .center?: (rect.width - lineWidth) / 2
            case .right?: rect.width - lineWidth
            default: 0
            }
            let baseline = rect.minY + height - origin.y
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let r = CTRunGetStringRange(run)
                let content = (string.string as NSString).substring(with: NSRange(location: r.location, length: r.length))
                    .trimmingCharacters(in: .newlines)
                guard !content.isEmpty else { continue }
                let x = rect.minX + dx + CTLineGetOffsetForStringIndex(line, r.location, nil)
                let font = string.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont ?? Fonts.body
                let color = string.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor ?? .black
                let paint = Self.paint(color) ?? (color: "#000000", opacity: nil)
                var attrs = "x=\"\(Self.number(x))\" y=\"\(Self.number(baseline))\" font-size=\"\(Self.number(font.pointSize))\" font-family=\"\(Self.family(font))\" fill=\"\(paint.color)\""
                if let o = paint.opacity { attrs += " fill-opacity=\"\(o)\"" }
                let traits = CTFontCopyTraits(font as CTFont) as NSDictionary
                let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
                if weight > 0.15 { attrs += " font-weight=\"\(weight > 0.35 ? 700 : 600)\"" }
                let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
                if symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0 { attrs += " font-style=\"italic\"" }
                body += "<text \(attrs) xml:space=\"preserve\">\(Self.escape(content))</text>\n"
            }
        }
    }

    // MARK: Helpers

    private static func family(_ font: NSFont) -> String {
        let monospaced = CTFontGetSymbolicTraits(font as CTFont).contains(.traitMonoSpace)
        return monospaced ? "ui-monospace, 'SF Mono', Menlo, Consolas, monospace"
                          : "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
    }

    static func number(_ v: CGFloat) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Resolves a (possibly dynamic) colour for the current appearance into an SVG paint; nil for fully clear.
    private static func paint(_ color: NSColor) -> (color: String, opacity: String?)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        guard a > 0.001 else { return nil }
        let hex = String(format: "#%02X%02X%02X", Int((min(max(r, 0), 1) * 255).rounded()), Int((min(max(g, 0), 1) * 255).rounded()), Int((min(max(b, 0), 1) * 255).rounded()))
        return (hex, a < 0.999 ? number(a) : nil)
    }

    private static func pathData(_ path: NSBezierPath) -> String {
        var d = ""
        let n = number
        path.cgPath.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: d += "M\(n(p[0].x)) \(n(p[0].y))"
            case .addLineToPoint: d += "L\(n(p[0].x)) \(n(p[0].y))"
            case .addQuadCurveToPoint: d += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
            case .addCurveToPoint: d += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }
}

// The renderer calls these instead of setFill()/fill() etc., so the same drawing code can produce SVG.
extension NSColor {
    func useForFill() { if let s = SVGSurface.current { s.fillColor = self } else { setFill() } }
    func useForStroke() { if let s = SVGSurface.current { s.strokeColor = self } else { setStroke() } }
}

extension NSBezierPath {
    func paintFill() { if let s = SVGSurface.current { s.fill(self) } else { fill() } }
    func paintStroke() { if let s = SVGSurface.current { s.stroke(self) } else { stroke() } }
}

extension DiagramRenderer {
    static func drawAttributed(_ s: NSAttributedString, in rect: CGRect) {
        if let surface = SVGSurface.current { surface.text(s, in: rect) }
        else { s.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil) }
    }
}
