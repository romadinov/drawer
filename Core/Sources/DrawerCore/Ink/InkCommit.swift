import Foundation

/// Turns recognised ink into real diagram elements:
/// shapes become nodes in the spec (or decorations when the diagram has no matching element),
/// handwriting inside a shape becomes its title, arrows between elements become relationships
/// or messages, and the rest becomes text or stays as ink.
public enum InkCommit {
    public struct Result: Equatable, Sendable {
        public var created: [ElementRef] = []
        /// Nodes created without a recognised title; the UI may offer to name them.
        public var untitled: [String] = []
    }

    /// The node kind a drawn shape becomes in this kind of diagram, or nil if it should stay a decoration.
    public static func nodeKind(for shape: InkShapeKind, rect: Rect, family: DiagramFamily, language: SpecLanguage) -> NodeKind? {
        let wide = rect.size.width > rect.size.height * 1.6
        switch (family, shape) {
        case (.flowchart, .rectangle): return .box
        case (.flowchart, .ellipse): return language == .mermaid ? (wide ? .stadium : .circle) : .usecase
        case (.flowchart, .diamond): return language == .mermaid ? .diamond : nil
        case (.classDiagram, .rectangle): return .classType
        case (.classDiagram, .ellipse): return .interfaceType
        case (.erDiagram, .rectangle): return .entity
        case (.c4, .rectangle): return .container
        case (.c4, .ellipse): return .person
        case (.sequence, .rectangle): return .participant
        case (.sequence, .ellipse): return .actor
        default: return nil
        }
    }

    @discardableResult
    public static func apply(_ items: [InkItem], to state: inout DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> Result {
        var result = Result()
        let needsSpec = items.contains { if case .text = $0 { false } else { true } }
        if needsSpec && state.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.spec = state.language == .plantUML ? "@startuml\n\n@enduml\n" : "flowchart TD\n"
        }
        var parsed = Engine.reconcile(&state, measure: measure)

        var shapes: [(kind: InkShapeKind, rect: Rect, words: [(String, Rect)])] = []
        var connectors: [(from: Point, to: Point, headStart: Bool, headEnd: Bool)] = []
        var texts: [(text: String?, rect: Rect, strokes: [InkStroke])] = []
        for item in items {
            switch item {
            case let .shape(k, r): shapes.append((k, r, []))
            case let .connector(a, b, hs, he): connectors.append((a, b, hs, he))
            case let .text(t, r, s): texts.append((t, r, s))
            }
        }

        // Handwriting inside a new shape names it.
        texts.removeAll { t in
            guard let text = t.text, !text.isEmpty else { return false }
            let hosts = shapes.indices.filter { shapes[$0].rect.insetBy(-6).contains(t.rect.center) }
            guard let i = hosts.min(by: { area(shapes[$0].rect) < area(shapes[$1].rect) }) else { return false }
            shapes[i].words.append((text, t.rect))
            return true
        }

        // Shapes → nodes (or decorations).
        for shape in shapes {
            let title = shape.words.sorted { abs($0.1.minY - $1.1.minY) > 10 ? $0.1.minY < $1.1.minY : $0.1.minX < $1.1.minX }
                .map(\.0).joined(separator: " ")
            guard let kind = nodeKind(for: shape.kind, rect: shape.rect, family: parsed.family, language: state.language) else {
                let d = Decoration(kind: shape.kind == .ellipse ? .ellipse : .rectangle, frame: shape.rect, text: title)
                state.decorations.append(d)
                result.created.append(.decoration(d.id))
                continue
            }
            let parent = innermostGroup(containing: shape.rect, parsed: parsed, state: state, measure: measure)
            let id = Engine.addNode(&state, kind: kind, title: title.isEmpty ? kind.displayName : title,
                                    at: shape.rect.center, parent: parent, measure: measure)
            if [.box, .stadium, .circle, .diamond, .usecase, .container, .participant].contains(kind),
               let node = SpecParser.parse(state.spec, language: state.language).node(id) {
                let intrinsic = DiagramGeometry.intrinsicSize(node, measure: measure)
                let w = max(intrinsic.width, (shape.rect.size.width / 10).rounded() * 10)
                let h = kind == .participant ? intrinsic.height : max(intrinsic.height, (shape.rect.size.height / 10).rounded() * 10)
                state.layout[id] = NodeLayout(position: Point(x: (shape.rect.midX - w / 2).rounded(), y: (shape.rect.midY - h / 2).rounded()),
                                              size: Size(width: w, height: h))
            }
            result.created.append(.node(id))
            if title.isEmpty { result.untitled.append(id) }
        }
        parsed = Engine.reconcile(&state, measure: measure)

        // Connectors → relationships / messages (or decorations).
        for c in connectors {
            var geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
            let label = takeText(near: [c.from, c.to], from: &texts, maxDistance: 36)
            guard var from = node(at: c.from, parsed: parsed, geometry: geometry),
                  var to = node(at: c.to, parsed: parsed, geometry: geometry),
                  from != to || parsed.family == .sequence else {
                let (a, b) = c.headStart && !c.headEnd ? (c.to, c.from) : (c.from, c.to)
                let d = Decoration(kind: c.headStart || c.headEnd ? .arrow : .line,
                                   frame: Rect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), text: label ?? "")
                state.decorations.append(d)
                result.created.append(.decoration(d.id))
                continue
            }
            if c.headStart && !c.headEnd { swap(&from, &to) }
            var editor = SpecEditor(spec: state.spec, language: state.language)
            var edge = editor.emitter.defaultEdge(from: from, to: to)
            edge.label = label ?? (parsed.family == .sequence ? "message" : nil)
            if parsed.family != .sequence && parsed.family != .c4 {
                if !c.headStart && !c.headEnd { edge.endMarker = .none }
                if c.headStart && c.headEnd { edge.startMarker = edge.endMarker }
            }
            var before: String?
            if let seq = geometry.sequence {
                let y = (c.from.y + c.to.y) / 2
                before = parsed.edges.indices
                    .compactMap { i in seq.messagePaths[i]?.first.map { (i, $0.y) } }
                    .filter { $0.1 > y }.min { $0.1 < $1.1 }.map { parsed.edges[$0.0].id }
            }
            let existing = Set(parsed.edges.map(\.id))
            editor.addEdge(edge, before: before)
            state.spec = editor.spec
            parsed = Engine.reconcile(&state, measure: measure)
            geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
            if let added = parsed.edges.first(where: { !existing.contains($0.id) }) { result.created.append(.edge(added.id)) }
        }

        // Remaining handwriting: rename the element it was written on, label a connection, or stay as text / ink.
        for t in texts {
            let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
            guard let text = t.text, !text.isEmpty else {
                let origin = t.rect.origin
                let d = Decoration(kind: .ink, frame: t.rect,
                                   strokes: t.strokes.map { $0.points.map { Point(x: $0.x - origin.x, y: $0.y - origin.y) } })
                state.decorations.append(d)
                result.created.append(.decoration(d.id))
                continue
            }
            if let id = node(at: t.rect.center, parsed: parsed, geometry: geometry, tolerance: 0) {
                let newID = Engine.updateNode(&state, id: id, NodeEdit(title: text), measure: measure)
                parsed = SpecParser.parse(state.spec, language: state.language)
                result.created.append(.node(newID))
                continue
            }
            if let edge = parsed.edges.first(where: { e in
                (e.label ?? "").isEmpty && DiagramGeometry.distance(from: t.rect.center, toPolyline: geometry.edgePath(e)).distance < 28
            }) {
                Engine.updateEdge(&state, id: edge.id, EdgeEdit(label: .some(text)), measure: measure)
                parsed = SpecParser.parse(state.spec, language: state.language)
                result.created.append(.edge(edge.id))
                continue
            }
            let fontSize = min(max((t.rect.size.height * 0.7).rounded(), 12), 32)
            let d = Decoration(kind: .text, frame: Rect(x: t.rect.minX, y: t.rect.minY, width: max(t.rect.size.width, 60), height: max(t.rect.size.height, fontSize * 1.4)),
                               text: text, fontSize: fontSize)
            state.decorations.append(d)
            result.created.append(.decoration(d.id))
        }
        Engine.reconcile(&state, measure: measure)
        return result
    }

    // MARK: Helpers

    private static func area(_ r: Rect) -> Double { r.size.width * r.size.height }

    /// The smallest non-group node under `p` (with some slack for sloppy pens), else a sequence lifeline, else a group.
    static func node(at p: Point, parsed: ParsedDiagram, geometry: DiagramGeometry, tolerance: Double = 22) -> String? {
        let hits = parsed.nodes.compactMap { n -> (DiagramNode, Rect)? in
            guard let f = geometry.frames[n.id], f.insetBy(-tolerance).contains(p) else { return nil }
            return (n, f)
        }
        if let n = hits.filter({ !$0.0.kind.isGroup }).min(by: { area($0.1) < area($1.1) }) { return n.0.id }
        if let seq = geometry.sequence {
            let lane = seq.lifelines.filter { abs($0.value.x - p.x) < 30 && p.y >= $0.value.top - 10 && p.y <= $0.value.bottom + 40 }
            if let best = lane.min(by: { abs($0.value.x - p.x) < abs($1.value.x - p.x) }) { return best.key }
        }
        guard tolerance > 0 else { return nil }
        return hits.filter { $0.0.kind.isGroup }.min { area($0.1) < area($1.1) }?.0.id
    }

    static func innermostGroup(containing r: Rect, parsed: ParsedDiagram, state: DrawingState, measure: @escaping TextMeasurer) -> String? {
        let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
        return parsed.nodes.filter(\.kind.isGroup)
            .compactMap { g in geometry.frames[g.id].flatMap { $0.contains(r.center) ? (g.id, $0) : nil } }
            .min { area($0.1) < area($1.1) }?.0
    }

    /// Removes and returns handwriting written alongside a connector (closest to its middle).
    private static func takeText(near ends: [Point], from texts: inout [(text: String?, rect: Rect, strokes: [InkStroke])], maxDistance: Double) -> String? {
        let candidates = texts.indices.compactMap { i -> (Int, Double)? in
            guard let t = texts[i].text, !t.isEmpty else { return nil }
            let d = DiagramGeometry.distance(from: texts[i].rect.center, toPolyline: ends).distance
            let along = InkMath.distance(texts[i].rect.center, ends[0])
            let toEnd = InkMath.distance(texts[i].rect.center, ends[1])
            // Text by the middle of the line, not hugging either end (that's probably a node title).
            return d < maxDistance + texts[i].rect.size.height / 2 && along > 30 && toEnd > 30 ? (i, d) : nil
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        return texts.remove(at: best.0).text
    }
}
