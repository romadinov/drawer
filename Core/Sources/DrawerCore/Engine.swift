import Foundation

public enum ElementRef: Hashable, Sendable {
    case node(String)
    case edge(String)
    case decoration(UUID)
}

/// Pure operations on `DrawingState`. Every drawing-side change that affects
/// semantics goes through `SpecEditor`, so the spec text always stays the source of truth.
public enum Engine {
    /// Re-parses the spec and gives positions to any new nodes.
    @discardableResult
    public static func reconcile(_ state: inout DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> ParsedDiagram {
        let parsed = SpecParser.parse(state.spec, language: state.language)
        let firstLayout = !parsed.nodes.isEmpty && parsed.nodes.allSatisfy { $0.kind.isGroup || state.layout[$0.id] == nil }
        let layout = AutoLayout.placeMissing(parsed, state: state, measure: measure)
        if layout != state.layout { state.layout = layout }
        if firstLayout { state.edgeLayout = AutoLayout.routeAroundObstacles(parsed, state: state, measure: measure) }
        return parsed
    }

    @discardableResult
    public static func addNode(_ state: inout DrawingState, kind: NodeKind, title: String, at point: Point, parent: String? = nil,
                               measure: @escaping TextMeasurer = approximateMeasurer) -> String {
        var editor = SpecEditor(spec: state.spec, language: state.language)
        let id = editor.addNode(kind: kind, title: title, parent: parent)
        state.spec = editor.spec
        if let node = editor.parsed.node(id) {
            let size = DiagramGeometry.intrinsicSize(node, measure: measure)
            state.layout[id] = NodeLayout(position: Point(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded()),
                                          size: kind.isGroup ? Size(width: 260, height: 160) : nil)
        }
        reconcile(&state, measure: measure)
        return id
    }

    public static func addEdge(_ state: inout DrawingState, from: String, to: String, label: String? = nil, before: String? = nil,
                               measure: @escaping TextMeasurer = approximateMeasurer) {
        var editor = SpecEditor(spec: state.spec, language: state.language)
        editor.addEdge(from: from, to: to, label: label, before: before)
        state.spec = editor.spec
        reconcile(&state, measure: measure)
    }

    public static func delete(_ state: inout DrawingState, _ selection: Set<ElementRef>, measure: @escaping TextMeasurer = approximateMeasurer) {
        var nodes = Set<String>(), edges = Set<String>(), decorations = Set<UUID>()
        for ref in selection {
            switch ref {
            case let .node(id): nodes.insert(id)
            case let .edge(id): edges.insert(id)
            case let .decoration(id): decorations.insert(id)
            }
        }
        if !nodes.isEmpty || !edges.isEmpty {
            var editor = SpecEditor(spec: state.spec, language: state.language)
            editor.delete(nodes: nodes, edges: edges)
            state.spec = editor.spec
            for id in edges { state.edgeLayout[id] = nil }
        }
        state.decorations.removeAll { decorations.contains($0.id) }
        reconcile(&state, measure: measure)
    }

    /// Returns the node id after the edit (renaming an identifier changes it).
    @discardableResult
    public static func updateNode(_ state: inout DrawingState, id: String, _ edit: NodeEdit, measure: @escaping TextMeasurer = approximateMeasurer) -> String {
        var editor = SpecEditor(spec: state.spec, language: state.language)
        var edit = edit
        // A placeholder name ("Use Case") follows a change of kind ("Cloud") instead of contradicting it.
        if let kind = edit.kind, edit.title == nil, let node = editor.parsed.node(id), node.kind != kind,
           node.title == node.kind.displayName || (node.title == "Person" && [.actor, .person, .personExt].contains(node.kind)) {
            edit.title = kind.displayName
        }
        let newID = editor.update(node: id, edit)
        state.spec = editor.spec
        if newID != id { migrateID(&state, from: id, to: newID) }
        // A user-sized node that changed content keeps its size; intrinsic ones re-measure automatically.
        reconcile(&state, measure: measure)
        return newID
    }

    public static func updateEdge(_ state: inout DrawingState, id: String, _ edit: EdgeEdit, measure: @escaping TextMeasurer = approximateMeasurer) {
        var editor = SpecEditor(spec: state.spec, language: state.language)
        let before = editor.parsed.edge(id)
        editor.update(edge: id, edit)
        state.spec = editor.spec
        if edit.reverse, let before {
            let newID = "\(before.to)->\(before.from)"
            if let l = state.edgeLayout.removeValue(forKey: id) {
                state.edgeLayout[newID] = EdgeLayout(waypoints: l.waypoints.reversed(), routing: l.routing, labelOffset: l.labelOffset)
            }
            if let s = state.styles.removeValue(forKey: "edge:" + id) { state.styles["edge:" + newID] = s }
        }
        reconcile(&state, measure: measure)
    }

    static func migrateID(_ state: inout DrawingState, from old: String, to new: String) {
        if let l = state.layout.removeValue(forKey: old) { state.layout[new] = l }
        if let s = state.styles.removeValue(forKey: old) { state.styles[new] = s }
        for (key, value) in state.edgeLayout {
            let parts = key.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            var from = parts[0], toAndSuffix = parts[1]
            var changed = false
            if from == old { from = new; changed = true }
            let suffixIndex = toAndSuffix.firstIndex(of: "#")
            let to = suffixIndex.map { String(toAndSuffix[..<$0]) } ?? toAndSuffix
            let suffix = suffixIndex.map { String(toAndSuffix[$0...]) } ?? ""
            if to == old { toAndSuffix = new + suffix; changed = true }
            if changed {
                state.edgeLayout.removeValue(forKey: key)
                state.edgeLayout["\(from)->\(toAndSuffix)"] = value
            }
        }
    }

    /// Moves nodes (groups carry their descendants) and decorations.
    public static func move(_ state: inout DrawingState, _ refs: Set<ElementRef>, by delta: Point, parsed: ParsedDiagram, measure: @escaping TextMeasurer = approximateMeasurer) {
        var nodeIDs = Set<String>()
        for case let .node(id) in refs {
            nodeIDs.insert(id)
            for d in parsed.descendants(of: id) { nodeIDs.insert(d.id) }
        }
        let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
        for id in nodeIDs {
            guard let frame = geometry.frames[id] else { continue }
            let isGroupWithChildren = parsed.node(id)?.kind.isGroup == true && !parsed.children(of: id).isEmpty
            // A group with children follows them, except for an explicit size it keeps (see DiagramGeometry).
            if isGroupWithChildren && state.layout[id]?.size == nil { continue }
            var l = state.layout[id] ?? NodeLayout(position: frame.origin)
            l.position = Point(x: (l.position.x + delta.x).rounded(), y: (l.position.y + delta.y).rounded())
            state.layout[id] = l
        }
        // Waypoints of edges whose both ends move travel along.
        for edge in parsed.edges where nodeIDs.contains(edge.from) && nodeIDs.contains(edge.to) {
            guard var l = state.edgeLayout[edge.id], !l.waypoints.isEmpty else { continue }
            l.waypoints = l.waypoints.map { Point(x: $0.x + delta.x, y: $0.y + delta.y) }
            state.edgeLayout[edge.id] = l
        }
        for i in state.decorations.indices {
            if refs.contains(.decoration(state.decorations[i].id)) {
                state.decorations[i].frame.origin.x += delta.x
                state.decorations[i].frame.origin.y += delta.y
            }
        }
    }

    public static func autoLayout(_ state: inout DrawingState, parsed: ParsedDiagram, measure: @escaping TextMeasurer = approximateMeasurer) {
        let positions = AutoLayout.layout(parsed, measure: measure)
        for (id, l) in positions {
            var existing = state.layout[id] ?? l
            existing.position = l.position
            existing.size = nil
            state.layout[id] = existing
        }
        state.edgeLayout = state.edgeLayout.mapValues { EdgeLayout(waypoints: [], routing: $0.routing, labelOffset: .zero) }
        state.edgeLayout = AutoLayout.routeAroundObstacles(parsed, state: state, measure: measure)
    }

    /// Rewrites the spec in another language, keeping ids so the layout survives.
    public static func convert(_ state: inout DrawingState, to language: SpecLanguage, parsed: ParsedDiagram) {
        guard language != state.language else { return }
        state.spec = SpecGenerator.generate(parsed, language: language)
        state.language = language
    }
}

/// Generates a complete spec from a parsed model.
public enum SpecGenerator {
    public static func generate(_ parsed: ParsedDiagram, language: SpecLanguage) -> String {
        if parsed.family == .sequence { return generateSequence(parsed, language: language) }
        let emitter = SpecEmitter(language: language, family: parsed.family)
        var lines: [String] = []
        switch language {
        case .plantUML:
            lines.append("@startuml")
            if parsed.family == .c4 { lines.append("!include <C4/C4_Container>") }
            if let t = parsed.title { lines.append("title \(t)") }
            if parsed.direction.isHorizontal { lines.append("left to right direction") }
        case .mermaid:
            switch parsed.family {
            case .flowchart: lines.append("flowchart " + (parsed.direction.isHorizontal ? "LR" : "TD"))
            case .classDiagram: lines.append("classDiagram")
            case .erDiagram: lines.append("erDiagram")
            case .c4: lines.append("C4Container")
            case .sequence: lines.append("sequenceDiagram")
            }
            if let t = parsed.title { lines.append("  title \(t)") }
        }
        let baseIndent = language == .mermaid ? "  " : ""
        func emit(parent: String?, indent: String) {
            for node in parsed.nodes where node.parent == parent {
                if node.kind.isGroup {
                    lines.append(emitter.groupOpening(node, indent: indent))
                    emit(parent: node.id, indent: indent + "  ")
                    lines.append(emitter.groupClosing(indent: indent))
                } else {
                    lines.append(emitter.declaration(for: node, indent: indent))
                }
            }
        }
        emit(parent: nil, indent: baseIndent)
        for edge in parsed.edges {
            lines.append(emitter.edge(edge, fromKind: parsed.node(edge.from)?.kind, toKind: parsed.node(edge.to)?.kind, indent: baseIndent))
        }
        if language == .plantUML { lines.append("@enduml") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func generateSequence(_ parsed: ParsedDiagram, language: SpecLanguage) -> String {
        let emitter = SpecEmitter(language: language, family: .sequence)
        let mermaid = language == .mermaid
        var lines: [String] = [mermaid ? "sequenceDiagram" : "@startuml"]
        let base = mermaid ? "  " : ""
        if let t = parsed.title { lines.append(base + "title \(t)") }
        let info = parsed.sequence ?? SequenceInfo()
        if info.autonumber { lines.append(base + "autonumber") }
        for node in parsed.nodes where !node.kind.isGroup { lines.append(emitter.declaration(for: node, indent: base)) }
        var depth = 0
        func indent() -> String { base + String(repeating: "  ", count: depth) }
        func text(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: mermaid ? "<br>" : "\\n") }
        for event in info.events {
            switch event.kind {
            case let .message(i, activate, deactivate):
                guard i < parsed.edges.count else { continue }
                lines.append(emitter.sequenceMessage(parsed.edges[i], activate: activate, deactivate: deactivate, indent: indent()))
            case let .note(t, participants, position):
                let target = participants.joined(separator: mermaid ? "," : ", ")
                let where_ = position == .over ? "over" : "\(position.rawValue) of"
                lines.append(indent() + (mermaid ? "Note \(where_) \(target): \(text(t))" : "note \(where_) \(target) : \(text(t))"))
            case let .divider(t):
                lines.append(indent() + (mermaid ? "%% == \(t) ==" : "== \(t) =="))
            case let .delay(t):
                lines.append(indent() + (mermaid ? "%% ...\(t ?? "")..." : "...\(t.map { "\($0)..." } ?? "")"))
            case .spacer:
                if !mermaid { lines.append(indent() + "|||") }
            case let .fragmentStart(kind, label):
                var k = kind
                if mermaid && ["group", "region"].contains(k) { k = "rect"; lines.append(indent() + "%% \(label)") }
                if !mermaid && ["rect", "region"].contains(k) { k = "group" }
                let showLabel = !(mermaid && k == "rect")
                lines.append(indent() + k + (showLabel && !label.isEmpty ? " \(label)" : (mermaid && k == "rect" ? " rgba(127,127,127,0.1)" : "")))
                depth += 1
            case let .fragmentElse(label):
                let k = mermaid ? "else" : "else"
                lines.append(base + String(repeating: "  ", count: max(depth - 1, 0)) + k + (label.isEmpty ? "" : " \(label)"))
            case .fragmentEnd:
                depth = max(depth - 1, 0)
                lines.append(indent() + "end")
            case let .activate(id):
                lines.append(indent() + "activate \(id)")
            case let .deactivate(id):
                lines.append(indent() + "deactivate \(id)")
            }
        }
        if !mermaid { lines.append("@enduml") }
        return lines.joined(separator: "\n") + "\n"
    }
}
