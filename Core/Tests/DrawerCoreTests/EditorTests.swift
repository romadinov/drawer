import Testing
@testable import DrawerCore

@Suite struct EditorTests {
    @Test func addNodeAndEdgePlantUML() {
        var e = SpecEditor(spec: "@startuml\nclass A\n@enduml\n", language: .plantUML)
        let id = e.addNode(kind: .classType, title: "Billing Service")
        #expect(id == "BillingService")
        e.addEdge(from: "A", to: id, label: "uses")
        #expect(e.spec.hasSuffix("@enduml\n"))
        #expect(e.parsed.node(id)?.title == "Billing Service")
        #expect(e.parsed.edge("A->BillingService")?.label == "uses")
        #expect(e.parsed.diagnostics.isEmpty, "\(e.parsed.diagnostics) \(e.spec)")
    }

    @Test func addInsideBoundaryC4() {
        var e = SpecEditor(spec: "C4Container\n  System_Boundary(b, \"B\") {\n    Container(a, \"A\")\n  }\n", language: .mermaid)
        let id = e.addNode(kind: .containerDb, title: "Store", parent: "b")
        #expect(e.parsed.node(id)?.parent == "b", "\(e.spec)")
        #expect(e.parsed.node(id)?.kind == .containerDb)
    }

    @Test func deleteKeepsChainedNeighbours() {
        var e = SpecEditor(spec: "flowchart TD\n  A[Alpha] --> B[Beta] --> C[Gamma]\n", language: .mermaid)
        e.delete(nodes: ["A"], edges: [])
        #expect(e.parsed.node("A") == nil)
        #expect(e.parsed.node("B")?.title == "Beta", "\(e.spec)")
        #expect(e.parsed.node("C")?.title == "Gamma")
        #expect(e.parsed.edge("B->C") != nil)
        #expect(e.parsed.edges.count == 1)
    }

    @Test func renameInlineLabel() {
        var e = SpecEditor(spec: "flowchart TD\n  A[Alpha] --> B\n", language: .mermaid)
        e.update(node: "A", NodeEdit(title: "First"))
        #expect(e.spec == "flowchart TD\n  A[First] --> B\n")
        e.update(node: "B", NodeEdit(title: "Second"))
        #expect(e.parsed.node("B")?.title == "Second", "\(e.spec)")
    }

    @Test func renameClassIdentifier() {
        var e = SpecEditor(spec: "classDiagram\n  class Foo {\n    +x\n  }\n  Foo <|-- Bar\n", language: .mermaid)
        let id = e.update(node: "Foo", NodeEdit(title: "Base"))
        #expect(id == "Base")
        #expect(e.parsed.edge("Base->Bar") != nil, "\(e.spec)")
        #expect(e.parsed.node("Base")?.fields == ["+x"])
    }

    @Test func updateMembersRewritesBlock() {
        var e = SpecEditor(spec: "@startuml\nclass Foo {\n  +a\n}\nFoo --> Bar\n@enduml\n", language: .plantUML)
        e.update(node: "Foo", NodeEdit(fields: ["+a", "+b"], methods: ["+run()"]))
        #expect(e.parsed.node("Foo")?.fields == ["+a", "+b"], "\(e.spec)")
        #expect(e.parsed.node("Foo")?.methods == ["+run()"])
        #expect(e.parsed.edges.count == 1)
    }

    @Test func edgeLabelAndReverse() {
        var e = SpecEditor(spec: "@startuml\n!include <C4/C4_Container>\nSystem(a, \"A\")\nSystem(b, \"B\")\nRel(a, b, \"calls\")\n@enduml\n", language: .plantUML)
        e.update(edge: "a->b", EdgeEdit(label: "invokes"))
        #expect(e.parsed.edge("a->b")?.label == "invokes")
        e.update(edge: "a->b", EdgeEdit(reverse: true))
        #expect(e.parsed.edge("b->a")?.label == "invokes", "\(e.spec)")
    }

    @Test func c4ElementUpdate() {
        var e = SpecEditor(spec: "C4Container\n  Container(api, \"API\", \"Go\")\n", language: .mermaid)
        e.update(node: "api", NodeEdit(technology: .some("Rust"), description: .some("Does things")))
        let n = e.parsed.node("api")
        #expect(n?.technology == "Rust", "\(e.spec)")
        #expect(n?.description == "Does things")
    }

    @Test func conversionRoundTrip() {
        for t in DiagramTemplate.all {
            let p = SpecParser.parse(t.spec, language: t.language)
            #expect(p.diagnostics.isEmpty, "\(t.name): \(p.diagnostics)")
            let other: SpecLanguage = t.language == .plantUML ? .mermaid : .plantUML
            let converted = SpecGenerator.generate(p, language: other)
            let q = SpecParser.parse(converted, language: other)
            #expect(q.diagnostics.isEmpty, "\(t.name) → \(other): \(q.diagnostics)\n\(converted)")
            #expect(Set(q.nodes.map(\.id)) == Set(p.nodes.map(\.id)), "\(t.name)\n\(converted)")
            #expect(q.edges.count == p.edges.count, "\(t.name)\n\(converted)")
        }
    }

    @Test func engineIncrementalPlacement() {
        var s = DrawingState(language: .mermaid, spec: "flowchart TD\n  A --> B\n")
        Engine.reconcile(&s)
        #expect(s.layout.count == 2)
        let a = s.layout["A"]!.position
        s.spec += "  B --> C\n"
        Engine.reconcile(&s)
        #expect(s.layout["A"]!.position == a)
        #expect(s.layout["C"]!.position.y > s.layout["B"]!.position.y)
    }
}
