import Foundation

/// Copying part of a diagram as a diagram of its own, and pasting one diagram into another.
public enum DiagramClipboard {
    /// The selected elements as a standalone diagram. Nothing selected, a sequence diagram, or a selection
    /// that covers every element gives the whole diagram.
    public static func subset(_ state: DrawingState, parsed: ParsedDiagram, selection: Set<ElementRef>) -> DrawingState {
        var ids = Set<String>()
        for case let .node(id) in selection {
            ids.insert(id)
            for d in parsed.descendants(of: id) { ids.insert(d.id) }
        }
        let decorations = state.decorations.filter { selection.contains(.decoration($0.id)) }
        let everything = ids.isSuperset(of: parsed.nodes.map(\.id)) && decorations.count == state.decorations.count
        if (ids.isEmpty && decorations.isEmpty) || everything || parsed.family == .sequence { return state }

        var p = parsed
        p.title = nil
        p.nodes = parsed.nodes.filter { ids.contains($0.id) }.map { n in
            var n = n
            if let parent = n.parent, !ids.contains(parent) { n.parent = nil }
            return n
        }
        p.edges = parsed.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        let edgeIDs = Set(p.edges.map(\.id))
        var out = DrawingState(language: state.language, spec: ids.isEmpty ? "" : SpecGenerator.generate(p, language: state.language))
        out.layout = state.layout.filter { ids.contains($0.key) }
        out.edgeLayout = state.edgeLayout.filter { edgeIDs.contains($0.key) }
        out.styles = state.styles.filter { ids.contains($0.key) || ($0.key.hasPrefix("edge:") && edgeIDs.contains(String($0.key.dropFirst(5)))) }
        out.decorations = decorations
        return out
    }

    /// Pastes `other` into `state`, to the right of what is already there. Clashing ids get a numeric suffix,
    /// and the pasted statements are written in the target's spec language. Returns the pasted elements.
    @discardableResult
    public static func paste(_ other: DrawingState, into state: inout DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> Set<ElementRef> {
        let blank = state.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.decorations.isEmpty
        var incoming = other
        let src = Engine.reconcile(&incoming, measure: measure)
        if blank {
            state = incoming
            return Set(src.nodes.map { .node($0.id) } + src.edges.map { .edge($0.id) } + incoming.decorations.map { .decoration($0.id) })
        }
        let dst = Engine.reconcile(&state, measure: measure)
        let srcBounds = DiagramGeometry(parsed: src, state: incoming, measure: measure).bounds
        let dstBounds = DiagramGeometry(parsed: dst, state: state, measure: measure).bounds
        let shift = (srcBounds != nil && dstBounds != nil)
            ? Point(x: dstBounds!.maxX + 80 - srcBounds!.minX, y: dstBounds!.minY - srcBounds!.minY)
            : Point(x: 40, y: 40)

        var pasted = Set<ElementRef>()
        // Statements can't be merged into or out of a sequence diagram; only decorations travel then.
        if !src.nodes.isEmpty, src.family != .sequence, dst.family != .sequence {
            var rename: [String: String] = [:]
            var taken = Set(dst.nodes.map(\.id))
            for n in src.nodes {
                var id = n.id, k = 2
                while taken.contains(id) { id = "\(n.id)\(k)"; k += 1 }
                taken.insert(id)
                rename[n.id] = id
            }
            var p = src
            p.title = nil
            p.direction = dst.direction
            p.nodes = src.nodes.map { n in
                var n = n
                n.id = rename[n.id]!
                n.parent = n.parent.flatMap { rename[$0] }
                if n.titleIsIdentifier { n.title = n.id }
                return n
            }
            p.edges = src.edges.map { e in var e = e; e.from = rename[e.from]!; e.to = rename[e.to]!; return e }
            let statements = SpecGenerator.generate(p, language: state.language)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !isHeader($0, language: state.language) }
            let ns = NSMutableString(string: state.spec)
            var block = statements.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
            let at = min(dst.insertionOffset, ns.length)
            if at > 0 && ns.character(at: at - 1) != 10 { block = "\n" + block }
            ns.insert(block, at: at)
            state.spec = ns as String

            for (old, new) in rename {
                if let l = incoming.layout[old] {
                    state.layout[new] = NodeLayout(position: Point(x: l.position.x + shift.x, y: l.position.y + shift.y), size: l.size)
                }
                if let s = incoming.styles[old] { state.styles[new] = s }
                pasted.insert(.node(new))
            }
            let after = SpecParser.parse(state.spec, language: state.language)
            for e in src.edges {
                let from = rename[e.from]!, to = rename[e.to]!
                guard let newEdge = after.edges.last(where: { $0.from == from && $0.to == to }) else { continue }
                pasted.insert(.edge(newEdge.id))
                if var l = incoming.edgeLayout[e.id] {
                    l.waypoints = l.waypoints.map { Point(x: $0.x + shift.x, y: $0.y + shift.y) }
                    state.edgeLayout[newEdge.id] = l
                }
                if let s = incoming.styles["edge:" + e.id] { state.styles["edge:" + newEdge.id] = s }
            }
        }
        for var d in incoming.decorations {
            d.id = UUID()
            d.frame.origin = Point(x: d.frame.origin.x + shift.x, y: d.frame.origin.y + shift.y)
            state.decorations.append(d)
            pasted.insert(.decoration(d.id))
        }
        Engine.reconcile(&state, measure: measure)
        return pasted
    }

    /// Lines of a generated spec that belong to the document, not to its elements.
    static func isHeader(_ line: String, language: SpecLanguage) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("title ") { return true }
        switch language {
        case .plantUML: return t == "@startuml" || t == "@enduml" || t.hasPrefix("!include") || t == "left to right direction"
        case .mermaid: return ["flowchart", "graph", "classDiagram", "erDiagram", "C4"].contains { t.hasPrefix($0) } && !t.contains("[")
        }
    }
}
