import AppKit
import UniformTypeIdentifiers
import DrawerCore

@MainActor
enum Exporter {
    enum Format { case png, svg, pdf }

    static func pngData(_ doc: DrawerDocument) -> Data? { DiagramExport.png(doc.state) }
    static func pdfData(_ doc: DrawerDocument) -> Data? { pdfData(doc.state) }

    static func pdfData(_ state: DrawingState) -> Data? {
        guard let (s, parsed, rect) = DiagramExport.prepared(state) else { return nil }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: rect.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        DiagramExport.inLightAppearance {
            NSColor.white.setFill()
            rect.fill()
            DiagramRenderer(parsed: parsed, state: s).draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func exportImage(_ doc: DrawerDocument, format: Format) {
        let panel = NSSavePanel()
        let type: UTType = switch format { case .png: .png; case .svg: .svg; case .pdf: .pdf }
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (doc.parsed.title ?? "Diagram") + "." + (type.preferredFilenameExtension ?? "png")
        if format != .pdf {
            panel.message = "The image keeps the editable diagram inside — open it in Drawer to keep editing."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = switch format { case .png: DiagramExport.png(doc.state); case .svg: DiagramExport.svg(doc.state); case .pdf: pdfData(doc.state) }
        try? data?.write(to: url)
    }

    static let diagramPasteboardType = NSPasteboard.PasteboardType(UTType.drawerDiagram.identifier)

    /// Copies the selection (or the whole diagram) as an image other apps can paste — PNG, SVG and PDF —
    /// plus the diagram itself, so pasting into Drawer brings back editable elements.
    static func copy(_ doc: DrawerDocument, selection: Set<ElementRef>? = nil) {
        let part = DiagramClipboard.subset(doc.state, parsed: doc.parsed, selection: selection ?? doc.selection)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(EmbeddedDiagram.json(part), forType: diagramPasteboardType)
        if let png = DiagramExport.png(part) { pb.setData(png, forType: .png) }
        if let svg = DiagramExport.svg(part) { pb.setData(svg, forType: NSPasteboard.PasteboardType(UTType.svg.identifier)) }
        if let pdf = pdfData(part) { pb.setData(pdf, forType: .pdf) }
    }

    static func copyPNG(_ doc: DrawerDocument) { copy(doc, selection: []) }

    /// A diagram on the pasteboard: copied from Drawer, or an image that has one embedded.
    static func pastedDiagram() -> DrawingState? {
        let pb = NSPasteboard.general
        for type in [diagramPasteboardType, .png, NSPasteboard.PasteboardType(UTType.svg.identifier), .fileURL] {
            guard var data = pb.data(forType: type) else { continue }
            if type == .fileURL, let url = URL(dataRepresentation: data, relativeTo: nil), let contents = try? Data(contentsOf: url) { data = contents }
            if let state = EmbeddedDiagram.decode(data) { return state }
        }
        return nil
    }
}

@MainActor
enum HeadlessExport {
    static func run(input: String, output: String) -> Never {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            guard let state = EmbeddedDiagram.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
            let doc = DrawerDocument(state: state)
            let out = output.hasSuffix(".pdf") ? Exporter.pdfData(doc) : output.hasSuffix(".svg") ? DiagramExport.svg(state) : Exporter.pngData(doc)
            guard let out else { throw CocoaError(.fileWriteUnknown) }
            try out.write(to: URL(fileURLWithPath: output))
            for d in doc.parsed.diagnostics { FileHandle.standardError.write("line \(d.line): \(d.message)\n".data(using: .utf8)!) }
            exit(0)
        } catch {
            FileHandle.standardError.write("export failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    /// Debug aid: treats the ink decorations in `input` as freshly drawn strokes, recognises them
    /// (shapes + Vision handwriting) and writes the result. Drawer --ink input.drawer output.drawer
    static func recognizeInk(input: String, output: String) -> Never {
        do {
            var state = try JSONDecoder().decode(DrawingState.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
            let strokes = state.decorations.filter { $0.kind == .ink }.flatMap { d in
                (d.strokes ?? []).map { InkStroke($0.map { Point(x: $0.x + d.frame.origin.x, y: $0.y + d.frame.origin.y) }) }
            }
            state.decorations.removeAll { $0.kind == .ink }
            let shapes = InkRecognizer.recognize(strokes)
            let box = UnsafeMutableTransferBox<[InkItem]>()
            let done = DispatchSemaphore(value: 0)
            Task.detached { box.value = await HandwritingReader.read(shapes); done.signal() }
            done.wait()
            let items = box.value ?? shapes
            for item in items { print("recognised:", item.summary) }
            InkCommit.apply(items, to: &state, measure: appMeasurer)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: URL(fileURLWithPath: output))
            print(state.spec)
            exit(0)
        } catch {
            FileHandle.standardError.write("ink failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

private final class UnsafeMutableTransferBox<T>: @unchecked Sendable { var value: T? }

private extension InkItem {
    var summary: String {
        switch self {
        case let .person(r, _): "person at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.size.width))×\(Int(r.size.height))"
        case let .shape(k, r): "\(k) at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.size.width))×\(Int(r.size.height))"
        case let .connector(a, b, hs, he): "connector \(Int(a.x)),\(Int(a.y)) → \(Int(b.x)),\(Int(b.y))\(hs ? " head@start" : "")\(he ? " head@end" : "")"
        case let .text(t, r, _): "text \(t.map { "\"\($0)\"" } ?? "(unreadable)") at \(Int(r.minX)),\(Int(r.minY))"
        }
    }
}
