import Foundation

/// Entry point: parse a spec in the given language.
public enum SpecParser {
    public static func parse(_ spec: String, language: SpecLanguage) -> ParsedDiagram {
        switch language {
        case .plantUML: PlantUMLParser(spec).parse()
        case .mermaid: MermaidParser(spec).parse()
        }
    }

    /// Best-effort language detection for imported text.
    public static func detectLanguage(_ text: String) -> SpecLanguage {
        if text.range(of: "@startuml") != nil || text.range(of: "!include") != nil { return .plantUML }
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("%%") && $0 != "---" } ?? ""
        let mermaidHeaders = ["flowchart", "graph", "classDiagram", "erDiagram", "C4"]
        return mermaidHeaders.contains { first.hasPrefix($0) } ? .mermaid : .plantUML
    }
}

// MARK: - Source lines

struct SourceLine {
    let number: Int      // 1-based
    let text: String
    let ns: NSString
    let offset: Int      // UTF-16 offset of line start in the whole spec
    let length: Int      // UTF-16 length excluding the line terminator

    var span: SourceSpan { SourceSpan(location: offset, length: length) }
    var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    func span(_ r: NSRange) -> SourceSpan { SourceSpan(location: offset + r.location, length: r.length) }
    func string(_ r: NSRange) -> String { ns.substring(with: r) }

    static func split(_ source: String) -> [SourceLine] {
        let ns = source as NSString
        var lines: [SourceLine] = []
        var start = 0
        var number = 1
        while start <= ns.length {
            var lineEnd = 0, contentsEnd = 0
            if start == ns.length {
                lines.append(SourceLine(number: number, text: "", ns: "", offset: start, length: 0))
                break
            }
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let r = NSRange(location: start, length: contentsEnd - start)
            let text = ns.substring(with: r)
            lines.append(SourceLine(number: number, text: text, ns: text as NSString, offset: start, length: r.length))
            number += 1
            if lineEnd == start { break }
            start = lineEnd
        }
        return lines
    }
}

// MARK: - Regex helpers

extension NSRegularExpression {
    convenience init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // Patterns are compile-time constants.
        try! self.init(pattern: pattern, options: options)
    }

    func firstMatch(in ns: NSString) -> NSTextCheckingResult? {
        firstMatch(in: ns as String, options: [], range: NSRange(location: 0, length: ns.length))
    }
}

extension NSTextCheckingResult {
    func has(_ i: Int) -> Bool { range(at: i).location != NSNotFound }
    func string(_ i: Int, in ns: NSString) -> String? {
        has(i) ? ns.substring(with: range(at: i)) : nil
    }
}

func stripQuotes(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { return String(t.dropFirst().dropLast()) }
    return t
}

/// PlantUML and Mermaid both use `\n` (literal) or `<br>` for line breaks in labels.
func normalizeLabel(_ s: String) -> String {
    s.replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "<br/>", with: "\n")
        .replacingOccurrences(of: "<br>", with: "\n")
        .replacingOccurrences(of: "<br />", with: "\n")
}

// MARK: - Builder

/// Accumulates nodes and edges while a parser walks the spec.
final class DiagramBuilder {
    var nodes: [DiagramNode] = []
    private var index: [String: Int] = [:]
    private(set) var implicit: Set<String> = []
    var edges: [DiagramEdge] = []
    var diagnostics: [Diagnostic] = []

    func contains(_ id: String) -> Bool { index[id] != nil }

    @discardableResult
    func ensure(_ id: String, kind: NodeKind, reference: SourceSpan? = nil, parent: String? = nil) -> Int {
        if let i = index[id] {
            if let reference { nodes[i].referenceSpans.append(reference) }
            return i
        }
        var node = DiagramNode(id: id, kind: kind, title: id)
        node.parent = parent
        if let reference { node.referenceSpans.append(reference) }
        nodes.append(node)
        index[id] = nodes.count - 1
        implicit.insert(id)
        return nodes.count - 1
    }

    @discardableResult
    func declare(
        _ id: String,
        kind: NodeKind,
        title: String? = nil,
        titleSpan: SourceSpan? = nil,
        declaration: SourceSpan,
        standalone: Bool,
        parent: String?
    ) -> Int {
        let i = ensure(id, kind: kind, parent: parent)
        implicit.remove(id)
        nodes[i].kind = kind
        if let title {
            nodes[i].title = normalizeLabel(title)
            nodes[i].titleIsIdentifier = false
            nodes[i].titleSpan = titleSpan
        } else if nodes[i].titleSpan == nil {
            nodes[i].titleIsIdentifier = true
        }
        // Prefer a standalone declaration as the canonical one.
        if nodes[i].declarationSpan == nil || standalone || !nodes[i].declarationIsStandalone {
            nodes[i].declarationSpan = declaration
            nodes[i].declarationIsStandalone = standalone
        }
        if nodes[i].parent == nil { nodes[i].parent = parent }
        nodes[i].referenceSpans.append(declaration)
        return i
    }

    func node(_ id: String) -> DiagramNode? { index[id].map { nodes[$0] } }

    func update(_ id: String, _ body: (inout DiagramNode) -> Void) {
        guard let i = index[id] else { return }
        body(&nodes[i])
    }

    func extendDeclaration(_ id: String, to line: SourceLine) {
        update(id) { node in
            if let d = node.declarationSpan { node.declarationSpan = d.union(line.span) }
        }
    }

    func setImplicitKind(_ kind: NodeKind) {
        for id in implicit {
            if let i = index[id] { nodes[i].kind = kind }
        }
    }

    func finish(family: DiagramFamily, direction: Direction, title: String?, insertionOffset: Int) -> ParsedDiagram {
        var counts: [String: Int] = [:]
        for i in edges.indices {
            let base = "\(edges[i].from)->\(edges[i].to)"
            let n = counts[base, default: 0] + 1
            counts[base] = n
            edges[i].id = n == 1 ? base : "\(base)#\(n)"
        }
        var result = ParsedDiagram(family: family, direction: direction)
        result.title = title
        result.nodes = nodes
        result.edges = edges
        result.diagnostics = diagnostics
        result.insertionOffset = insertionOffset
        return result
    }
}

// MARK: - Shared: UML / ER relationship lines

/// Matches `A "1" *-- "many" B : label` style relationships used by PlantUML,
/// Mermaid class diagrams and Mermaid ER diagrams.
struct RelationParser {
    struct Result {
        var from: String
        var fromRaw: String
        var fromSpan: NSRange
        var to: String
        var toRaw: String
        var toSpan: NSRange
        var fromLabel: String?
        var toLabel: String?
        var label: String?
        var labelSpan: NSRange?
        var line: EdgeLineStyle
        var startMarker: EdgeMarker
        var endMarker: EdgeMarker
    }

    let regex: NSRegularExpression

    init(allowHyphenInIdentifiers: Bool = false) {
        let ident = allowHyphenInIdentifiers ? #"[A-Za-z_][\w\-]*\w|[A-Za-z_]"# : #"[A-Za-z_][\w.~]*"#
        let endpoint = #"(\[[^\]]+\]|\([^)]+\)|:[^:]+:|"[^"]+"|"# + ident + ")"
        let left = #"(<\|\||<\||\|o|\|\||\}o|\}\||<<|<|\*|o|\}|#|x|\+|\^)?"#
        let body = #"([-.=]+(?:(?:\[[^\]]*\])|left|right|up|down|le|ri|do|l|r|u|d)*[-.=]*)"#
        let right = #"(\|\|>|\|>|o\{|o\||\|\{|\|\||>>|>|\*|o|\{|#|x|\+|\^)?"#
        let card = #"(?:"([^"]*)"\s*)?"#
        let pattern = #"^\s*"# + endpoint + #"\s*"# + card + left + body + right + #"\s*"# + card + endpoint + #"\s*(?::\s*(.*?))?\s*;?\s*$"#
        regex = NSRegularExpression(pattern, options: [])
    }

    func parse(_ line: SourceLine) -> Result? {
        guard let m = regex.firstMatch(in: line.ns) else { return nil }
        let ns = line.ns
        let bodyText = m.string(4, in: ns) ?? "--"
        // A body must contain at least one real connector character run of 1+ ("-", ".", "=").
        guard bodyText.contains(where: { "-.=".contains($0) }) else { return nil }
        let line: EdgeLineStyle = bodyText.contains(".") ? .dashed : (bodyText.contains("=") ? .thick : .solid)
        let start = Self.leftMarker(m.string(3, in: ns))
        let end = Self.rightMarker(m.string(5, in: ns))
        var labelText = m.string(8, in: ns)?.trimmingCharacters(in: .whitespaces)
        var labelRange: NSRange? = m.has(8) ? m.range(at: 8) : nil
        if let l = labelText, l.hasPrefix("\""), l.hasSuffix("\""), l.count >= 2, let r = labelRange {
            labelText = String(l.dropFirst().dropLast())
            labelRange = NSRange(location: r.location + 1, length: r.length - 2)
        }
        if labelText?.isEmpty == true { labelText = nil; labelRange = nil }
        let fromRaw = m.string(1, in: ns)!
        let toRaw = m.string(7, in: ns)!
        return Result(
            from: Self.endpointID(fromRaw), fromRaw: fromRaw, fromSpan: m.range(at: 1),
            to: Self.endpointID(toRaw), toRaw: toRaw, toSpan: m.range(at: 7),
            fromLabel: m.string(2, in: ns), toLabel: m.string(6, in: ns),
            label: labelText.map(normalizeLabel), labelSpan: labelRange,
            line: line, startMarker: start, endMarker: end)
    }

    static func endpointID(_ raw: String) -> String {
        if raw.count >= 2 {
            let f = raw.first!, l = raw.last!
            if (f == "[" && l == "]") || (f == "(" && l == ")") || (f == ":" && l == ":") || (f == "\"" && l == "\"") {
                return String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }
        return raw
    }

    /// Kind implied by PlantUML endpoint shorthand.
    static func endpointKind(_ raw: String) -> NodeKind? {
        switch raw.first {
        case "[": .component
        case "(": .usecase
        case ":": .actor
        default: nil
        }
    }

    static func leftMarker(_ s: String?) -> EdgeMarker {
        switch s {
        case "<|", "^": .triangle
        case "<", "<<": .arrow
        case "*": .filledDiamond
        case "o": .diamond
        case "x": .cross
        case "+", "#": .circle
        case "||", "<||": .exactlyOne
        case "|o": .zeroOrOne
        case "}o": .zeroOrMany
        case "}|", "}": .oneOrMany
        default: .none
        }
    }

    static func rightMarker(_ s: String?) -> EdgeMarker {
        switch s {
        case "|>", "||>", "^": .triangle
        case ">", ">>": .arrow
        case "*": .filledDiamond
        case "o": .diamond
        case "x": .cross
        case "+", "#": .circle
        case "||": .exactlyOne
        case "o|": .zeroOrOne
        case "o{": .zeroOrMany
        case "|{", "{": .oneOrMany
        default: .none
        }
    }
}

// MARK: - Shared: C4 macros (C4-PlantUML and Mermaid C4)

struct MacroArgument {
    var value: String
    var range: NSRange   // range of the value (without quotes) inside the line
    var isNamed: Bool
}

struct C4Macro {
    enum Role {
        case element(NodeKind, hasTechnology: Bool)
        case boundary(caption: String?, typeArgIndex: Int?)
        case relation(back: Bool, bidirectional: Bool)
        case ignored
    }

    static let macroLine = NSRegularExpression(#"^\s*([A-Za-z_]\w*)\s*\((.*)\)\s*(\{)?\s*(\})?\s*$"#)

    static func role(of name: String) -> Role? {
        switch name {
        case "Person": return .element(.person, hasTechnology: false)
        case "Person_Ext": return .element(.personExt, hasTechnology: false)
        case "System": return .element(.system, hasTechnology: false)
        case "System_Ext": return .element(.systemExt, hasTechnology: false)
        case "SystemDb": return .element(.systemDb, hasTechnology: false)
        case "SystemDb_Ext": return .element(.systemDbExt, hasTechnology: false)
        case "SystemQueue": return .element(.systemQueue, hasTechnology: false)
        case "SystemQueue_Ext": return .element(.systemExt, hasTechnology: false)
        case "Container": return .element(.container, hasTechnology: true)
        case "Container_Ext": return .element(.containerExt, hasTechnology: true)
        case "ContainerDb": return .element(.containerDb, hasTechnology: true)
        case "ContainerDb_Ext": return .element(.containerDbExt, hasTechnology: true)
        case "ContainerQueue": return .element(.containerQueue, hasTechnology: true)
        case "ContainerQueue_Ext": return .element(.containerExt, hasTechnology: true)
        case "Component": return .element(.component4, hasTechnology: true)
        case "Component_Ext": return .element(.component4Ext, hasTechnology: true)
        case "ComponentDb": return .element(.component4Db, hasTechnology: true)
        case "ComponentDb_Ext": return .element(.component4Ext, hasTechnology: true)
        case "ComponentQueue": return .element(.component4Queue, hasTechnology: true)
        case "ComponentQueue_Ext": return .element(.component4Ext, hasTechnology: true)
        case "Boundary": return .boundary(caption: nil, typeArgIndex: 2)
        case "Enterprise_Boundary": return .boundary(caption: "Enterprise", typeArgIndex: nil)
        case "System_Boundary": return .boundary(caption: "System", typeArgIndex: nil)
        case "Container_Boundary": return .boundary(caption: "Container", typeArgIndex: nil)
        case "Deployment_Node", "Deployment_Node_L", "Deployment_Node_R", "Node", "Node_L", "Node_R":
            return .boundary(caption: nil, typeArgIndex: 2)
        default:
            break
        }
        if name.hasPrefix("Rel") || name.hasPrefix("BiRel") {
            let bi = name.hasPrefix("BiRel")
            let suffix = name.dropFirst(bi ? 5 : 3)
            let known = ["", "_Back", "_Neighbor", "_Back_Neighbor", "_U", "_Up", "_D", "_Down", "_L", "_Left", "_R", "_Right", "Index"]
            if known.contains(String(suffix)) {
                return .relation(back: suffix.hasPrefix("_Back"), bidirectional: bi)
            }
        }
        return nil
    }

    /// Splits `a, "b, c", $tag="x"` into arguments, tracking positions relative to the line.
    static func splitArguments(_ line: NSString, range: NSRange) -> [MacroArgument] {
        var result: [MacroArgument] = []
        var i = range.location
        let end = range.location + range.length
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }
        while i < end {
            while i < end, isSpace(line.character(at: i)) { i += 1 }
            if i >= end { break }
            var valueStart = i
            var valueEnd = i
            let named = line.character(at: i) == 36 // "$"
            var depth = 0
            var inQuote = false
            var quoteStart = -1, quoteEnd = -1
            while i < end {
                let c = line.character(at: i)
                if c == 34 { // "
                    if !inQuote { inQuote = true; quoteStart = i + 1 } else { inQuote = false; quoteEnd = i }
                } else if !inQuote {
                    if c == 40 { depth += 1 } else if c == 41 { depth -= 1 } else if c == 44 && depth == 0 { break }
                }
                i += 1
            }
            valueEnd = i
            while valueEnd > valueStart, isSpace(line.character(at: valueEnd - 1)) { valueEnd -= 1 }
            if !named, quoteStart >= 0, quoteEnd >= quoteStart, quoteStart - 1 == valueStart, quoteEnd + 1 == valueEnd {
                valueStart = quoteStart
                valueEnd = quoteEnd
            }
            let r = NSRange(location: valueStart, length: valueEnd - valueStart)
            result.append(MacroArgument(value: line.substring(with: r), range: r, isNamed: named))
            i += 1 // skip comma
        }
        return result
    }

    /// Handles one line. Returns false when the line isn't a C4 macro this parser cares about.
    /// - Parameter groups: stack of open group ids; modified when a boundary opens.
    static func handle(_ line: SourceLine, builder: DiagramBuilder, groups: inout [String?]) -> Bool {
        guard let m = macroLine.firstMatch(in: line.ns) else { return false }
        let name = line.string(m.range(at: 1))
        guard let role = role(of: name) else { return false }
        var args = splitArguments(line.ns, range: m.range(at: 2)).filter { !$0.isNamed }
        if name.hasSuffix("Index"), !args.isEmpty { args.removeFirst() } // Mermaid RelIndex(i, from, to, ...)
        let opensBlock = m.has(3) && !m.has(4)
        let parent = groups.compactMap { $0 }.last
        func arg(_ i: Int) -> MacroArgument? { i < args.count && !args[i].value.isEmpty ? args[i] : nil }

        switch role {
        case .ignored:
            return true
        case let .element(kind, hasTech):
            guard let alias = arg(0)?.value else { return true }
            let title = arg(1)
            builder.declare(alias, kind: kind, title: title?.value ?? alias,
                            titleSpan: title.map { line.span($0.range) },
                            declaration: line.span, standalone: true, parent: parent)
            builder.update(alias) { node in
                if hasTech {
                    node.technology = arg(2).map { normalizeLabel($0.value) }
                    node.description = arg(3).map { normalizeLabel($0.value) }
                } else {
                    node.description = arg(2).map { normalizeLabel($0.value) }
                }
                node.titleIsIdentifier = false
            }
            if opensBlock { groups.append(nil) }
        case let .boundary(caption, typeIndex):
            guard let alias = arg(0)?.value else { return true }
            let title = arg(1)
            builder.declare(alias, kind: .boundary, title: title?.value ?? alias,
                            titleSpan: title.map { line.span($0.range) },
                            declaration: line.span, standalone: true, parent: parent)
            builder.update(alias) { node in
                node.stereotype = typeIndex.flatMap { arg($0)?.value } ?? caption
                node.titleIsIdentifier = false
                if typeIndex != nil { node.description = arg(3)?.value }
            }
            if opensBlock { groups.append(alias) }
        case let .relation(back, bidirectional):
            guard var from = arg(0)?.value, var to = arg(1)?.value else { return true }
            if back { swap(&from, &to) }
            builder.ensure(from, kind: .system, reference: line.span(args[0].range), parent: nil)
            builder.ensure(to, kind: .system, reference: line.span(args[1].range), parent: nil)
            var edge = DiagramEdge(from: from, to: to, line: .solid,
                                   startMarker: bidirectional ? .filledArrow : .none, endMarker: .filledArrow)
            if let l = arg(2) {
                edge.label = normalizeLabel(l.value)
                edge.labelSpan = line.span(l.range)
            }
            edge.technology = arg(3).map { normalizeLabel($0.value) }
            edge.span = line.span
            edge.spanIsStandalone = true
            builder.edges.append(edge)
        }
        return true
    }
}
