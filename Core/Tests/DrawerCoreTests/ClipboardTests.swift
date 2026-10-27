import Foundation
import Testing
@testable import DrawerCore

@Suite struct ClipboardTests {
    let template = DiagramTemplate.all.first { $0.name == "UML Class" }!

    func state() -> DrawingState {
        var s = DrawingState(language: template.language, spec: template.spec)
        Engine.reconcile(&s)
        s.decorations = [Decoration(kind: .note, frame: Rect(x: 0, y: 0, width: 100, height: 60), text: "Hi")]
        return s
    }

    @Test func pngRoundTrip() throws {
        // A minimal valid 1×1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==")!
        let s = state()
        let embedded = EmbeddedDiagram.embed(s, inPNG: png)
        #expect(EmbeddedDiagram.decode(embedded) == s)
        // Re-embedding replaces rather than duplicates.
        let twice = EmbeddedDiagram.embed(s, inPNG: embedded)
        #expect(EmbeddedDiagram.pngChunks(twice).filter { $0.type == "iTXt" }.count == 1)
        #expect(EmbeddedDiagram.pngChunks(twice).map(\.type) == ["IHDR", "iTXt", "IDAT", "IEND"])
        #expect(EmbeddedDiagram.decode(png) == nil)
    }

    @Test func svgRoundTrip() {
        let s = state()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\">\(EmbeddedDiagram.svgMetadata(s))<rect/></svg>"
        #expect(EmbeddedDiagram.decode(Data(svg.utf8)) == s)
        #expect(EmbeddedDiagram.decode(Data("<svg></svg>".utf8)) == nil)
    }

    @Test func subsetAndPaste() {
        let s = state()
        let parsed = SpecParser.parse(s.spec, language: s.language)
        let part = DiagramClipboard.subset(s, parsed: parsed, selection: [.node("Order"), .node("OrderLine")])
        let p = SpecParser.parse(part.spec, language: part.language)
        #expect(Set(p.nodes.map(\.id)) == ["Order", "OrderLine"], "\(part.spec)")
        #expect(p.edges.count == 1)
        #expect(part.layout["Order"] == s.layout["Order"])
        #expect(part.decorations.isEmpty)

        // Pasting into the original renames clashes and keeps everything valid.
        var target = s
        let pasted = DiagramClipboard.paste(part, into: &target)
        let after = SpecParser.parse(target.spec, language: target.language)
        #expect(after.node("Order2") != nil && after.node("OrderLine2") != nil, "\(target.spec)")
        #expect(after.edges.contains { $0.from == "Order2" && $0.to == "OrderLine2" })
        #expect(after.diagnostics.isEmpty, "\(after.diagnostics)")
        #expect(pasted.contains(.node("Order2")))
        #expect(target.layout["Order2"]!.position.x > target.layout["Order"]!.position.x)

        // Across languages: a PlantUML selection pasted into a Mermaid class diagram.
        var mermaid = DrawingState(language: .mermaid, spec: "classDiagram\n  class Zoo\n")
        DiagramClipboard.paste(part, into: &mermaid)
        let m = SpecParser.parse(mermaid.spec, language: .mermaid)
        #expect(Set(m.nodes.map(\.id)) == ["Zoo", "Order", "OrderLine"], "\(mermaid.spec)")
        #expect(m.diagnostics.isEmpty, "\(m.diagnostics) \(mermaid.spec)")

        // Into an empty document: it simply becomes that diagram.
        var empty = DrawingState(language: .mermaid, spec: "")
        DiagramClipboard.paste(s, into: &empty)
        #expect(empty == s)
    }
}
