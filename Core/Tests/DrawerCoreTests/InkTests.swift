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

@Suite struct InkTests {
    func kinds(_ items: [InkItem]) -> [String] {
        items.map {
            switch $0 {
            case let .shape(k, _): k.rawValue
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
}
