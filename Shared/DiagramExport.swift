import DrawerCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Images of a diagram that carry the editable diagram inside them (like draw.io's .drawio.png / .drawio.svg),
/// so they can be opened in Drawer again. Always rendered in the light appearance on white.
@MainActor
enum DiagramExport {
    static func prepared(_ state: DrawingState) -> (DrawingState, ParsedDiagram, CGRect)? {
        var s = state
        let parsed = Engine.reconcile(&s, measure: appMeasurer)
        guard let b = DiagramGeometry(parsed: parsed, state: s, measure: appMeasurer).bounds else { return nil }
        return (s, parsed, CGRect(b).insetBy(dx: -30, dy: -30).integral)
    }

    static func inLightAppearance(_ body: () -> Void) {
        #if os(macOS)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance(body)
        #else
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent(body)
        #endif
    }

    static func png(_ state: DrawingState, scale: CGFloat = 2) -> Data? {
        guard let (s, parsed, rect) = prepared(state) else { return nil }
        let draw = {
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            DiagramRenderer(parsed: parsed, state: s).draw()
        }
        #if os(macOS)
        let w = Int(rect.width * scale), h = Int(rect.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        ctx.cgContext.translateBy(x: 0, y: CGFloat(h))
        ctx.cgContext.scaleBy(x: scale, y: -scale)
        ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        inLightAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let data = UIGraphicsImageRenderer(size: rect.size, format: format).pngData { ctx in
            ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            inLightAppearance(draw)
        }
        #endif
        return EmbeddedDiagram.embed(state, inPNG: data)
    }

    static func svg(_ state: DrawingState) -> Data? {
        guard let (s, parsed, rect) = prepared(state) else { return nil }
        var text = ""
        inLightAppearance {
            text = SVGSurface.render(rect, metadata: EmbeddedDiagram.svgMetadata(state)) { DiagramRenderer(parsed: parsed, state: s).draw() }
        }
        return Data(text.utf8)
    }

    /// The file contents for saving a document as `type` (PNG/SVG with the diagram embedded, otherwise JSON).
    static func fileContents(_ state: DrawingState, as type: UTType) -> Data? {
        if type.conforms(to: .png) { return png(state) }
        if type.conforms(to: .svg) { return svg(state) }
        return nil
    }
}
