import Foundation
import Testing
@testable import DrawerCore

@Suite struct CompletionTests {
    func items(_ spec: String, _ language: SpecLanguage, at marker: String = "|") -> SpecCompleter.Suggestions {
        let cursor = (spec as NSString).range(of: marker).location
        let text = (spec as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return SpecCompleter.suggestions(spec: text, language: language, cursor: cursor)
    }

    @Test func keywordsAndNames() {
        let s = items("@startuml\nclass Order\nclass OrderLine\ncl|\n@enduml\n", .plantUML)
        #expect(s.items.first == "class")
        #expect(s.range.length == 2)
        let names = items("@startuml\nclass Order\nclass OrderLine\nOrd|\n@enduml\n", .plantUML)
        #expect(names.items == ["Order", "OrderLine"])
    }

    @Test func namesAfterArrowAndArrowsAfterName() {
        let after = items("classDiagram\n  class Order\n  class Customer\n  Customer --> Or|\n", .mermaid)
        #expect(after.items == ["Order"])
        let arrows = items("classDiagram\n  class Order\n  Order <|", .mermaid)
        #expect(arrows.items.contains("<|--"))
        let seq = items("sequenceDiagram\n  Alice -|\n", .mermaid)
        #expect(seq.items.contains("->>"))
        let c4 = items("C4Context\n  Person(a, \"A\")\n  System(b, \"B\")\n  Rel(a, |\n", .mermaid)
        #expect(Set(c4.items) == ["a", "b"])
    }
}

@Suite struct VoiceTests {
    @Test func parsesCommands() {
        #expect(VoiceCommand.parse("Add a database called Orders.") == [.add(kind: "database", name: "Orders")])
        #expect(VoiceCommand.parse("connect web app to orders labelled reads and writes") == [.connect(from: "web app", to: "orders", label: "reads and writes")])
        #expect(VoiceCommand.parse("add payment service then connect shop to payment service")
                == [.add(kind: nil, name: "payment service"), .connect(from: "shop", to: "payment service", label: nil)])
        #expect(VoiceCommand.parse("web app calls the API", knownNames: ["Web App", "API"]) == [.connect(from: "web app", to: "API", label: "calls")])
        #expect(VoiceCommand.parse("rename shop to storefront") == [.rename("shop", to: "storefront")])
        #expect(VoiceCommand.parse("make shop an external system") == [.changeKind("shop", kind: "external system")])
        #expect(VoiceCommand.parse("Undo") == [.undo])
    }

    @Test func buildsADiagramByVoice() {
        var state = DrawingState(language: .mermaid, spec: "C4Context\n")
        let out = VoiceCommand.apply(VoiceCommand.parse(
            "add a person called customer then add a system called online shop then connect customer to shop labelled buys from then add a database called orders then online shop writes to orders"),
            to: &state)
        let p = SpecParser.parse(state.spec, language: .mermaid)
        #expect(p.nodes.map(\.kind) == [.person, .system, .containerDb], "\(state.spec)")
        #expect(p.nodes.map(\.title) == ["Customer", "Online Shop", "Orders"])
        #expect(p.edges.map(\.label) == ["buys from", "writes to"], "\(state.spec)")
        #expect(p.diagnostics.isEmpty, "\(p.diagnostics)")
        #expect(out.messages.count == 5)

        let more = VoiceCommand.apply(VoiceCommand.parse("make orders a queue then rename online shop to storefront then delete customer then undo"), to: &state)
        let q = SpecParser.parse(state.spec, language: .mermaid)
        #expect(q.nodes.contains { $0.title == "Orders" && $0.kind == .containerQueue }, "\(state.spec)")
        #expect(q.nodes.contains { $0.title == "Storefront" })
        #expect(!q.nodes.contains { $0.title == "Customer" })
        #expect(more.appActions == [.undo])
    }

    @Test func fuzzyNames() {
        #expect(NameMatcher.best("web app", in: ["Web Application", "API"]) == "Web Application")
        #expect(NameMatcher.best("orders", in: ["Order", "OrderLine"]) == "Order")
        #expect(NameMatcher.best("paymnt", in: ["Payment", "Shop"]) == "Payment")
        #expect(NameMatcher.best("nothing", in: ["Payment"]) == nil)
    }
}
