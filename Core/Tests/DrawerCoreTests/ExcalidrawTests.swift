import Foundation
import Testing
@testable import DrawerCore

@Suite struct ExcalidrawTests {
    /// Two labelled boxes joined by a labelled arrow, some free text and a scribble — the way Excalidraw saves them.
    let sketch = """
    {"type":"excalidraw","version":2,"source":"https://excalidraw.com","elements":[
     {"id":"a","type":"rectangle","x":100,"y":100,"width":160,"height":80,"strokeColor":"#1e1e1e","backgroundColor":"#a5d8ff",
      "boundElements":[{"id":"ta","type":"text"},{"id":"arr","type":"arrow"}]},
     {"id":"ta","type":"text","x":140,"y":128,"width":80,"height":25,"text":"Web App","originalText":"Web App","containerId":"a"},
     {"id":"b","type":"rectangle","x":500,"y":100,"width":160,"height":80,"strokeColor":"#e03131","backgroundColor":"transparent",
      "boundElements":[{"id":"tb","type":"text"}]},
     {"id":"tb","type":"text","x":530,"y":118,"width":100,"height":50,"text":"Orders\\nService","originalText":"Orders Service","containerId":"b","strokeColor":"#f08c00"},
     {"id":"arr","type":"arrow","x":265,"y":140,"width":230,"height":0,"points":[[0,0],[230,0]],
      "startBinding":{"elementId":"a","focus":0,"gap":5},"endBinding":{"elementId":"b","fixedPoint":[0,0.5],"mode":"orbit"},
      "startArrowhead":null,"endArrowhead":"arrow","boundElements":[{"id":"tl","type":"text"}]},
     {"id":"tl","type":"text","x":350,"y":115,"width":60,"height":20,"text":"calls","containerId":"arr"},
     {"id":"note","type":"text","x":100,"y":300,"width":200,"height":25,"text":"Draft for review"},
     {"id":"todo","type":"text","x":100,"y":400,"width":200,"height":50,"fontSize":16,"text":"To do:\\nadd retries"},
     {"id":"gone","type":"rectangle","x":900,"y":900,"width":50,"height":50,"isDeleted":true},
     {"id":"f","type":"freedraw","x":400,"y":300,"width":40,"height":20,"points":[[0,0],[10,15],[25,5],[40,20]],"pressures":[]}
    ],"appState":{"viewBackgroundColor":"#ffffff"},"files":{}}
    """

    @Test func opensAnExcalidrawFile() throws {
        let scene = try #require(Excalidraw.scene(from: Data(sketch.utf8)))
        #expect(scene.elements.count == 9, "deleted elements are dropped")
        let state = Excalidraw.state(from: scene)
        let parsed = SpecParser.parse(state.spec, language: state.language)
        #expect(state.language == .mermaid)
        #expect(Set(parsed.nodes.map(\.title)) == ["Web App", "Orders Service"], "\(state.spec)")
        let web = try #require(parsed.nodes.first { $0.title == "Web App" })
        let orders = try #require(parsed.nodes.first { $0.title == "Orders Service" })
        #expect(parsed.edges.count == 1)
        #expect(parsed.edges.first?.from == web.id && parsed.edges.first?.to == orders.id)
        #expect(parsed.edges.first?.label == "calls")
        #expect(state.styles[web.id]?.fill == "#a5d8ff")
        #expect(state.styles[orders.id]?.stroke == "#e03131")
        #expect(state.styles[orders.id]?.text == "#f08c00")
        #expect(state.decorations.contains { $0.kind == .text && $0.text == "Draft for review" })
        #expect(state.decorations.contains { $0.kind == .ink })
        #expect(state.decorations.contains { $0.kind == .text && $0.text == "To do:\nadd retries" && $0.fontSize == 16 }, "notes keep their lines")
    }

    @Test func pastedIntoAC4DiagramBecomesC4() throws {
        let scene = try #require(Excalidraw.scene(from: Data(sketch.utf8)))
        var state = DrawingState(language: .plantUML, spec: DiagramStarter.blankSpec(.c4, language: .plantUML))
        let pasted = Excalidraw.paste(scene, into: &state)
        let parsed = SpecParser.parse(state.spec, language: state.language)
        #expect(parsed.family == .c4)
        #expect(parsed.nodes.allSatisfy { $0.kind == .container }, "\(state.spec)")
        #expect(parsed.edges.count == 1)
        #expect(pasted.contains(.node(parsed.nodes[0].id)))
    }

    @Test func aShapeAroundOthersBecomesAGroup() throws {
        let json = """
        {"type":"excalidraw/clipboard","elements":[
         {"id":"bg","type":"rectangle","x":-4000,"y":-3000,"width":10000,"height":7500,"backgroundColor":"#1e1e2e"},
         {"id":"g","type":"frame","x":0,"y":0,"width":600,"height":300,"name":"Backend"},
         {"id":"a","type":"rectangle","x":50,"y":80,"width":150,"height":70},
         {"id":"t","type":"text","x":80,"y":100,"width":60,"height":20,"text":"API","containerId":"a"},
         {"id":"b","type":"ellipse","x":350,"y":80,"width":150,"height":70},
         {"id":"u","type":"text","x":390,"y":100,"width":60,"height":20,"text":"Cache"}
        ]}
        """
        let state = Excalidraw.state(from: try #require(Excalidraw.scene(from: Data(json.utf8))))
        let parsed = SpecParser.parse(state.spec, language: state.language)
        #expect(parsed.nodes.filter(\.kind.isGroup).count == 1, "the page background isn't a group: \(state.spec)")
        let group = try #require(parsed.nodes.first { $0.kind.isGroup }, "\(state.spec)")
        #expect(group.title == "Backend")
        #expect(Set(parsed.children(of: group.id).map(\.title)) == ["API", "Cache"], "\(state.spec)")
    }

    @Test func groupedIconsAreOneElementEach() throws {
        // A database drawn as a cylinder (two ellipses, a rectangle, two lines) and a stick figure, each grouped with its label.
        let json = """
        {"type":"excalidraw","elements":[
         {"id":"t1","type":"text","x":600,"y":60,"width":120,"height":25,"text":"Posts Table","groupIds":["db"]},
         {"id":"e1","type":"ellipse","x":600,"y":100,"width":110,"height":35,"groupIds":["db"]},
         {"id":"e2","type":"ellipse","x":600,"y":160,"width":110,"height":35,"groupIds":["db"]},
         {"id":"r1","type":"rectangle","x":600,"y":118,"width":110,"height":60,"groupIds":["db"]},
         {"id":"l1","type":"line","x":600,"y":118,"width":0,"height":60,"points":[[0,0],[0,60]],"groupIds":["db"]},
         {"id":"l2","type":"line","x":710,"y":118,"width":0,"height":60,"points":[[0,0],[0,60]],"groupIds":["db"]},
         {"id":"h","type":"ellipse","x":110,"y":100,"width":30,"height":30,"groupIds":["inner","fig"]},
         {"id":"b","type":"line","x":125,"y":130,"width":30,"height":70,"points":[[0,0],[0,40],[-15,70],[0,40],[15,70]],"groupIds":["fig"]},
         {"id":"t2","type":"text","x":105,"y":205,"width":40,"height":25,"text":"Reader","groupIds":["fig"]},
         {"id":"a","type":"arrow","x":170,"y":150,"width":420,"height":0,"points":[[0,0],[420,0]],"endBinding":{"elementId":"r1","focus":0,"gap":4}}
        ]}
        """
        let scene = try #require(Excalidraw.scene(from: Data(json.utf8)))
        let flow = Excalidraw.state(from: scene)
        var parsed = SpecParser.parse(flow.spec, language: flow.language)
        let table = try #require(parsed.nodes.first { $0.title == "Posts Table" }, "\(flow.spec)")
        #expect(table.kind == .database)
        #expect(parsed.nodes.count == 1, "the figure stays a drawing in a flowchart: \(flow.spec)")

        var c4 = DrawingState(language: .plantUML, spec: DiagramStarter.blankSpec(.c4, language: .plantUML))
        Excalidraw.paste(scene, into: &c4)
        parsed = SpecParser.parse(c4.spec, language: c4.language)
        #expect(parsed.nodes.first { $0.title == "Posts Table" }?.kind == .containerDb, "\(c4.spec)")
        let reader = try #require(parsed.nodes.first { $0.title == "Reader" }, "\(c4.spec)")
        #expect(reader.kind == .person)
        #expect(parsed.edges.first.map { [$0.from, $0.to] } == [reader.id, parsed.nodes.first { $0.title == "Posts Table" }!.id])
    }

    @Test func exportsBoundElementsAndReopensExactly() throws {
        let template = DiagramTemplate.all.first { $0.name.contains("C4") }!
        var state = DrawingState(language: template.language, spec: template.spec)
        Engine.reconcile(&state)
        state.decorations = [Decoration(kind: .note, frame: Rect(x: 0, y: -200, width: 120, height: 60), text: "Remember"),
                             Decoration(kind: .ink, frame: Rect(x: 0, y: -300, width: 50, height: 50), strokes: [[Point(x: 0, y: 0), Point(x: 50, y: 50)]])]
        let data = Excalidraw.file(state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "excalidraw")
        let elements = try #require(object["elements"] as? [[String: Any]])
        let ids = Set(elements.compactMap { $0["id"] as? String })
        #expect(ids.count == elements.count, "ids are unique")
        let parsed = SpecParser.parse(state.spec, language: state.language)

        // Every bound label and arrow end points at a real element, and that element lists it back.
        func bound(_ id: String) -> Set<String> {
            Set((elements.first { $0["id"] as? String == id }?["boundElements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        }
        for e in elements {
            let id = e["id"] as! String
            if let container = e["containerId"] as? String { #expect(bound(container).contains(id)) }
            for key in ["startBinding", "endBinding"] {
                if let b = e[key] as? [String: Any], let target = b["elementId"] as? String { #expect(bound(target).contains(id)) }
            }
        }
        let arrows = elements.filter { $0["type"] as? String == "arrow" }
        #expect(arrows.count == parsed.edges.count)
        #expect(arrows.allSatisfy { !($0["startBinding"] is NSNull) && !($0["endBinding"] is NSNull) })
        let labels = Set(elements.compactMap { $0["originalText"] as? String })
        for node in parsed.nodes where !node.kind.isGroup {
            #expect(labels.contains { $0.contains(node.title) }, "no label for \(node.title)")
        }
        #expect(elements.contains { $0["type"] as? String == "freedraw" })

        // Drawer reads back its own diagram; Excalidraw's elements alone still give the same elements.
        #expect(Excalidraw.scene(from: data)?.drawer == state)
        var plain = object
        plain["drawer"] = nil
        let reimported = Excalidraw.state(from: try #require(Excalidraw.scene(from: try JSONSerialization.data(withJSONObject: plain))))
        let again = SpecParser.parse(reimported.spec, language: reimported.language)
        // (The note comes back as an element too: in Excalidraw it's just a rectangle.)
        #expect(again.nodes.filter { !$0.kind.isGroup }.count == parsed.nodes.filter { !$0.kind.isGroup }.count + 1, "\(reimported.spec)")
        #expect(again.edges.count == parsed.edges.count)
        #expect(again.edges.filter { $0.label != nil }.count == parsed.edges.filter { $0.label != nil }.count, "\(reimported.spec)")
        #expect(again.nodes.filter(\.kind.isGroup).map(\.title) == parsed.nodes.filter(\.kind.isGroup).map { $0.title + "  [System]" }, "\(reimported.spec)")
    }

    @Test func exportsSequenceDiagrams() throws {
        let template = DiagramTemplate.all.first { $0.name.contains("Sequence") }!
        let elements = Excalidraw.elements(DrawingState(language: template.language, spec: template.spec), measure: approximateMeasurer)
        let parsed = SpecParser.parse(template.spec, language: template.language)
        #expect(elements.filter { $0["type"] as? String == "arrow" }.count == parsed.edges.count)
        #expect(elements.filter { $0["type"] as? String == "line" }.count >= parsed.nodes.count, "lifelines")
    }

    @Test func clipboardIsWhatExcalidrawPastes() throws {
        var state = DrawingState(language: .mermaid, spec: "flowchart LR\n  A[Shop] --> B[(Orders)]\n")
        Engine.reconcile(&state)
        let text = Excalidraw.clipboard(state)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "excalidraw/clipboard")
        #expect((object["elements"] as? [Any])?.isEmpty == false)
        let back = Excalidraw.state(from: try #require(Excalidraw.scene(from: Data(text.utf8))))
        #expect(Set(SpecParser.parse(back.spec, language: back.language).nodes.map(\.title)) == ["Shop", "Orders"], "\(back.spec)")
    }

    /// Excalidraw's "embed scene" wrapper: pako.deflate (zlib) output as a byte string.
    func wrapper(_ json: String) throws -> String {
        let raw = try (Data(json.utf8) as NSData).compressed(using: .zlib) as Data
        var adler = (UInt32(1), UInt32(0))
        for byte in Data(json.utf8) { adler.0 = (adler.0 + UInt32(byte)) % 65521; adler.1 = (adler.1 + adler.0) % 65521 }
        var checksum = (adler.1 << 16 | adler.0).bigEndian
        let zlib = Data([0x78, 0x9C]) + raw + Data(bytes: &checksum, count: 4)
        let bstring = String(zlib.map { Character(Unicode.Scalar($0)) })
        let w = try JSONSerialization.data(withJSONObject: ["version": "1", "encoding": "bstring", "compressed": true, "encoded": bstring])
        return String(decoding: w, as: UTF8.self)
    }

    @Test func readsScenesEmbeddedInPNGAndSVG() throws {
        let payload = try wrapper(sketch)
        // PNG: a tEXt chunk keyed by the MIME type, its value one byte per character.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==")!
        var chunks = EmbeddedDiagram.pngChunks(png)
        let text = Data(Excalidraw.mimeType.utf8) + Data([0]) + Data(payload.unicodeScalars.map { UInt8($0.value) })
        chunks.insert((type: "tEXt", data: text), at: chunks.count - 1)
        var out = Data(EmbeddedDiagram.pngSignature)
        for c in chunks {
            var length = UInt32(c.data.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            let typeAndData = Data(c.type.utf8) + c.data
            out.append(typeAndData)
            var crc = EmbeddedDiagram.crc32(typeAndData).bigEndian
            out.append(Data(bytes: &crc, count: 4))
        }
        #expect(Excalidraw.scene(from: out)?.elements.count == 9)

        // SVG: base64 of the same byte string between comment markers.
        let b64 = Data(payload.unicodeScalars.map { UInt8($0.value) }).base64EncodedString()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg"><!-- svg-source:excalidraw --><metadata><!-- payload-type:application/vnd.excalidraw+json -->\
        <!-- payload-version:2 --><!-- payload-start -->\(b64)<!-- payload-end --></metadata></svg>
        """
        #expect(Excalidraw.scene(from: Data(svg.utf8))?.elements.count == 9)
        #expect(Excalidraw.scene(from: png) == nil)
    }
}
