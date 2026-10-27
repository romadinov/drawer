import Foundation

/// Parses the Mermaid diagram types that make sense to lay out by hand:
/// flowchart/graph, classDiagram, erDiagram and C4 (C4Context, C4Container, C4Component, C4Dynamic, C4Deployment).
struct MermaidParser {
    let source: String
    let lines: [SourceLine]
    let builder = DiagramBuilder()

    init(_ source: String) {
        self.source = source
        lines = SourceLine.split(source)
    }

    func parse() -> ParsedDiagram {
        var index = 0
        // Optional YAML front matter.
        if let first = lines.first, first.trimmed == "---" {
            index = 1
            while index < lines.count, lines[index].trimmed != "---" { index += 1 }
            index += 1
        }
        while index < lines.count, isBlank(lines[index]) { index += 1 }
        let insertion = (source as NSString).length
        guard index < lines.count else {
            return builder.finish(family: .flowchart, direction: .topDown, title: nil, insertionOffset: insertion)
        }
        let header = lines[index].trimmed
        let body = Array(lines[(index + 1)...])
        let words = header.split(separator: " ").map(String.init)
        let keyword = words.first ?? ""

        switch keyword {
        case "flowchart", "graph":
            let direction = Self.direction(words.dropFirst().first ?? "TD")
            return parseFlowchart(body, direction: direction, insertion: insertion)
        case "classDiagram", "classDiagram-v2":
            return parseClass(body, insertion: insertion)
        case "erDiagram":
            return parseER(body, insertion: insertion)
        case "sequenceDiagram":
            var parser = SequenceParser(dialect: .mermaid, lines: body)
            return parser.parse(insertionOffset: insertion)
        case _ where keyword.hasPrefix("C4"):
            return parseC4(body, insertion: insertion)
        default:
            builder.diagnostics.append(Diagnostic(line: lines[index].number,
                message: "Unsupported Mermaid diagram type '\(keyword)'. Supported: flowchart, classDiagram, sequenceDiagram, erDiagram, C4Context/C4Container/C4Component.",
                severity: .error))
            return builder.finish(family: .flowchart, direction: .topDown, title: nil, insertionOffset: insertion)
        }
    }

    private func isBlank(_ line: SourceLine) -> Bool {
        let t = line.trimmed
        return t.isEmpty || t.hasPrefix("%%")
    }

    static func direction(_ s: String) -> Direction {
        switch s.uppercased() {
        case "LR": .leftRight
        case "RL": .rightLeft
        case "BT": .bottomUp
        default: .topDown
        }
    }

    private func warn(_ line: SourceLine, _ message: String) {
        builder.diagnostics.append(Diagnostic(line: line.number, message: message))
    }

    // MARK: Flowchart

    private static let ignoredFlowKeywords = ["classDef", "class ", "style ", "linkStyle", "click ", "direction ", "accTitle", "accDescr"]

    private func parseFlowchart(_ body: [SourceLine], direction: Direction, insertion: Int) -> ParsedDiagram {
        var groups: [String] = []
        var title: String?
        for line in body {
            let t = line.trimmed
            if t.isEmpty || t.hasPrefix("%%") { continue }
            if Self.ignoredFlowKeywords.contains(where: { t.hasPrefix($0) }) { continue }
            if t.hasPrefix("title ") { title = String(t.dropFirst(6)); continue }
            if t == "end" {
                if let g = groups.popLast() { builder.extendDeclaration(g, to: line) }
                continue
            }
            if t.hasPrefix("subgraph") {
                parseSubgraph(line, parent: groups.last, groups: &groups)
                continue
            }
            var scanner = FlowScanner(line: line)
            scanner.scanStatement(builder: builder, parent: groups.last)
            if !scanner.consumedAll {
                warn(line, "Could not understand part of this line: \(scanner.remainder)")
            }
        }
        builder.setImplicitKind(.box)
        return builder.finish(family: .flowchart, direction: direction, title: title, insertionOffset: insertion)
    }

    private static let subgraphRegex = NSRegularExpression(#"^\s*subgraph\s+(?:([\w\-]+)\s*\[\s*"?([^"\]]*)"?\s*\]|"([^"]+)"|(.+?))\s*$"#)

    private func parseSubgraph(_ line: SourceLine, parent: String?, groups: inout [String]) {
        guard let m = Self.subgraphRegex.firstMatch(in: line.ns) else {
            let id = "subgraph\(line.number)"
            builder.declare(id, kind: .group, title: "", declaration: line.span, standalone: true, parent: parent)
            groups.append(id)
            return
        }
        let id: String
        var title: String?
        var titleSpan: SourceSpan?
        if let explicitID = m.string(1, in: line.ns) {
            id = explicitID
            title = m.string(2, in: line.ns)
            titleSpan = line.span(m.range(at: 2))
        } else if let quoted = m.string(3, in: line.ns) {
            id = quoted
            title = quoted
            titleSpan = line.span(m.range(at: 3))
        } else {
            id = m.string(4, in: line.ns) ?? "subgraph\(line.number)"
            title = id
            titleSpan = line.span(m.range(at: 4))
        }
        builder.declare(id, kind: .group, title: title, titleSpan: titleSpan, declaration: line.span, standalone: true, parent: parent)
        groups.append(id)
    }

    // MARK: Class diagram

    private static let classDecl = NSRegularExpression(#"^\s*class\s+([\w]+)(?:~([^~]+)~)?(?:\s*\[\s*"([^"]*)"\s*\])?\s*(?::::\w+)?\s*(\{)?\s*(\})?\s*$"#)
    private static let annotationLine = NSRegularExpression(#"^\s*<<\s*([^>]+?)\s*>>\s*([\w]+)?\s*$"#)
    private static let memberLine = NSRegularExpression(#"^\s*([\w]+)\s*:\s*(.+?)\s*$"#)
    private static let namespaceLine = NSRegularExpression(#"^\s*namespace\s+([\w.]+)\s*\{\s*$"#)

    private func parseClass(_ body: [SourceLine], insertion: Int) -> ParsedDiagram {
        let relations = RelationParser()
        var direction = Direction.topDown
        var openClass: String?
        var namespaces: [String] = []
        var title: String?
        for line in body {
            let t = line.trimmed
            if t.isEmpty || t.hasPrefix("%%") { continue }
            if let cls = openClass {
                builder.extendDeclaration(cls, to: line)
                if t == "}" { openClass = nil; continue }
                if let m = Self.annotationLine.firstMatch(in: line.ns) {
                    applyStereotype(m.string(1, in: line.ns)!, to: cls)
                    continue
                }
                addMember(t, to: cls)
                continue
            }
            if t == "}" {
                if let ns = namespaces.popLast() { builder.extendDeclaration(ns, to: line) }
                continue
            }
            if t.hasPrefix("direction ") { direction = Self.direction(String(t.dropFirst(10))); continue }
            if t.hasPrefix("title ") { title = String(t.dropFirst(6)); continue }
            if t.hasPrefix("note") || t.hasPrefix("link ") || t.hasPrefix("click ") || t.hasPrefix("callback ")
                || t.hasPrefix("cssClass") || t.hasPrefix("style ") || t.hasPrefix("classDef") { continue }
            if let m = Self.namespaceLine.firstMatch(in: line.ns) {
                let id = m.string(1, in: line.ns)!
                builder.declare(id, kind: .group, title: id, titleSpan: line.span(m.range(at: 1)), declaration: line.span, standalone: true, parent: namespaces.last)
                builder.update(id) { $0.titleIsIdentifier = true }
                namespaces.append(id)
                continue
            }
            if let m = Self.classDecl.firstMatch(in: line.ns) {
                let id = m.string(1, in: line.ns)!
                let label = m.string(3, in: line.ns)
                let existingKind = builder.node(id).map(\.kind)
                let kind = existingKind.flatMap { $0.isClassifier ? $0 : nil } ?? .classType
                builder.declare(id, kind: kind, title: label,
                                titleSpan: label != nil ? line.span(m.range(at: 3)) : line.span(m.range(at: 1)),
                                declaration: line.span, standalone: true, parent: namespaces.last)
                if label == nil { builder.update(id) { $0.titleIsIdentifier = true; $0.title = id } }
                if let generic = m.string(2, in: line.ns) {
                    builder.update(id) { $0.title += "<\(generic)>" }
                }
                if m.has(4) && !m.has(5) { openClass = id }
                continue
            }
            if let m = Self.annotationLine.firstMatch(in: line.ns), let id = m.string(2, in: line.ns) {
                builder.ensure(id, kind: .classType, reference: line.span)
                applyStereotype(m.string(1, in: line.ns)!, to: id)
                continue
            }
            if let r = relations.parse(line) {
                addRelation(r, line: line, implicitKind: .classType)
                continue
            }
            if let m = Self.memberLine.firstMatch(in: line.ns) {
                let id = m.string(1, in: line.ns)!
                builder.ensure(id, kind: .classType, reference: line.span)
                addMember(m.string(2, in: line.ns)!, to: id)
                continue
            }
            warn(line, "Unrecognised class diagram statement")
        }
        return builder.finish(family: .classDiagram, direction: direction, title: title, insertionOffset: insertion)
    }

    private func applyStereotype(_ stereotype: String, to id: String) {
        builder.update(id) { node in
            node.stereotype = stereotype
            switch stereotype.lowercased() {
            case "interface": node.kind = .interfaceType
            case "abstract": node.kind = .abstractClass
            case "enumeration", "enum": node.kind = .enumType
            default: break
            }
        }
    }

    private func addMember(_ member: String, to id: String) {
        let m = member.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        builder.update(id) { node in
            if m.contains("(") { node.methods.append(m) } else { node.fields.append(m) }
        }
    }

    private func addRelation(_ r: RelationParser.Result, line: SourceLine, implicitKind: NodeKind) {
        builder.ensure(r.from, kind: implicitKind, reference: line.span(r.fromSpan))
        builder.ensure(r.to, kind: implicitKind, reference: line.span(r.toSpan))
        var edge = DiagramEdge(from: r.from, to: r.to, line: r.line, startMarker: r.startMarker, endMarker: r.endMarker)
        edge.label = r.label
        edge.labelSpan = r.labelSpan.map { line.span($0) }
        edge.fromLabel = r.fromLabel
        edge.toLabel = r.toLabel
        edge.span = line.span
        edge.spanIsStandalone = true
        builder.edges.append(edge)
    }

    // MARK: ER diagram

    private static let entityDecl = NSRegularExpression(#"^\s*([A-Za-z_][\w\-]*)\s*(?:\[\s*"?([^"\]]*)"?\s*\])?\s*(\{)?\s*(\})?\s*$"#)

    private func parseER(_ body: [SourceLine], insertion: Int) -> ParsedDiagram {
        let relations = RelationParser(allowHyphenInIdentifiers: true)
        var direction = Direction.topDown
        var openEntity: String?
        var title: String?
        for line in body {
            let t = line.trimmed
            if t.isEmpty || t.hasPrefix("%%") { continue }
            if let entity = openEntity {
                builder.extendDeclaration(entity, to: line)
                if t == "}" { openEntity = nil; continue }
                builder.update(entity) { $0.fields.append(t) }
                continue
            }
            if t.hasPrefix("direction ") { direction = Self.direction(String(t.dropFirst(10))); continue }
            if t.hasPrefix("title ") { title = String(t.dropFirst(6)); continue }
            if let r = relations.parse(line) {
                addRelation(r, line: line, implicitKind: .entity)
                continue
            }
            if let m = Self.entityDecl.firstMatch(in: line.ns) {
                let id = m.string(1, in: line.ns)!
                let alias = m.string(2, in: line.ns)
                builder.declare(id, kind: .entity, title: alias,
                                titleSpan: alias != nil ? line.span(m.range(at: 2)) : line.span(m.range(at: 1)),
                                declaration: line.span, standalone: true, parent: nil)
                if alias == nil { builder.update(id) { $0.titleIsIdentifier = true; $0.title = id } }
                if m.has(3) && !m.has(4) { openEntity = id }
                continue
            }
            warn(line, "Unrecognised ER statement")
        }
        return builder.finish(family: .erDiagram, direction: direction, title: title, insertionOffset: insertion)
    }

    // MARK: C4

    private func parseC4(_ body: [SourceLine], insertion: Int) -> ParsedDiagram {
        var groups: [String?] = []
        var title: String?
        for line in body {
            let t = line.trimmed
            if t.isEmpty || t.hasPrefix("%%") { continue }
            if t.hasPrefix("title ") { title = String(t.dropFirst(6)); continue }
            if t == "}" {
                if let g = groups.popLast(), let id = g { builder.extendDeclaration(id, to: line) }
                continue
            }
            if C4Macro.handle(line, builder: builder, groups: &groups) { continue }
            if C4Macro.macroLine.firstMatch(in: line.ns) != nil { continue } // UpdateElementStyle(...) etc.
            warn(line, "Unrecognised C4 statement")
        }
        builder.setImplicitKind(.system)
        return builder.finish(family: .c4, direction: .topDown, title: title, insertionOffset: insertion)
    }
}

// MARK: - Flowchart statement scanner

/// Scans `A[Label] -->|text| B & C --> D` style statements.
struct FlowScanner {
    let line: SourceLine
    private let ns: NSString
    private var pos = 0

    init(line: SourceLine) {
        self.line = line
        ns = line.ns
    }

    var consumedAll: Bool {
        var i = pos
        while i < ns.length {
            let c = ns.character(at: i)
            if c != 32 && c != 9 && c != 59 { return false } // space, tab, ;
            i += 1
        }
        return true
    }

    var remainder: String { ns.substring(from: min(pos, ns.length)) }

    private struct NodeRef {
        var id: String
        var idRange: NSRange
        var kind: NodeKind?
        var label: String?
        var labelRange: NSRange?
    }

    private static let shapes: [(open: String, close: String, kind: NodeKind)] = [
        ("(((", ")))", .circle), ("([", "])", .stadium), ("[[", "]]", .box), ("[(", ")]", .database),
        ("((", "))", .circle), ("{{", "}}", .hexagon), ("[/", "/]", .parallelogram), ("[\\", "\\]", .parallelogram),
        ("[/", "\\]", .box), ("[\\", "/]", .box), (">", "]", .box), ("(", ")", .rounded), ("[", "]", .box), ("{", "}", .diamond),
    ]

    private mutating func skipSpaces() {
        while pos < ns.length, [32, 9].contains(ns.character(at: pos)) { pos += 1 }
    }

    private func hasPrefix(_ s: String, at i: Int) -> Bool {
        let len = (s as NSString).length
        guard i + len <= ns.length else { return false }
        return ns.substring(with: NSRange(location: i, length: len)) == s
    }

    private mutating func scanNode() -> NodeRef? {
        skipSpaces()
        let start = pos
        while pos < ns.length {
            let c = ns.character(at: pos)
            let isIDChar = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
            if !isIDChar { break }
            pos += 1
        }
        guard pos > start else { return nil }
        var ref = NodeRef(id: ns.substring(with: NSRange(location: start, length: pos - start)),
                          idRange: NSRange(location: start, length: pos - start))
        for shape in Self.shapes where hasPrefix(shape.open, at: pos) {
            // Make sure this is not the start of a link such as "A-->B" (">" handled by link scanner first char check).
            if shape.open == ">" { continue }
            let contentStart = pos + (shape.open as NSString).length
            var i = contentStart
            var labelRange: NSRange
            if i < ns.length, ns.character(at: i) == 34 { // quoted label
                let q = ns.range(of: "\"", options: [], range: NSRange(location: i + 1, length: ns.length - i - 1))
                guard q.location != NSNotFound else { continue }
                labelRange = NSRange(location: i + 1, length: q.location - i - 1)
                i = q.location + 1
                guard hasPrefix(shape.close, at: i) else { continue }
            } else {
                let c = ns.range(of: shape.close, options: [], range: NSRange(location: i, length: ns.length - i))
                guard c.location != NSNotFound else { continue }
                labelRange = NSRange(location: i, length: c.location - i)
                i = c.location
            }
            ref.kind = shape.kind
            ref.label = ns.substring(with: labelRange)
            ref.labelRange = labelRange
            pos = i + (shape.close as NSString).length
            break
        }
        // ":::className" suffix
        if hasPrefix(":::", at: pos) {
            pos += 3
            while pos < ns.length, ns.character(at: pos) != 32 { pos += 1 }
        }
        return ref
    }

    private mutating func scanGroup() -> [NodeRef]? {
        guard let first = scanNode() else { return nil }
        var refs = [first]
        while true {
            let save = pos
            skipSpaces()
            if pos < ns.length, ns.character(at: pos) == 38 { // &
                pos += 1
                if let next = scanNode() { refs.append(next); continue }
            }
            pos = save
            break
        }
        return refs
    }

    private struct Link {
        var line: EdgeLineStyle
        var start: EdgeMarker
        var end: EdgeMarker
        var label: String?
        var labelRange: NSRange?
    }

    private static let textLink = NSRegularExpression(#"^\s*([<xo]?)(--|==|-\.)(?![-=.>])\s*([^|]+?)\s*(-{2,}|={2,}|\.+-)([>xo]?)(?=\s|$|[\w"])"#)
    private static let plainLink = NSRegularExpression(#"^\s*([<xo]?)(-{2,}|-\.+-|={2,}|~{3,})([>xo]?)"#)
    private static let pipeLabel = NSRegularExpression(#"^\s*\|\s*"?([^|"]*)"?\s*\|"#)

    private mutating func scanLink() -> Link? {
        let rest = NSRange(location: pos, length: ns.length - pos)
        func marker(_ s: String) -> EdgeMarker {
            switch s {
            case ">", "<": .filledArrow
            case "x": .cross
            case "o": .circle
            default: .none
            }
        }
        func style(_ body: String) -> EdgeLineStyle {
            if body.contains(".") { return .dashed }
            if body.contains("=") { return .thick }
            if body.contains("~") { return .invisible }
            return .solid
        }
        if let m = Self.textLink.firstMatch(in: ns as String, options: [], range: rest) {
            pos = m.range.location + m.range.length
            return Link(line: style(m.string(2, in: ns)! + m.string(4, in: ns)!),
                        start: marker(m.string(1, in: ns)!), end: marker(m.string(5, in: ns)!),
                        label: stripQuotes(m.string(3, in: ns)!), labelRange: m.range(at: 3))
        }
        if let m = Self.plainLink.firstMatch(in: ns as String, options: [], range: rest) {
            pos = m.range.location + m.range.length
            var link = Link(line: style(m.string(2, in: ns)!), start: marker(m.string(1, in: ns)!), end: marker(m.string(3, in: ns)!))
            let after = NSRange(location: pos, length: ns.length - pos)
            if let p = Self.pipeLabel.firstMatch(in: ns as String, options: [], range: after) {
                link.label = ns.substring(with: p.range(at: 1)).trimmingCharacters(in: .whitespaces)
                link.labelRange = p.range(at: 1)
                pos = p.range.location + p.range.length
            }
            return link
        }
        return nil
    }

    mutating func scanStatement(builder: DiagramBuilder, parent: String?) {
        guard var previous = scanGroup() else { return }
        var allRefs = previous
        var links: [(from: [NodeRef], to: [NodeRef], link: Link)] = []
        while let link = scanLink() {
            guard let next = scanGroup() else { break }
            links.append((previous, next, link))
            allRefs += next
            previous = next
        }
        let standaloneDeclaration = links.isEmpty && allRefs.count == 1
        for ref in allRefs {
            if let kind = ref.kind {
                builder.declare(ref.id, kind: kind, title: ref.label,
                                titleSpan: ref.labelRange.map { line.span($0) },
                                declaration: line.span, standalone: standaloneDeclaration, parent: parent)
            } else {
                builder.ensure(ref.id, kind: .box, reference: line.span(ref.idRange), parent: parent)
            }
        }
        let edgeCount = links.reduce(0) { $0 + $1.from.count * $1.to.count }
        let anyInlineLabels = allRefs.contains { $0.kind != nil }
        for l in links {
            for a in l.from {
                for b in l.to {
                    var edge = DiagramEdge(from: a.id, to: b.id, line: l.link.line, startMarker: l.link.start, endMarker: l.link.end)
                    edge.label = l.link.label.map(normalizeLabel)
                    edge.labelSpan = l.link.labelRange.map { line.span($0) }
                    edge.span = line.span
                    edge.spanIsStandalone = edgeCount == 1 && !anyInlineLabels
                    builder.edges.append(edge)
                }
            }
        }
    }
}
