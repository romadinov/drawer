import AppKit
import UniformTypeIdentifiers
import DrawerCore

@MainActor
enum Exporter {
    enum Format { case png, pdf }

    private static func contentRect(_ doc: DrawerDocument) -> CGRect? {
        let g = DiagramGeometry(parsed: doc.parsed, state: doc.state, measure: appMeasurer)
        return g.bounds.map { CGRect($0).insetBy(dx: -30, dy: -30).integral }
    }

    private static func render(_ doc: DrawerDocument, in rect: CGRect) {
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSColor.white.setFill()
            CGRect(origin: .zero, size: rect.size).fill()
            let t = NSAffineTransform()
            t.translateX(by: -rect.minX, yBy: -rect.minY)
            t.concat()
            DiagramRenderer(parsed: doc.parsed, state: doc.state).draw()
        }
    }

    static func pngData(_ doc: DrawerDocument, scale: CGFloat = 2) -> Data? {
        guard let rect = contentRect(doc) else { return nil }
        let w = Int(rect.width * scale), h = Int(rect.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        ctx.cgContext.translateBy(x: 0, y: CGFloat(h))
        ctx.cgContext.scaleBy(x: scale, y: -scale)
        render(doc, in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func pdfData(_ doc: DrawerDocument) -> Data? {
        guard let rect = contentRect(doc) else { return nil }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: rect.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        render(doc, in: rect)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func exportImage(_ doc: DrawerDocument, format: Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        panel.nameFieldStringValue = "diagram." + (format == .png ? "png" : "pdf")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = format == .png ? pngData(doc) : pdfData(doc)
        try? data?.write(to: url)
    }

    static func copyPNG(_ doc: DrawerDocument) {
        guard let data = pngData(doc) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }
}

@MainActor
enum HeadlessExport {
    static func run(input: String, output: String) -> Never {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            let state = try JSONDecoder().decode(DrawingState.self, from: data)
            let doc = DrawerDocument(state: state)
            let out = output.hasSuffix(".pdf") ? Exporter.pdfData(doc) : Exporter.pngData(doc)
            guard let out else { throw CocoaError(.fileWriteUnknown) }
            try out.write(to: URL(fileURLWithPath: output))
            for d in doc.parsed.diagnostics { FileHandle.standardError.write("line \(d.line): \(d.message)\n".data(using: .utf8)!) }
            exit(0)
        } catch {
            FileHandle.standardError.write("export failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
