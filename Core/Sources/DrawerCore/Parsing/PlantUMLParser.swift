import Foundation

/// Parses the structural PlantUML diagrams: class, object, component, deployment,
/// use case, IE/ER (`entity`) and C4-PlantUML macros. Sequence/activity/state
/// syntax is reported as unsupported.
struct PlantUMLParser {
    let source: String
    let lines: [SourceLine]
    let builder = DiagramBuilder()

    init(_ source: String) {
        self.source = source
        lines = SourceLine.split(source)
    }

    private static let keywords = [
        "abstract class", "abstract", "class", "interface", "enum", "entity", "annotation", "object", "struct",
        "component", "node", "database", "actor", "usecase", "rectangle", "package", "namespace", "folder",
        "frame", "cloud", "queue", "storage", "artifact", "boundary", "control", "card", "file", "collections",
        "agent", "person", "hexagon", "label", "stack", "circle",
    ]

    private static let declaration: NSRegularExpression = {
        let kw = keywords.map { $0.replacingOccurrences(of: " ", with: #"\s+"#) }.joined(separator: "|")
        return NSRegularExpression(#"^\s*("# + kw + #")\s+(.+?)\s*$"#)
    }()

    /// Name clause: `"Title" as Id`, `Id as "Title"`, `[Title] as Id`, `Id as Alias`, `"Title"`, `[Title]`, `Id`
    /// followed by optional `<<stereotype>>`, `#color`, `{`, `}`.
    private static let nameClause = NSRegularExpression(
        #"^(?:"([^"]+)"\s+as\s+([\w.]+)|([\w.]+)\s+as\s+"([^"]+)"|\[([^\]]+)\]\s+as\s+([\w.]+)|([\w.]+)\s+as\s+([\w.]+)|"([^"]+)"|\[([^\]]+)\]|([\w.]+(?:<[^<>]*>)?))\s*(?:<<\s*(.+?)\s*>>)?\s*(?:#[\w#:\\/;.-]+)?\s*(?:\[\[[^\]]*\]\])?\s*(\{)?\s*(\})?\s*$"#)

    private static let shorthand = NSRegularExpression(#"^\s*(\[[^\]]+\]|\([^)]+\)|:[^:]+:)\s*(?:as\s+([\w.]+))?\s*(?:<<\s*(.+?)\s*>>)?\s*$"#)
    private static let memberShorthand = NSRegularExpression(#"^\s*([\w.]+)\s*:\s*(.+?)\s*$"#)

    private static let ignoredPrefixes = [
        "skinparam", "hide ", "show ", "scale ", "caption ", "header", "footer", "autonumber", "allowmixing",
        "set ", "!", "sprite ", "remove ", "restore ", "allow_mixing", "newpage", "left to right", "top to bottom",
        "title ", "LAYOUT_", "SHOW_", "HIDE_", "AddElementTag", "AddRelTag", "UpdateElementStyle", "UpdateRelStyle",
        "AddBoundaryTag", "UpdateBoundaryStyle", "Lay_", "Legend", "together",
    ]

    private enum Block {
        case group(String)
        case members(String)
        case other
    }

    func parse() -> ParsedDiagram {
        if SequenceParser.looksLikePlantUMLSequence(lines) {
            let end = lines.first { $0.trimmed.hasPrefix("@enduml") }
            var parser = SequenceParser(dialect: .plantUML, lines: end.map { e in lines.filter { $0.number < e.number } } ?? lines)
            return parser.parse(insertionOffset: end?.offset ?? (source as NSString).length)
        }
        let relations = RelationParser()
        var direction = Direction.topDown
        var title: String?
        var stack: [Block] = []
        var inBlockComment = false
        var skipUntil: String?
        var skipBraceDepth = 0
        var insertion = (source as NSString).length
        var usesC4 = false
        var sawEnd = false

        func currentGroup() -> String? {
            for b in stack.reversed() { if case let .group(id) = b { return id } }
            return nil
        }

        for line in lines {
            let t = line.trimmed
            if sawEnd { continue }
            if inBlockComment {
                if t.contains("'/") { inBlockComment = false }
                continue
            }
            if let end = skipUntil {
                if t.lowercased().hasPrefix(end) { skipUntil = nil }
                continue
            }
            if skipBraceDepth > 0 {
                if t.hasSuffix("{") { skipBraceDepth += 1 }
                if t.hasPrefix("}") { skipBraceDepth -= 1 }
                continue
            }
            if t.isEmpty || t.hasPrefix("'") { continue }
            if t.hasPrefix("/'") {
                if !t.contains("'/") { inBlockComment = true }
                continue
            }
            if t.hasPrefix("@startuml") { continue }
            if t.hasPrefix("@enduml") {
                insertion = line.offset
                sawEnd = true
                continue
            }

            // Inside a class/entity body.
            if case let .members(id)? = stack.last {
                builder.extendDeclaration(id, to: line)
                if t.hasPrefix("}") { stack.removeLast(); continue }
                addMember(t, to: id)
                continue
            }

            if t.hasPrefix("!include") && t.contains("C4") { usesC4 = true }
            if t == "left to right direction" { direction = .leftRight; continue }
            if t == "top to bottom direction" { direction = .topDown; continue }
            if t.hasPrefix("title ") { title = String(t.dropFirst(6)); continue }
            if t.hasPrefix("skinparam") && t.hasSuffix("{") { skipBraceDepth = 1; continue }
            if t.hasPrefix("legend") && !t.contains("endlegend") { skipUntil = "endlegend"; continue }
            if t.hasPrefix("note ") || t == "note" {
                if !t.contains(":") && !t.contains("\" as ") { skipUntil = "end note" }
                continue
            }
            if t.hasPrefix("together") && t.hasSuffix("{") { stack.append(.other); continue }
            if t.hasPrefix("}") {
                if let b = stack.popLast(), case let .group(id) = b { builder.extendDeclaration(id, to: line) }
                continue
            }

            // C4 macros.
            var c4Groups: [String?] = stack.map { if case let .group(id) = $0 { id } else { nil } }
            let depth = c4Groups.count
            if C4Macro.handle(line, builder: builder, groups: &c4Groups) {
                usesC4 = true
                if c4Groups.count > depth, let opened = c4Groups.last { stack.append(opened.map { .group($0) } ?? .other) }
                continue
            }
            if Self.ignoredPrefixes.contains(where: { t.hasPrefix($0) }) { continue }
            if C4Macro.macroLine.firstMatch(in: line.ns) != nil, t.first?.isUppercase == true { continue }

            if let r = relations.parse(line) {
                addRelation(r, line: line, parent: currentGroup())
                continue
            }
            if let m = Self.declaration.firstMatch(in: line.ns) {
                handleDeclaration(m, line: line, parent: currentGroup(), stack: &stack)
                continue
            }
            if let m = Self.shorthand.firstMatch(in: line.ns) {
                let raw = m.string(1, in: line.ns)!
                let title = RelationParser.endpointID(raw)
                let id = m.string(2, in: line.ns) ?? title
                let titleRange = NSRange(location: m.range(at: 1).location + 1, length: m.range(at: 1).length - 2)
                builder.declare(id, kind: RelationParser.endpointKind(raw) ?? .component, title: title,
                                titleSpan: line.span(titleRange), declaration: line.span, standalone: true,
                                parent: currentGroup())
                if m.string(2, in: line.ns) == nil { builder.update(id) { $0.titleIsIdentifier = true } }
                if let s = m.string(3, in: line.ns) { builder.update(id) { $0.stereotype = s } }
                continue
            }
            if let m = Self.memberShorthand.firstMatch(in: line.ns), let id = m.string(1, in: line.ns), builder.contains(id) {
                addMember(m.string(2, in: line.ns)!, to: id)
                builder.update(id) { $0.referenceSpans.append(line.span) }
                continue
            }
            if ["start", "stop", "state", "if "].contains(where: { t.hasPrefix($0) }) {
                builder.diagnostics.append(Diagnostic(line: line.number,
                    message: "Activity/state syntax isn't supported — use sequence, class, component, use case, entity or C4 statements.",
                    severity: .warning))
                continue
            }
            builder.diagnostics.append(Diagnostic(line: line.number, message: "Unrecognised statement"))
        }

        let family: DiagramFamily
        if usesC4 || builder.nodes.contains(where: { $0.kind.isC4 }) {
            family = .c4
            builder.setImplicitKind(.system)
        } else if builder.nodes.contains(where: { $0.kind == .entity }) {
            family = .erDiagram
            builder.setImplicitKind(.entity)
        } else if builder.nodes.contains(where: { $0.kind.isClassifier }) || builder.nodes.allSatisfy({ builder.implicit.contains($0.id) }) && !builder.nodes.isEmpty {
            family = .classDiagram
            builder.setImplicitKind(.classType)
        } else {
            family = .flowchart
            builder.setImplicitKind(.component)
        }
        return builder.finish(family: family, direction: direction, title: title, insertionOffset: insertion)
    }

    private func kind(for keyword: String, opensBlock: Bool) -> (NodeKind, isContainer: Bool) {
        let k = keyword.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        switch k {
        case "class", "struct", "annotation", "object": return (.classType, false)
        case "abstract class", "abstract": return (.abstractClass, false)
        case "interface": return (.interfaceType, false)
        case "enum": return (.enumType, false)
        case "entity": return (.entity, false)
        case "component": return opensBlock ? (.group, true) : (.component, false)
        case "node": return opensBlock ? (.group, true) : (.node, false)
        case "database": return opensBlock ? (.group, true) : (.database, false)
        case "actor", "person": return (.actor, false)
        case "usecase": return (.usecase, false)
        case "rectangle", "card", "label", "agent", "collections", "stack": return opensBlock ? (.group, true) : (.box, false)
        case "package", "namespace", "frame": return (.group, true)
        case "folder": return opensBlock ? (.group, true) : (.folder, false)
        case "cloud": return opensBlock ? (.group, true) : (.cloud, false)
        case "queue": return (.queue, false)
        case "storage": return (.database, false)
        case "artifact", "file": return (.artifact, false)
        case "boundary", "control", "circle": return (.circle, false)
        case "hexagon": return (.hexagon, false)
        default: return (.box, false)
        }
    }

    private func handleDeclaration(_ m: NSTextCheckingResult, line: SourceLine, parent: String?, stack: inout [Block]) {
        let keyword = m.string(1, in: line.ns)!
        let restRange = m.range(at: 2)
        let rest = line.string(restRange) as NSString
        guard let n = Self.nameClause.firstMatch(in: rest) else {
            builder.diagnostics.append(Diagnostic(line: line.number, message: "Could not read the name in this declaration"))
            return
        }
        func r(_ i: Int) -> NSRange { NSRange(location: restRange.location + n.range(at: i).location, length: n.range(at: i).length) }
        var id: String
        var title: String?
        var titleRange: NSRange?
        if n.has(1) { title = n.string(1, in: rest); titleRange = r(1); id = n.string(2, in: rest)! }
        else if n.has(3) { id = n.string(3, in: rest)!; title = n.string(4, in: rest); titleRange = r(4) }
        else if n.has(5) { title = n.string(5, in: rest); titleRange = r(5); id = n.string(6, in: rest)! }
        else if n.has(7) { title = n.string(7, in: rest); titleRange = r(7); id = n.string(8, in: rest)! }
        else if n.has(9) { id = n.string(9, in: rest)!; titleRange = r(9) }
        else if n.has(10) { id = n.string(10, in: rest)!; titleRange = r(10) }
        else { id = n.string(11, in: rest)!; titleRange = r(11) }
        let opensBlock = n.has(13) && !n.has(14)
        let (kind, isContainer) = kind(for: keyword, opensBlock: opensBlock)
        // Generic class names: `class Foo<T>` → id "Foo"
        var displayGeneric: String?
        if title == nil, let lt = id.firstIndex(of: "<") {
            displayGeneric = id
            id = String(id[..<lt])
        }
        builder.declare(id, kind: kind, title: title ?? displayGeneric,
                        titleSpan: titleRange.map { line.span($0) },
                        declaration: line.span, standalone: true, parent: parent)
        if title == nil && displayGeneric == nil { builder.update(id) { $0.titleIsIdentifier = true; $0.title = id } }
        if let s = n.string(12, in: rest) {
            builder.update(id) { node in
                node.stereotype = s
                if node.kind == .classType {
                    switch s.lowercased() {
                    case "interface": node.kind = .interfaceType
                    case "abstract": node.kind = .abstractClass
                    case "enum", "enumeration": node.kind = .enumType
                    default: break
                    }
                }
            }
        }
        if opensBlock {
            stack.append(isContainer ? .group(id) : .members(id))
        }
    }

    private func addMember(_ raw: String, to id: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        // Separators: --, .., ==, __ (optionally with a title)
        if let f = t.first, "-.=_".contains(f), t.hasPrefix(String(repeating: f, count: 2)) { return }
        builder.update(id) { node in
            if t.contains("(") && node.kind != .entity { node.methods.append(t) } else { node.fields.append(t) }
        }
    }

    private func addRelation(_ r: RelationParser.Result, line: SourceLine, parent: String?) {
        let fromKind = RelationParser.endpointKind(r.fromRaw)
        let toKind = RelationParser.endpointKind(r.toRaw)
        if let fromKind, !builder.contains(r.from) {
            builder.declare(r.from, kind: fromKind, declaration: line.span, standalone: false, parent: parent)
        }
        builder.ensure(r.from, kind: fromKind ?? .classType, reference: line.span(r.fromSpan), parent: parent)
        if let toKind, !builder.contains(r.to) {
            builder.declare(r.to, kind: toKind, declaration: line.span, standalone: false, parent: parent)
        }
        builder.ensure(r.to, kind: toKind ?? .classType, reference: line.span(r.toSpan), parent: parent)
        var edge = DiagramEdge(from: r.from, to: r.to, line: r.line, startMarker: r.startMarker, endMarker: r.endMarker)
        edge.label = r.label
        edge.labelSpan = r.labelSpan.map { line.span($0) }
        edge.fromLabel = r.fromLabel
        edge.toLabel = r.toLabel
        edge.span = line.span
        edge.spanIsStandalone = true
        builder.edges.append(edge)
    }
}
