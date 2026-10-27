import Testing
@testable import DrawerCore

@Suite struct ParserTests {
    @Test func mermaidFlowchart() {
        let d = SpecParser.parse("""
        flowchart LR
          A[Start] --> B{Ok?}
          B -->|yes| C(Done)
          B -- no --> A
          C & B -.-> D[(DB)]
          subgraph grp [Group]
            E
          end
        """, language: .mermaid)
        #expect(d.direction == .leftRight)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.node("A")?.title == "Start")
        #expect(d.node("B")?.kind == .diamond)
        #expect(d.node("D")?.kind == .database)
        #expect(d.node("E")?.parent == "grp")
        #expect(d.edges.count == 5)
        #expect(d.edge("B->C")?.label == "yes")
        #expect(d.edge("B->A")?.label == "no")
        #expect(d.edge("C->D")?.line == .dashed)
    }

    @Test func mermaidClass() {
        let d = SpecParser.parse("""
        classDiagram
          class Animal {
            <<abstract>>
            +String name
            +speak() void
          }
          class Dog
          Animal <|-- Dog : extends
          Dog "1" *-- "4" Leg
          Dog : +bark()
        """, language: .mermaid)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.node("Animal")?.kind == .abstractClass)
        #expect(d.node("Animal")?.fields == ["+String name"])
        #expect(d.node("Dog")?.methods == ["+bark()"])
        #expect(d.edge("Animal->Dog")?.startMarker == .triangle)
        #expect(d.edge("Dog->Leg")?.startMarker == .filledDiamond)
        #expect(d.edge("Dog->Leg")?.toLabel == "4")
    }

    @Test func mermaidER() {
        let d = SpecParser.parse("""
        erDiagram
          CUSTOMER ||--o{ ORDER : places
          ORDER ||--|{ LINE-ITEM : "contains"
          CUSTOMER {
            string name PK
            string email
          }
        """, language: .mermaid)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.family == .erDiagram)
        #expect(d.edge("CUSTOMER->ORDER")?.endMarker == .zeroOrMany)
        #expect(d.edge("CUSTOMER->ORDER")?.startMarker == .exactlyOne)
        #expect(d.edge("ORDER->LINE-ITEM")?.label == "contains")
        #expect(d.node("CUSTOMER")?.fields.count == 2)
    }

    @Test func mermaidC4() {
        let d = SpecParser.parse("""
        C4Container
          title Internet Banking
          Person(customer, "Customer", "A bank customer")
          System_Boundary(b, "Banking") {
            Container(web, "Web App", "React", "UI")
            ContainerDb(db, "Database", "Postgres")
          }
          Rel(customer, web, "Uses", "HTTPS")
          Rel_Back(db, web, "Reads")
        """, language: .mermaid)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.family == .c4)
        #expect(d.node("web")?.parent == "b")
        #expect(d.node("web")?.technology == "React")
        #expect(d.node("customer")?.description == "A bank customer")
        #expect(d.edge("customer->web")?.technology == "HTTPS")
        #expect(d.edge("web->db") != nil)
    }

    @Test func plantUMLClassAndComponents() {
        let d = SpecParser.parse("""
        @startuml
        left to right direction
        package Shop {
          abstract class Base <<Entity>> {
            +id : UUID
            --
            +save()
          }
          class "Order Line" as Line
        }
        interface Repo
        Base <|-- Line
        Line ..|> Repo : implements
        [Web UI] --> (Checkout)
        actor Admin
        @enduml
        """, language: .plantUML)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.direction == .leftRight)
        #expect(d.node("Base")?.parent == "Shop")
        #expect(d.node("Base")?.fields == ["+id : UUID"])
        #expect(d.node("Base")?.methods == ["+save()"])
        #expect(d.node("Line")?.title == "Order Line")
        #expect(d.node("Web UI")?.kind == .component)
        #expect(d.node("Checkout")?.kind == .usecase)
        #expect(d.edge("Line->Repo")?.endMarker == .triangle)
        #expect(d.edge("Line->Repo")?.line == .dashed)
    }

    @Test func plantUMLC4() {
        let d = SpecParser.parse("""
        @startuml
        !include <C4/C4_Container>
        LAYOUT_TOP_DOWN()
        Person(u, "User")
        System_Boundary(s, "System") {
          Container(api, "API", "Go", "Serves things")
        }
        Rel(u, api, "Calls", "JSON")
        SHOW_LEGEND()
        @enduml
        """, language: .plantUML)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.family == .c4)
        #expect(d.node("api")?.parent == "s")
        #expect(d.edges.count == 1)
    }

    @Test func plantUMLER() {
        let d = SpecParser.parse("""
        @startuml
        entity Customer {
          *id : number <<PK>>
          --
          name : text
        }
        entity Order
        Customer ||--o{ Order
        @enduml
        """, language: .plantUML)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.family == .erDiagram)
        #expect(d.node("Customer")?.fields.count == 2)
        #expect(d.edge("Customer->Order")?.endMarker == .zeroOrMany)
    }
}

@Suite struct SequenceTests {
    @Test func plantUMLSequence() {
        let d = SpecParser.parse(DiagramTemplate.all.first { $0.name == "Sequence" }!.spec, language: .plantUML)
        #expect(d.family == .sequence)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.node("User")?.kind == .actor)
        #expect(d.node("db")?.kind == .database)
        #expect(d.node("web")?.title == "Web App")
        #expect(d.edges.count == 8)
        #expect(d.edges[3].line == .dashed)
        #expect(d.sequence?.autonumber == true)
        let fragments = d.sequence!.events.filter { if case .fragmentStart = $0.kind { true } else { false } }
        #expect(fragments.count == 1)
        let g = DiagramGeometry(parsed: d, state: { var s = DrawingState(language: .plantUML, spec: ""); s.layout = AutoLayout.layout(d); return s }())
        #expect(g.sequence?.activations.count == 1)
        #expect(g.sequence?.fragments.count == 1)
        let ys = (0..<d.edges.count).compactMap { g.sequence?.messagePaths[$0]?.first?.y }
        #expect(ys == ys.sorted())
    }

    @Test func mermaidSequence() {
        let d = SpecParser.parse(DiagramTemplate.all.first { $0.name == "Sequence (Mermaid)" }!.spec, language: .mermaid)
        #expect(d.family == .sequence)
        #expect(d.diagnostics.isEmpty, "\(d.diagnostics)")
        #expect(d.node("Auth")?.title == "Auth Service")
        #expect(d.edges.count == 5)
        #expect(d.edges[3].endMarker == .arrow)
        #expect(d.edges[4].endMarker == .cross)
        if case let .message(_, activate, _) = d.sequence!.events[0].kind { #expect(activate) }
    }

    @Test func plainArrowsDefaultToSequence() {
        let d = SpecParser.parse("@startuml\nA -> B : hi\nB --> A : ok\n@enduml\n", language: .plantUML)
        #expect(d.family == .sequence)
        let c = SpecParser.parse("@startuml\nclass A\nA --> B\n@enduml\n", language: .plantUML)
        #expect(c.family == .classDiagram)
    }

    @Test func editingSequence() {
        var e = SpecEditor(spec: "sequenceDiagram\n  participant A\n  A->>B: one\n  B-->>A: two\n", language: .mermaid)
        let id = e.addNode(kind: .participant, title: "Cache Server")
        #expect(e.parsed.nodes.map(\.id) == ["A", "CacheServer", "B"], "\(e.spec)")
        e.addEdge(from: "A", to: id, label: "lookup", before: "B->A")
        #expect(e.parsed.edges.map(\.label) == ["one", "lookup", "two"], "\(e.spec)")
        e.update(edge: "A->CacheServer", EdgeEdit(line: .dashed))
        #expect(e.parsed.edges[1].line == .dashed, "\(e.spec)")
        e.delete(nodes: ["B"], edges: [])
        #expect(e.parsed.edges.count == 1, "\(e.spec)")
    }
}
