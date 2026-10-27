import Foundation

/// Suggestions for the word being typed in a spec: keywords and element types for the diagram,
/// names of existing elements, and relationship arrows after an element name.
public enum SpecCompleter {
    public struct Suggestions: Equatable, Sendable {
        /// UTF-16 range of the partial word the suggestions replace.
        public var range: NSRange
        public var items: [String]
    }

    public static func suggestions(spec: String, language: SpecLanguage, cursor: Int) -> Suggestions {
        let ns = spec as NSString
        let cursor = min(max(cursor, 0), ns.length)
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        let parsed = SpecParser.parse(spec, language: language)

        // Arrow being typed right after an element name ("Order -" / "A -->").
        let arrowChars = CharacterSet(charactersIn: "-.<>|*o}{x+)")
        let arrowPartial = String(before.reversed().prefix { $0.unicodeScalars.allSatisfy(arrowChars.contains) }.reversed())
        if let first = arrowPartial.first, "-.<".contains(first) {
            let head = before.dropLast(arrowPartial.count)
            if head.last == " " || head.last.map({ $0.isLetter || $0.isNumber || $0 == "\"" || $0 == "]" }) == true,
               !head.trimmingCharacters(in: .whitespaces).isEmpty {
                let arrows = self.arrows(family: parsed.family, language: language).filter { $0.hasPrefix(arrowPartial) && $0 != arrowPartial }
                return Suggestions(range: NSRange(location: cursor - (arrowPartial as NSString).length, length: (arrowPartial as NSString).length), items: arrows)
            }
        }

        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@!"))
        let partial = String(before.reversed().prefix { $0.unicodeScalars.allSatisfy(wordChars.contains) }.reversed())
        let range = NSRange(location: cursor - (partial as NSString).length, length: (partial as NSString).length)
        let prefix = before.dropLast(partial.count).trimmingCharacters(in: .whitespaces)
        let lower = partial.lowercased()
        let ids = parsed.nodes.map(\.id)
        func matching(_ words: [String]) -> [String] {
            var seen = Set<String>()
            return words.filter { $0.lowercased().hasPrefix(lower) && $0 != partial && seen.insert($0).inserted }
        }

        // After an arrow, or inside a relationship macro: element names.
        let afterArrow = prefix.range(of: #"[-.=<>|*o}{]{2,}[>|*o}{]?$|->>?$|-\)$|-x$"#, options: .regularExpression) != nil
        let inMacro = prefix.range(of: #"\b(Rel\w*|BiRel)\($|,\s*$"#, options: .regularExpression) != nil
        if afterArrow || inMacro { return Suggestions(range: range, items: matching(ids)) }
        guard !partial.isEmpty else { return Suggestions(range: range, items: []) }
        // Start of a statement: keywords first, then element names (to start a relationship).
        if prefix.isEmpty {
            return Suggestions(range: range, items: matching(keywords(family: parsed.family, language: language, spec: spec) + ids))
        }
        return Suggestions(range: range, items: matching(ids))
    }

    static func arrows(family: DiagramFamily, language: SpecLanguage) -> [String] {
        switch (family, language) {
        case (.sequence, .plantUML): ["->", "-->", "->>", "-->>", "->x", "<-", "<--"]
        case (.sequence, .mermaid): ["->>", "-->>", "-)", "--)", "-x", "--x", "->", "-->"]
        case (.erDiagram, _): ["||--o{", "||--|{", "||--||", "|o--o{", "}o--o{", "}|--|{"]
        case (.classDiagram, _): ["<|--", "*--", "o--", "-->", "..>", "..|>", "--", ".."]
        case (_, .mermaid): ["-->", "---", "-.->", "==>", "--o", "--x"]
        default: ["-->", "->", "..>", "--", "<|--", "*--", "o--"]
        }
    }

    static func keywords(family: DiagramFamily, language: SpecLanguage, spec: String) -> [String] {
        let c4 = ["Person(", "Person_Ext(", "System(", "System_Ext(", "SystemDb(", "Container(", "ContainerDb(", "ContainerQueue(",
                  "Container_Ext(", "Component(", "ComponentDb(", "Rel(", "BiRel(", "Rel_D(", "Rel_R(", "System_Boundary(", "Container_Boundary(", "Boundary("]
        switch (language, family) {
        case (_, .c4):
            return c4 + (language == .plantUML ? ["!include <C4/C4_Container>", "title", "@startuml", "@enduml", "SHOW_LEGEND()"] : ["title", "C4Context", "C4Container", "C4Component"])
        case (.plantUML, .sequence):
            return ["participant", "actor", "boundary", "control", "entity", "database", "collections", "queue", "activate", "deactivate",
                    "return", "note", "alt", "else", "opt", "loop", "par", "critical", "break", "group", "end", "autonumber", "title",
                    "hide footbox", "@startuml", "@enduml"]
        case (.mermaid, .sequence):
            return ["participant", "actor", "activate", "deactivate", "Note", "loop", "alt", "else", "opt", "par", "and", "critical",
                    "break", "rect", "end", "autonumber", "title", "sequenceDiagram"]
        case (.plantUML, .classDiagram):
            return ["class", "interface", "abstract class", "enum", "package", "namespace", "note", "title", "hide empty members", "@startuml", "@enduml"]
        case (.mermaid, .classDiagram):
            return ["class", "namespace", "direction", "note", "<<interface>>", "<<abstract>>", "<<enumeration>>", "classDiagram"]
        case (.plantUML, .erDiagram):
            return ["entity", "package", "title", "hide circle", "@startuml", "@enduml"]
        case (.mermaid, .erDiagram):
            return ["erDiagram", "title"]
        case (.plantUML, .flowchart):
            return ["component", "rectangle", "database", "queue", "actor", "usecase", "node", "cloud", "folder", "artifact", "package",
                    "frame", "note", "left to right direction", "title", "@startuml", "@enduml"]
        case (.mermaid, .flowchart):
            return ["flowchart TD", "flowchart LR", "subgraph", "end", "classDef", "class", "style", "linkStyle", "direction", "click"]
        }
    }
}
