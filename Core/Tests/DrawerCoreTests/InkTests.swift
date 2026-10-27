import Foundation
import Testing
@testable import DrawerCore

/// Synthetic "hand-drawn" strokes with a little wobble.
enum Pen {
    static func wobble(_ i: Int) -> Double { sin(Double(i) * 1.7) * 1.2 }

    static func polyline(_ corners: [Point], step: Double = 4) -> InkStroke {
        var pts: [Point] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(Int(InkMath.distance(a, b) / step), 1)
            for k in 0..<n {
                let t = Double(k) / Double(n)
                pts.append(Point(x: a.x + (b.x - a.x) * t + wobble(pts.count), y: a.y + (b.y - a.y) * t + wobble(pts.count + 3)))
            }
        }
        pts.append(corners.last!)
        return InkStroke(pts)
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> InkStroke {
        polyline([Point(x: x, y: y), Point(x: x + w, y: y), Point(x: x + w, y: y + h), Point(x: x, y: y + h), Point(x: x + 2, y: y + 3)])
    }

    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> InkStroke {
        InkStroke((0...60).map { i in
            let t = Double(i) / 60 * 2 * .pi
            return Point(x: cx + rx * cos(t) + wobble(i), y: cy + ry * sin(t) + wobble(i + 5))
        })
    }

    static func diamond(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> InkStroke {
        polyline([Point(x: cx, y: cy - ry), Point(x: cx + rx, y: cy), Point(x: cx, y: cy + ry), Point(x: cx - rx, y: cy), Point(x: cx + 1, y: cy - ry + 2)])
    }

    /// A little zig-zag the size of a handwritten word.
    static func word(_ x: Double, _ y: Double, letters: Int = 4) -> [InkStroke] {
        (0..<letters).map { i in
            let x0 = x + Double(i) * 14
            return polyline([Point(x: x0, y: y + 14), Point(x: x0 + 4, y: y), Point(x: x0 + 8, y: y + 14), Point(x: x0 + 11, y: y + 6)], step: 2)
        }
    }
}

extension Pen {
    /// Traced from a real drawing: arms as one "^" stroke, spine and legs as another, no head.
    static func stickFigure(dx: Double = 0, dy: Double = 0) -> [InkStroke] {
        func t(_ pts: [(Double, Double)]) -> [Point] { pts.map { Point(x: $0.0 + dx, y: $0.1 + dy) } }
        return [
            polyline(t([(55, 265), (110, 200), (160, 128), (172, 125), (200, 165), (268, 245)])),
            polyline(t([(168, 72), (172, 90), (162, 230), (158, 320), (175, 340), (185, 345), (240, 450), (285, 590),
                        (260, 570), (245, 500), (175, 380), (172, 470), (150, 540), (150, 558)])),
        ]
    }
}

@Suite struct InkTests {
    func kinds(_ items: [InkItem]) -> [String] {
        items.map {
            switch $0 {
            case let .shape(k, _): k.rawValue
            case .person: "person"
            case let .connector(_, _, s, e): s || e ? "arrow" : "line"
            case .text: "text"
            }
        }
    }

    @Test func recognisesBasicShapes() {
        #expect(kinds(InkRecognizer.recognize([Pen.rect(0, 0, 160, 80)])) == ["rectangle"])
        #expect(kinds(InkRecognizer.recognize([Pen.ellipse(100, 100, 80, 45)])) == ["ellipse"])
        #expect(kinds(InkRecognizer.recognize([Pen.diamond(100, 100, 70, 50)])) == ["diamond"])
        #expect(kinds(InkRecognizer.recognize([Pen.polyline([Point(x: 0, y: 0), Point(x: 200, y: 10)])])) == ["line"])
    }

    @Test func boxDrawnInFourStrokes() {
        let sides = [
            Pen.polyline([Point(x: 0, y: 0), Point(x: 150, y: 2)]),
            Pen.polyline([Point(x: 152, y: 4), Point(x: 150, y: 90)]),
            Pen.polyline([Point(x: 148, y: 92), Point(x: 1, y: 90)]),
            Pen.polyline([Point(x: 0, y: 88), Point(x: 2, y: 3)]),
        ]
        #expect(kinds(InkRecognizer.recognize(sides)) == ["rectangle"])
    }

    @Test func arrows() {
        // One stroke: shaft then a "V" head.
        let one = Pen.polyline([Point(x: 0, y: 0), Point(x: 200, y: 0), Point(x: 186, y: -12), Point(x: 200, y: 0), Point(x: 186, y: 12)], step: 3)
        let items = InkRecognizer.recognize([one])
        #expect(kinds(items) == ["arrow"])
        if case let .connector(from, to, headStart, headEnd) = items.first {
            #expect(from.x < 20 && to.x > 180 && headEnd && !headStart)
        }
        // Shaft plus a separate head stroke at the start.
        let shaft = Pen.polyline([Point(x: 0, y: 0), Point(x: 0, y: 150)])
        let head = Pen.polyline([Point(x: -10, y: 14), Point(x: 0, y: 1), Point(x: 10, y: 14)], step: 2)
        let two = InkRecognizer.recognize([shaft, head])
        #expect(kinds(two) == ["arrow"])
        if case let .connector(_, _, headStart, headEnd) = two.first { #expect(headStart && !headEnd) }
    }

    @Test func handwritingIsText() {
        let items = InkRecognizer.recognize(Pen.word(0, 0) + Pen.word(200, 200, letters: 3))
        #expect(kinds(items) == ["text", "text"])
        // A small "o" inside a word stays part of the word.
        let withO = Pen.word(0, 0) + [Pen.ellipse(66, 8, 7, 7)]
        #expect(kinds(InkRecognizer.recognize(withO)) == ["text"])
    }

    @Test func commitBuildsDiagramFromInk() {
        var state = DrawingState(language: .mermaid, spec: "")
        let items: [InkItem] = [
            .shape(.rectangle, Rect(x: 0, y: 0, width: 160, height: 70)),
            .shape(.diamond, Rect(x: 300, y: 0, width: 140, height: 90)),
            .text("Load order", bounds: Rect(x: 20, y: 25, width: 100, height: 20), strokes: []),
            .text("Valid?", bounds: Rect(x: 340, y: 35, width: 60, height: 20), strokes: []),
            .connector(from: Point(x: 165, y: 35), to: Point(x: 295, y: 45), headAtStart: false, headAtEnd: true),
            .text("checks", bounds: Rect(x: 200, y: 10, width: 50, height: 18), strokes: []),
            .text("Remember to review", bounds: Rect(x: 0, y: 300, width: 160, height: 22), strokes: []),
            .text(nil, bounds: Rect(x: 0, y: 400, width: 30, height: 30), strokes: [Pen.polyline([Point(x: 0, y: 400), Point(x: 30, y: 430)])]),
        ]
        let result = InkCommit.apply(items, to: &state)
        let parsed = SpecParser.parse(state.spec, language: .mermaid)
        #expect(parsed.family == .flowchart)
        #expect(parsed.node("LoadOrder")?.title == "Load order", "\(state.spec)")
        #expect(parsed.node("Valid")?.kind == .diamond, "\(state.spec)")
        #expect(parsed.edge("LoadOrder->Valid")?.label == "checks", "\(state.spec)")
        #expect(state.decorations.map(\.kind) == [.text, .ink])
        #expect(state.decorations.first?.text == "Remember to review")
        #expect(result.untitled.isEmpty)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func commitOnExistingDiagram() {
        var state = DrawingState(language: .plantUML, spec: "@startuml\nclass Order\nclass Customer\n@enduml\n")
        let parsed = Engine.reconcile(&state)
        let g = DiagramGeometry(parsed: parsed, state: state, measure: approximateMeasurer)
        let order = g.frames["Order"]!, customer = g.frames["Customer"]!
        // Draw an arrow from Customer to Order, then write a name onto Order.
        InkCommit.apply([
            .connector(from: customer.center, to: order.center, headAtStart: false, headAtEnd: true),
            .text("Purchase", bounds: Rect(x: order.midX - 30, y: order.midY - 8, width: 60, height: 16), strokes: []),
        ], to: &state)
        let after = SpecParser.parse(state.spec, language: .plantUML)
        #expect(after.edges.count == 1, "\(state.spec)")
        #expect(after.edges.first?.from == "Customer")
        #expect(after.nodes.contains { $0.title == "Purchase" }, "\(state.spec)")
        #expect(after.diagnostics.isEmpty)
    }

    @Test func sequenceArrowBecomesMessageInPlace() {
        var state = DrawingState(language: .mermaid, spec: "sequenceDiagram\n  participant A\n  participant B\n  A->>B: first\n  B->>A: second\n")
        let parsed = Engine.reconcile(&state)
        let g = DiagramGeometry(parsed: parsed, state: state, measure: approximateMeasurer)
        let seq = g.sequence!
        let y1 = seq.messagePaths[0]![0].y, y2 = seq.messagePaths[1]![0].y
        let mid = (y1 + y2) / 2
        InkCommit.apply([
            .connector(from: Point(x: seq.lifelines["B"]!.x, y: mid), to: Point(x: seq.lifelines["A"]!.x, y: mid + 4), headAtStart: false, headAtEnd: true),
        ], to: &state)
        let lines = state.spec.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.firstIndex(of: "B->>A: message")! < lines.firstIndex(of: "B->>A: second")!, "\(state.spec)")
    }

    @Test func stickFigureIsAPerson() {
        #expect(kinds(InkRecognizer.recognize(Pen.stickFigure())) == ["person"])
        // Three strokes plus a head.
        let three = [
            Pen.polyline([Point(x: 100, y: 40), Point(x: 100, y: 130)]),
            Pen.polyline([Point(x: 60, y: 75), Point(x: 140, y: 72)]),
            Pen.polyline([Point(x: 70, y: 190), Point(x: 100, y: 130), Point(x: 130, y: 192)]),
            Pen.ellipse(100, 28, 13, 13),
        ]
        #expect(kinds(InkRecognizer.recognize(three)) == ["person"])
        // Next to a box and a word, both stay what they are.
        let mixed = Pen.stickFigure() + [Pen.rect(400, 200, 160, 80)] + Pen.word(420, 400)
        #expect(Set(kinds(InkRecognizer.recognize(mixed))) == ["person", "rectangle", "text"])
        // A tall letter is not a person.
        #expect(kinds(InkRecognizer.recognize([Pen.polyline([Point(x: 0, y: 0), Point(x: 0, y: 100), Point(x: 50, y: 100)])])) != ["person"])
    }

    @Test func personBecomesActorOrC4Person() {
        var plant = DrawingState(language: .plantUML, spec: "")
        let r = Rect(x: 50, y: 70, width: 240, height: 520)
        InkCommit.apply([.person(r, strokes: []), .text("Customer", bounds: Rect(x: 120, y: 600, width: 90, height: 24), strokes: [])], to: &plant)
        let p = SpecParser.parse(plant.spec, language: .plantUML)
        #expect(p.nodes.map(\.kind) == [.actor], "\(plant.spec)")
        #expect(p.nodes.first?.title == "Customer")

        var c4 = DrawingState(language: .mermaid, spec: "C4Context\n  System(s, \"Shop\")\n")
        InkCommit.apply([.person(r, strokes: [])], to: &c4)
        #expect(SpecParser.parse(c4.spec, language: .mermaid).nodes.contains { $0.kind == .person }, "\(c4.spec)")

        // Mermaid flowcharts have no person shape: the drawing is kept as ink.
        var flow = DrawingState(language: .mermaid, spec: "flowchart TD\n  A\n")
        InkCommit.apply([.person(r, strokes: Pen.stickFigure())], to: &flow)
        #expect(flow.decorations.map(\.kind) == [.ink])

        // …but in a blank Mermaid document a figure starts a C4 context diagram.
        var blank = DrawingState(language: .mermaid, spec: "")
        InkCommit.apply([.person(r, strokes: [])], to: &blank)
        let b = SpecParser.parse(blank.spec, language: .mermaid)
        #expect(b.family == .c4 && b.nodes.map(\.kind) == [.person], "\(blank.spec)")
        #expect(b.diagnostics.isEmpty)
    }

    @Test func ambiguousShapesOfferChoices() {
        var state = DrawingState(language: .mermaid, spec: "C4Context\n  System(s, \"Shop\")\n")
        let result = InkCommit.apply([
            .shape(.rectangle, Rect(x: 400, y: 300, width: 160, height: 80)),
            .text("Billing", bounds: Rect(x: 440, y: 330, width: 60, height: 20), strokes: []),
        ], to: &state)
        #expect(result.choices.count == 1)
        #expect(result.choices.first?.options.prefix(2) == [.container, .system])
        // Picking another option rewrites the declaration in place.
        let id = result.choices[0].id
        Engine.updateNode(&state, id: id, NodeEdit(kind: .system))
        let after = SpecParser.parse(state.spec, language: .mermaid)
        #expect(after.node(id)?.kind == .system, "\(state.spec)")
        #expect(after.node(id)?.title == "Billing")
        #expect(after.diagnostics.isEmpty)

        // Unambiguous shapes don't ask.
        var er = DrawingState(language: .mermaid, spec: "erDiagram\n  A {\n    int id\n  }\n")
        #expect(InkCommit.apply([.shape(.rectangle, Rect(x: 400, y: 300, width: 160, height: 80))], to: &er).choices.isEmpty)
    }

    @Test func blankStartersHaveTheirType() {
        for language in SpecLanguage.allCases {
            for family in DiagramStarter.families {
                let spec = DiagramStarter.blankSpec(family, language: language)
                let parsed = SpecParser.parse(spec, language: language)
                #expect(parsed.family == family, "\(language) \(family)")
                #expect(parsed.diagnostics.isEmpty, "\(language) \(family) \(parsed.diagnostics)")
                #expect(DiagramStarter.example(family, language: language) != nil)
                // Drawing a box gives that type's main element, and the type sticks.
                var state = DrawingState(language: language, spec: spec)
                InkCommit.apply([.shape(.rectangle, Rect(x: 0, y: 0, width: 160, height: 80))], to: &state)
                let after = SpecParser.parse(state.spec, language: language)
                #expect(after.family == family, "\(language) \(family): \(state.spec)")
                #expect(after.nodes.count == 1 && after.diagnostics.isEmpty, "\(language) \(family): \(state.spec) \(after.diagnostics)")
            }
        }
    }

    @Test func placeholderNameFollowsKind() {
        for language in SpecLanguage.allCases {
            var state = DrawingState(language: language, spec: DiagramStarter.blankSpec(.flowchart, language: language))
            let r = InkCommit.apply([.shape(.ellipse, Rect(x: 0, y: 0, width: 160, height: 80))], to: &state)
            let c = r.choices[0]
            #expect(c.needsName)
            let first = SpecParser.parse(state.spec, language: language).node(c.id)!
            #expect(first.title == first.kind.displayName)
            let other = c.options[1]
            let id = Engine.updateNode(&state, id: c.id, NodeEdit(kind: other))
            let after = SpecParser.parse(state.spec, language: language)
            #expect(after.node(id)?.kind == other, "\(language): \(state.spec)")
            #expect(after.node(id)?.title == other.displayName, "\(language): \(state.spec)")
            #expect(after.diagnostics.isEmpty)
            // A real name is left alone.
            Engine.updateNode(&state, id: id, NodeEdit(title: "Billing"))
            let named = SpecParser.parse(state.spec, language: language).nodes.first { $0.title == "Billing" }!
            let id2 = Engine.updateNode(&state, id: named.id, NodeEdit(kind: first.kind))
            #expect(SpecParser.parse(state.spec, language: language).node(id2)?.title == "Billing")
        }
    }

    /// Draws a rectangle around everything currently in the diagram.
    func around(_ state: inout DrawingState) -> Rect {
        let parsed = Engine.reconcile(&state)
        let b = DiagramGeometry(parsed: parsed, state: state, measure: approximateMeasurer).bounds!
        return Rect(x: b.minX - 30, y: b.minY - 40, width: b.size.width + 60, height: b.size.height + 80)
    }

    @Test func drawingAroundElementsGroupsThem() {
        let cases: [(SpecLanguage, String, NodeKind)] = [
            (.mermaid, "flowchart TD\n  A[Alpha] --> B[Beta]\n", .group),
            (.plantUML, "@startuml\ncomponent Alpha\ncomponent Beta\nAlpha --> Beta\n@enduml\n", .group),
            (.mermaid, "classDiagram\n  class Order\n  class Line\n  Order --> Line\n", .group),
            (.plantUML, "@startuml\nclass Order {\n  +id : UUID\n}\nclass Line\nOrder --> Line\n@enduml\n", .group),
            (.mermaid, "C4Container\n  Container(web, \"Web\")\n  ContainerDb(db, \"DB\")\n  Rel(web, db, \"reads\")\n", .boundary),
            (.plantUML, "@startuml\n!include <C4/C4_Container>\nContainer(web, \"Web\")\nContainerDb(db, \"DB\")\nRel(web, db, \"reads\")\n@enduml\n", .boundary),
        ]
        for (language, spec, kind) in cases {
            var state = DrawingState(language: language, spec: spec)
            let before = SpecParser.parse(spec, language: language)
            let rect = around(&state)
            let result = InkCommit.apply([.shape(.rectangle, rect), .text("Core", bounds: Rect(x: rect.minX + 10, y: rect.minY + 8, width: 40, height: 16), strokes: [])], to: &state)
            let after = SpecParser.parse(state.spec, language: language)
            let group = after.nodes.first { $0.kind == kind }
            #expect(group?.title == "Core", "\(language): \(state.spec)")
            #expect(Set(after.children(of: group?.id ?? "").map(\.id)) == Set(before.nodes.map(\.id)), "\(language): \(state.spec)")
            #expect(after.edges.count == before.edges.count)
            #expect(after.diagnostics.isEmpty, "\(language): \(after.diagnostics) \(state.spec)")
            if spec.contains("+id") { #expect(after.node("Order")?.fields.count == 1, "members survive the move: \(state.spec)") }
            #expect(result.created.contains(.node(group?.id ?? "")))
            // Keeps the size it was drawn at.
            let frame = DiagramGeometry(parsed: after, state: state, measure: approximateMeasurer).frames[group!.id]!
            #expect(frame.size.width >= rect.size.width - 1 && frame.size.height >= rect.size.height - 1)
        }
    }

    @Test func drawingInsideAContainerMakesChildren() {
        for language in SpecLanguage.allCases {
            var state = DrawingState(language: language, spec: DiagramStarter.blankSpec(.c4, language: language))
            // A container drawn big, then components drawn inside it in a later batch.
            InkCommit.apply([.shape(.rectangle, Rect(x: 0, y: 0, width: 500, height: 320)),
                             .text("Shop API", bounds: Rect(x: 200, y: 10, width: 80, height: 18), strokes: [])], to: &state)
            let api = SpecParser.parse(state.spec, language: language).nodes.first { $0.title == "Shop API" }!
            #expect(api.kind == .container)
            InkCommit.apply([.shape(.rectangle, Rect(x: 30, y: 80, width: 160, height: 80)),
                             .text("Orders", bounds: Rect(x: 60, y: 110, width: 60, height: 18), strokes: []),
                             .shape(.rectangle, Rect(x: 280, y: 80, width: 160, height: 80)),
                             .text("Payments", bounds: Rect(x: 310, y: 110, width: 70, height: 18), strokes: [])], to: &state)
            let p = SpecParser.parse(state.spec, language: language)
            let boundary = p.nodes.first { $0.title == "Shop API" }!
            #expect(boundary.kind == .boundary && boundary.stereotype == "Container", "\(language): \(state.spec)")
            #expect(Set(p.children(of: boundary.id).map(\.title)) == ["Orders", "Payments"], "\(language): \(state.spec)")
            #expect(state.spec.contains("Container_Boundary("))
            #expect(p.diagnostics.isEmpty, "\(p.diagnostics)")
            // The boundary keeps the container's size.
            let f = DiagramGeometry(parsed: p, state: state, measure: approximateMeasurer).frames[boundary.id]!
            #expect(f.size.width >= 499, "\(f)")
        }
        // Classes don't swallow shapes drawn on them.
        var cls = DrawingState(language: .mermaid, spec: "classDiagram\n  class Order\n")
        let parsed = Engine.reconcile(&cls)
        let f = DiagramGeometry(parsed: parsed, state: cls, measure: approximateMeasurer).frames["Order"]!
        InkCommit.apply([.shape(.rectangle, Rect(x: f.midX - 10, y: f.midY - 10, width: 20, height: 20))], to: &cls)
        #expect(SpecParser.parse(cls.spec, language: .mermaid).node("Order")?.kind == .classType)
    }

    @Test func boxesWithTailsAreBoxes() {
        // Pen starts left of the corner, goes round, and overshoots the start (as in a real sketch).
        let tailed = Pen.polyline([Point(x: -50, y: 2), Point(x: 0, y: 0), Point(x: 10, y: 120), Point(x: 300, y: 115),
                                   Point(x: 305, y: -20), Point(x: 5, y: 4), Point(x: 30, y: 30)])
        #expect(kinds(InkRecognizer.recognize([tailed])) == ["rectangle"])
        if case let .shape(_, r) = InkRecognizer.recognize([tailed]).first { #expect(r.minX > -10, "\(r)") }
    }
}
