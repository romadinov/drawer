import Foundation

/// Generates PlantUML / Mermaid statements for nodes and edges.
struct SpecEmitter {
    let language: SpecLanguage
    let family: DiagramFamily

    static func isIdentifier(_ s: String, allowHyphen: Bool = false) -> Bool {
        let pattern = allowHyphen ? #"^[A-Za-z_][A-Za-z0-9_\-]*$"# : #"^[A-Za-z_][A-Za-z0-9_]*$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    var allowsHyphenInIDs: Bool { language == .mermaid && family == .erDiagram }

    /// Text safe to put between double quotes.
    func quoted(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\"", with: "'")
        t = t.replacingOccurrences(of: "\n", with: language == .plantUML ? "\\n" : "<br>")
        return t
    }

    /// Text that replaces an existing title span in place (span excludes surrounding quotes/brackets).
    func inlineTitle(_ s: String) -> String { quoted(s) }

    // MARK: Nodes

    func declaration(for node: DiagramNode, indent: String = "") -> String {
        if family == .sequence { return indent + participant(node) }
        if node.kind.isGroup { return groupOpening(node, indent: indent) + "\n" + groupClosing(indent: indent) }
        if node.kind.isC4 { return indent + c4Element(node) }
        switch language {
        case .mermaid: return mermaidDeclaration(node, indent: indent)
        case .plantUML: return plantDeclaration(node, indent: indent)
        }
    }

    func groupOpening(_ node: DiagramNode, indent: String) -> String {
        if family == .c4 || node.kind == .boundary {
            let macro = switch node.stereotype {
            case "Container": "Container_Boundary"
            case "Enterprise": "Enterprise_Boundary"
            default: "System_Boundary"
            }
            return indent + "\(macro)(\(node.id), \"\(quoted(node.title))\") {"
        }
        switch language {
        case .mermaid:
            if family == .classDiagram { return indent + "namespace \(node.id) {" }
            return indent + "subgraph \(node.id) [\"\(quoted(node.title))\"]"
        case .plantUML:
            return indent + "package \"\(quoted(node.title))\" as \(node.id) {"
        }
    }

    func groupClosing(indent: String) -> String {
        if language == .mermaid && family == .flowchart { return indent + "end" }
        return indent + "}"
    }

    private func c4Element(_ node: DiagramNode) -> String {
        let macro: String = switch node.kind {
        case .person: "Person"
        case .personExt: "Person_Ext"
        case .system: "System"
        case .systemExt: "System_Ext"
        case .systemDb: "SystemDb"
        case .systemDbExt: "SystemDb_Ext"
        case .systemQueue: "SystemQueue"
        case .container: "Container"
        case .containerExt: "Container_Ext"
        case .containerDb: "ContainerDb"
        case .containerDbExt: "ContainerDb_Ext"
        case .containerQueue: "ContainerQueue"
        case .component4: "Component"
        case .component4Ext: "Component_Ext"
        case .component4Db: "ComponentDb"
        case .component4Queue: "ComponentQueue"
        default: "System"
        }
        let hasTech = [.container, .containerExt, .containerDb, .containerDbExt, .containerQueue,
                       .component4, .component4Ext, .component4Db, .component4Queue].contains(node.kind)
        var args = [node.id, "\"\(quoted(node.title))\""]
        if hasTech {
            let tech = node.technology ?? ""
            let descr = node.description ?? ""
            if !tech.isEmpty || !descr.isEmpty { args.append("\"\(quoted(tech))\"") }
            if !descr.isEmpty { args.append("\"\(quoted(descr))\"") }
        } else if let d = node.description, !d.isEmpty {
            args.append("\"\(quoted(d))\"")
        }
        return "\(macro)(\(args.joined(separator: ", ")))"
    }

    private func mermaidDeclaration(_ node: DiagramNode, indent: String) -> String {
        switch family {
        case .classDiagram:
            var head = "class \(node.id)"
            if node.title != node.id && !node.title.isEmpty { head += "[\"\(quoted(node.title))\"]" }
            var body: [String] = []
            switch node.kind {
            case .interfaceType: body.append("<<interface>>")
            case .abstractClass: body.append("<<abstract>>")
            case .enumType: body.append("<<enumeration>>")
            default: if let s = node.stereotype { body.append("<<\(s)>>") }
            }
            body += node.fields + node.methods
            if body.isEmpty { return indent + head }
            return ([indent + head + " {"] + body.map { indent + "  " + $0 } + [indent + "}"]).joined(separator: "\n")
        case .erDiagram:
            var head = node.id
            if node.title != node.id && !node.title.isEmpty { head += "[\"\(quoted(node.title))\"]" }
            if node.fields.isEmpty { return indent + head }
            return ([indent + head + " {"] + node.fields.map { indent + "  " + $0 } + [indent + "}"]).joined(separator: "\n")
        default:
            let (open, close) = mermaidShape(node.kind)
            return indent + "\(node.id)\(open)\"\(quoted(node.title))\"\(close)"
        }
    }

    func mermaidShape(_ kind: NodeKind) -> (String, String) {
        switch kind {
        case .rounded: ("(", ")")
        case .stadium: ("([", "])")
        case .circle: ("((", "))")
        case .diamond: ("{", "}")
        case .hexagon: ("{{", "}}")
        case .parallelogram: ("[/", "/]")
        case .database: ("[(", ")]")
        default: ("[", "]")
        }
    }

    private func plantKeyword(_ kind: NodeKind) -> String {
        switch kind {
        case .classType: "class"
        case .interfaceType: "interface"
        case .abstractClass: "abstract class"
        case .enumType: "enum"
        case .entity: "entity"
        case .component: "component"
        case .node: "node"
        case .database: "database"
        case .queue: "queue"
        case .actor: "actor"
        case .usecase: "usecase"
        case .cloud: "cloud"
        case .folder: "folder"
        case .artifact: "artifact"
        case .circle: "circle"
        case .hexagon: "hexagon"
        case .note: "card"
        default: "rectangle"
        }
    }

    private func plantDeclaration(_ node: DiagramNode, indent: String) -> String {
        var head = plantKeyword(node.kind) + " "
        if node.title == node.id && Self.isIdentifier(node.id) {
            head += node.id
        } else {
            head += "\"\(quoted(node.title))\" as \(plantID(node.id))"
        }
        if let s = node.stereotype, !s.isEmpty { head += " <<\(s)>>" }
        let members: [String] = node.kind == .entity
            ? node.fields
            : node.fields + (node.fields.isEmpty || node.methods.isEmpty ? [] : ["--"]) + node.methods
        guard (node.kind.isClassifier || node.kind == .entity), !members.isEmpty else { return indent + head }
        return ([indent + head + " {"] + members.map { indent + "  " + $0 } + [indent + "}"]).joined(separator: "\n")
    }

    /// A PlantUML alias must be an identifier; ids that came from `[Some Name]` aren't.
    private func plantID(_ id: String) -> String {
        Self.isIdentifier(id) ? id : id.replacingOccurrences(of: #"[^A-Za-z0-9_]"#, with: "_", options: .regularExpression)
    }

    /// How an id is written as a relationship endpoint.
    func endpoint(_ id: String, kind: NodeKind?) -> String {
        if Self.isIdentifier(id, allowHyphen: allowsHyphenInIDs) { return id }
        guard language == .plantUML else { return id }
        switch kind {
        case .component?: return "[\(id)]"
        case .usecase?: return "(\(id))"
        case .actor?: return ":\(id):"
        default: return "\"\(id)\""
        }
    }

    // MARK: Sequence

    private func participant(_ node: DiagramNode) -> String {
        let plain = node.title == node.id && Self.isIdentifier(node.id)
        if language == .mermaid {
            let keyword = node.kind == .actor ? "actor" : "participant"
            return plain ? "\(keyword) \(node.id)" : "\(keyword) \(node.id) as \(node.title.replacingOccurrences(of: "\n", with: " "))"
        }
        let keyword: String = switch node.kind {
        case .actor: "actor"
        case .seqBoundary: "boundary"
        case .seqControl: "control"
        case .seqEntity: "entity"
        case .database: "database"
        case .collections: "collections"
        case .queue: "queue"
        default: "participant"
        }
        return plain ? "\(keyword) \(node.id)" : "\(keyword) \"\(quoted(node.title))\" as \(node.id)"
    }

    func sequenceMessage(_ e: DiagramEdge, activate: Bool = false, deactivate: Bool = false, indent: String = "") -> String {
        let dashed = e.line == .dashed || e.line == .dotted
        let label = (e.label ?? "").replacingOccurrences(of: "\n", with: language == .plantUML ? "\\n" : "<br>")
        if language == .mermaid {
            let head: String = switch e.endMarker {
            case .arrow: ")"
            case .cross: "x"
            case .none: ">"
            default: ">>"
            }
            let start = e.startMarker != .none && head == ">>" ? "<<" : ""
            let mod = activate ? "+" : (deactivate ? "-" : "")
            return indent + "\(e.from)\(start)\(dashed ? "--" : "-")\(head)\(mod)\(e.to): \(label)"
        }
        let head: String = switch e.endMarker {
        case .arrow: ">>"
        case .cross: ">x"
        case .circle: ">o"
        default: ">"
        }
        let start: String = switch e.startMarker {
        case .none: ""
        case .arrow: "<<"
        default: "<"
        }
        var s = "\(endpoint(e.from, kind: nil)) \(start)\(dashed ? "--" : "-")\(head) \(endpoint(e.to, kind: nil))"
        if activate { s += " ++" } else if deactivate { s += " --" }
        if !label.isEmpty { s += " : \(label)" }
        return indent + s
    }

    // MARK: Edges

    func edge(_ e: DiagramEdge, fromKind: NodeKind?, toKind: NodeKind?, indent: String = "") -> String {
        if family == .sequence { return sequenceMessage(e, indent: indent) }
        let from = endpoint(e.from, kind: fromKind)
        let to = endpoint(e.to, kind: toKind)
        if family == .c4 {
            var args = [e.from, e.to, "\"\(quoted(e.label ?? ""))\""]
            if let t = e.technology, !t.isEmpty { args.append("\"\(quoted(t))\"") }
            let macro = e.startMarker == .none ? "Rel" : "BiRel"
            return indent + "\(macro)(\(args.joined(separator: ", ")))"
        }
        if language == .mermaid && family == .flowchart {
            let start = e.startMarker == .none ? "" : (e.startMarker == .cross ? "x" : e.startMarker == .circle ? "o" : "<")
            let endMark: String = switch e.endMarker {
            case .none: ""
            case .cross: "x"
            case .circle: "o"
            default: ">"
            }
            var body: String
            switch e.line {
            case .dashed, .dotted: body = endMark.isEmpty ? "-.-" : "-.-"
            case .thick: body = endMark.isEmpty ? "===" : "=="
            case .invisible: body = "~~~"
            case .solid: body = endMark.isEmpty ? "---" : "--"
            }
            if e.line == .invisible { return indent + "\(from) ~~~ \(to)" }
            var s = "\(from) \(start)\(body)\(endMark)"
            if let l = e.label, !l.isEmpty { s += "|\"\(quoted(l))\"|" }
            return indent + s + " \(to)"
        }
        // UML / ER relationship syntax shared by PlantUML and Mermaid.
        let left = leftHead(e.startMarker)
        let right = rightHead(e.endMarker)
        let body = (e.line == .dashed || e.line == .dotted) ? ".." : (e.line == .thick && language == .plantUML ? "==" : "--")
        var s = from
        if let c = e.fromLabel, !c.isEmpty { s += " \"\(quoted(c))\"" }
        s += " \(left)\(body)\(right) "
        if let c = e.toLabel, !c.isEmpty { s += "\"\(quoted(c))\" " }
        s += to
        if let l = e.label, !l.isEmpty {
            s += language == .mermaid && family == .erDiagram ? " : \"\(quoted(l))\"" : " : \(l.replacingOccurrences(of: "\n", with: language == .plantUML ? "\\n" : " "))"
        } else if language == .mermaid && family == .erDiagram {
            s += " : \"\""
        }
        return indent + s
    }

    private func leftHead(_ m: EdgeMarker) -> String {
        switch m {
        case .none: ""
        case .arrow, .filledArrow: "<"
        case .triangle: "<|"
        case .diamond: "o"
        case .filledDiamond: "*"
        case .circle: language == .plantUML ? "+" : ""
        case .cross: language == .plantUML ? "x" : ""
        case .exactlyOne: "||"
        case .zeroOrOne: "|o"
        case .oneOrMany: "}|"
        case .zeroOrMany: "}o"
        }
    }

    private func rightHead(_ m: EdgeMarker) -> String {
        switch m {
        case .none: ""
        case .arrow, .filledArrow: ">"
        case .triangle: "|>"
        case .diamond: "o"
        case .filledDiamond: "*"
        case .circle: language == .plantUML ? "+" : ""
        case .cross: language == .plantUML ? "x" : ""
        case .exactlyOne: "||"
        case .zeroOrOne: "o|"
        case .oneOrMany: "|{"
        case .zeroOrMany: "o{"
        }
    }

    /// Default look of a newly drawn connection for this kind of diagram.
    func defaultEdge(from: String, to: String) -> DiagramEdge {
        switch family {
        case .flowchart: DiagramEdge(from: from, to: to, startMarker: .none, endMarker: language == .mermaid ? .filledArrow : .arrow)
        case .classDiagram: DiagramEdge(from: from, to: to, startMarker: .none, endMarker: .arrow)
        case .erDiagram: DiagramEdge(from: from, to: to, startMarker: .exactlyOne, endMarker: .zeroOrMany)
        case .c4: DiagramEdge(from: from, to: to, startMarker: .none, endMarker: .filledArrow)
        case .sequence: DiagramEdge(from: from, to: to, startMarker: .none, endMarker: .filledArrow)
        }
    }
}
