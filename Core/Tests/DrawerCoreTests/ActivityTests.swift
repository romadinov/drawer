import Testing
@testable import DrawerCore

struct ActivityTests {
    /// Elements and flows by text, so ids and order don't matter.
    func shape(_ p: ParsedDiagram) -> (nodes: [String], edges: [String]) {
        func name(_ id: String) -> String {
            guard let n = p.node(id) else { return id }
            return n.kind.isActivitySymbol ? n.kind.rawValue : "\(n.kind.rawValue):\(n.title)"
        }
        let nodes = p.nodes.map { n -> String in
            let lane = n.parent.flatMap { p.node($0) }.map { " in \($0.title)" } ?? ""
            return name(n.id) + lane
        }.sorted()
        let edges = p.edges.map { "\(name($0.from)) -> \(name($0.to))" + ($0.label.map { " [\($0)]" } ?? "") }.sorted()
        return (nodes, edges)
    }

    func roundTrip(_ spec: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        let parsed = SpecParser.parse(spec, language: .plantUML)
        let written = SpecGenerator.generate(parsed, language: .plantUML)
        let again = SpecParser.parse(written, language: .plantUML)
        #expect(again.family == .activity, sourceLocation: sourceLocation)
        #expect(again.diagnostics.isEmpty, "\(again.diagnostics)\n\(written)", sourceLocation: sourceLocation)
        #expect(shape(again).nodes == shape(parsed).nodes, "\(written)", sourceLocation: sourceLocation)
        #expect(shape(again).edges == shape(parsed).edges, "\(written)", sourceLocation: sourceLocation)
        return written
    }

    let order = DiagramTemplate.all.first { $0.name == "Order Activity" }!.spec

    @Test func readsTheFlow() {
        let p = SpecParser.parse(order, language: .plantUML)
        #expect(p.family == .activity)
        #expect(p.diagnostics.isEmpty)
        let s = shape(p)
        #expect(s.nodes.contains("action:Check stock in Shop"))
        #expect(s.nodes.contains("action:Place order in Customer"))
        #expect(s.nodes.filter { $0.hasPrefix("forkBar") }.count == 2)
        #expect(s.edges.contains("diamond:In stock? -> forkBar [yes]"))
        #expect(s.edges.contains("diamond:In stock? -> action:Refund payment [no]"))
        #expect(s.edges.contains("action:Refund payment -> activityEnd"))
        #expect(s.edges.contains("action:Ship -> action:Receive parcel"))
        #expect(s.edges.contains("action:Pack items -> forkBar"))
        #expect(p.node("CheckStock")?.titleSpan != nil)
        _ = roundTrip(order)
    }

    @Test func loopsSwitchesNotesAndConnectors() {
        let spec = """
        @startuml
        title Payments
        start
        :Read request;
        note right: from the queue
        repeat
          :Charge card;
        backward :Wait a minute;
        repeat while (Declined?) is (yes) not (no)
        while (Items left?) is (yes)
          :Ship item;
        endwhile (no)
        switch (Region?)
        case (EU)
          :Add VAT;
        case (US)
          :Add sales tax;
        case (Other)
        endswitch
        split
          :Email receipt;
        split again
          -> later;
          :Update ledger;
        end split
        :Close;
        stop
        @enduml
        """
        let p = SpecParser.parse(spec, language: .plantUML)
        #expect(p.diagnostics.isEmpty, "\(p.diagnostics)")
        #expect(p.title == "Payments")
        let s = shape(p)
        #expect(s.edges.contains("diamond:Declined? -> action:Wait a minute [yes]"))
        #expect(s.edges.contains("action:Wait a minute -> action:Charge card"))
        #expect(s.edges.contains("diamond:Items left? -> action:Ship item [yes]"))
        #expect(s.edges.contains("action:Ship item -> diamond:Items left?"))
        #expect(s.edges.contains("diamond:Region? -> diamond:Items left? [no]") == false)
        #expect(s.edges.contains("diamond:Region? -> action:Email receipt [Other]"))
        #expect(s.edges.contains("action:Update ledger -> action:Close"))
        #expect(s.edges.contains("note:from the queue -> action:Read request"))
        let written = roundTrip(spec)
        #expect(written.contains("repeat while (Declined?) is (yes) not (no)"))
        #expect(written.contains("backward :Wait a minute;"))
        #expect(written.contains("while (Items left?) is (yes)"))
        #expect(written.contains("note right: from the queue"))
    }

    @Test func unstructuredFlowsJumpThroughConnectors() {
        var state = DrawingState(language: .plantUML, spec: "@startuml\nstart\n:A;\nif (ok?) then (yes)\n  :B;\nelse (no)\n  :C;\nendif\nstop\n@enduml\n")
        Engine.reconcile(&state)
        Engine.addEdge(&state, from: "B", to: "A")
        let p = SpecParser.parse(state.spec, language: .plantUML)
        #expect(p.edges.contains { $0.from == "B" && $0.to == "A" }, "\(state.spec)")
        #expect(p.edges.count == 7, "\(state.spec)")
        _ = roundTrip(state.spec)
    }

    @Test func editsRewriteTheFlow() {
        var state = DrawingState(language: .plantUML, spec: DiagramStarter.blankSpec(.activity, language: .plantUML))
        Engine.reconcile(&state)
        let a = Engine.addNode(&state, kind: .action, title: "Check stock", at: Point(x: 100, y: 120))
        let d = Engine.addNode(&state, kind: .diamond, title: "In stock?", at: Point(x: 100, y: 220))
        let stop = Engine.addNode(&state, kind: .activityStop, title: "Stop", at: Point(x: 100, y: 320))
        #expect(a == "CheckStock" && d == "InStock" && stop == "Stop", "\(state.spec)")
        Engine.addEdge(&state, from: "Start", to: a)
        Engine.addEdge(&state, from: a, to: d)
        Engine.addEdge(&state, from: d, to: stop, label: "yes")
        #expect(state.spec == "@startuml\nstart\n:Check stock;\nif (In stock?) then (yes)\n  stop\nendif\n@enduml\n", "\(state.spec)")

        // Renaming edits the text in place; the id (and its position) follow.
        let position = state.layout[a]?.position
        let renamed = Engine.updateNode(&state, id: a, NodeEdit(title: "Check the stock"))
        #expect(renamed == "CheckTheStock")
        #expect(state.layout["CheckTheStock"]?.position == position)
        #expect(state.spec.contains(":Check the stock;"))

        // Deleting a step joins its neighbours.
        Engine.delete(&state, [.node(renamed)])
        let p = SpecParser.parse(state.spec, language: .plantUML)
        #expect(p.edges.contains { $0.from == "Start" && $0.to == "InStock" }, "\(state.spec)")
    }

    @Test func swimlanesFollowTheirElements() {
        var state = DrawingState(language: .plantUML, spec: order)
        let parsed = Engine.reconcile(&state)
        let customer = parsed.nodes.first { $0.kind == .lane && $0.title == "Customer" }!.id
        var editor = SpecEditor(spec: state.spec, language: .plantUML)
        editor.move(nodes: ["CheckStock"], into: customer)
        let p = SpecParser.parse(editor.spec, language: .plantUML)
        #expect(p.node("CheckStock")?.parent == customer, "\(editor.spec)")
        #expect(p.nodes.filter { $0.kind == .lane }.count == 2)
    }

    @Test func mermaidActivityShapes() {
        let spec = DiagramTemplate.all.first { $0.name == "Activity" && $0.language == .mermaid }!.spec
        let p = SpecParser.parse(spec, language: .mermaid)
        #expect(p.family == .activity)
        #expect(p.diagnostics.isEmpty, "\(p.diagnostics)")
        #expect(p.node("Start")?.kind == .activityStart)
        #expect(p.node("Stop")?.kind == .activityStop)
        #expect(p.node("Fork")?.kind == .forkBar)
        #expect(p.node("Order")?.kind == .action)
        #expect(p.node("InStock")?.kind == .diamond)

        // A drawn start symbol is written with its named shape.
        var state = DrawingState(language: .mermaid, spec: "flowchart TD\n  A(\"Check\")\n  Stop@{ shape: fr-circ }\n")
        Engine.reconcile(&state)
        let id = Engine.addNode(&state, kind: .forkBar, title: "Fork", at: Point(x: 0, y: 0))
        #expect(state.spec.contains("\(id)@{ shape: fork }"))
        #expect(SpecParser.parse(state.spec, language: .mermaid).node(id)?.kind == .forkBar)
    }

    @Test func convertsBetweenLanguagesKeepingLayout() {
        var state = DrawingState(language: .plantUML, spec: order)
        let parsed = Engine.reconcile(&state)
        let before = state.layout["CheckStock"]
        Engine.convert(&state, to: .mermaid, parsed: parsed)
        let m = SpecParser.parse(state.spec, language: .mermaid)
        #expect(m.family == .activity, "\(state.spec)")
        #expect(m.node("CheckStock")?.kind == .action)
        let back = Engine.reconcile(&state)
        Engine.convert(&state, to: .plantUML, parsed: back)
        let p = SpecParser.parse(state.spec, language: .plantUML)
        #expect(p.family == .activity, "\(state.spec)")
        #expect(shape(p).edges == shape(parsed).edges, "\(state.spec)")
        #expect(state.layout["CheckStock"]?.position == before?.position)
    }

    @Test func sketchBecomesAnActivityDiagram() {
        var state = DrawingState(language: .plantUML, spec: DiagramStarter.blankSpec(.activity, language: .plantUML))
        let parsed = Engine.reconcile(&state)
        let start = DiagramGeometry(parsed: parsed, state: state).frames["Start"]!
        let result = InkCommit.apply([
            .shape(.rectangle, Rect(x: 0, y: 100, width: 160, height: 60)),
            .text("Check stock", bounds: Rect(x: 20, y: 120, width: 110, height: 20), strokes: []),
            .shape(.diamond, Rect(x: 20, y: 220, width: 120, height: 80)),
            .text("In stock?", bounds: Rect(x: 45, y: 250, width: 70, height: 20), strokes: []),
            .shape(.rectangle, Rect(x: 0, y: 360, width: 160, height: 12)),
            .shape(.ellipse, Rect(x: 60, y: 460, width: 40, height: 40)),
            .shape(.ellipse, Rect(x: 70, y: 470, width: 20, height: 20)),
            .text(nil, bounds: Rect(x: 72, y: 472, width: 16, height: 16), strokes: [Pen.polyline([Point(x: 72, y: 472), Point(x: 88, y: 488)])]),
            .connector(from: Point(x: start.midX, y: start.maxY + 2), to: Point(x: 80, y: 96), headAtStart: false, headAtEnd: true),
            .connector(from: Point(x: 80, y: 164), to: Point(x: 80, y: 216), headAtStart: false, headAtEnd: true),
            .connector(from: Point(x: 80, y: 304), to: Point(x: 80, y: 356), headAtStart: false, headAtEnd: true),
            .text("yes", bounds: Rect(x: 90, y: 320, width: 30, height: 16), strokes: []),
            .connector(from: Point(x: 80, y: 376), to: Point(x: 80, y: 456), headAtStart: false, headAtEnd: true),
        ], to: &state)
        let p = SpecParser.parse(state.spec, language: .plantUML)
        #expect(p.family == .activity)
        #expect(p.node("CheckStock")?.kind == .action, "\(state.spec)")
        #expect(p.node("InStock")?.kind == .diamond)
        #expect(p.nodes.contains { $0.kind == .forkBar })
        #expect(p.nodes.contains { $0.kind == .activityStop }, "\(state.spec)")
        #expect(state.decorations.isEmpty, "the scribble filling the bullseye is part of it")
        #expect(result.untitled.isEmpty)
        #expect(state.spec.contains("start\n:Check stock;\nif (In stock?) then (yes)"), "\(state.spec)")
        #expect(p.edges.count == 4, "\(state.spec)")
    }
}
