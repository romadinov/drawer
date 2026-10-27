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
        /// Elements whose kind was a guess between several options.
        public var choices: [Choice] = []
        /// A connector was drawn from an element back onto itself: the user wants to edit that element.
        public var edit: String?
        public init() {}
    }

    /// A recognised element that could have been one of several kinds. The first option was applied.
    public struct Choice: Equatable, Sendable {
        public var id: String
        public var options: [NodeKind]
        /// Drawn without a name: once the kind is settled, the name is the next thing to ask for.
        public var needsName = false
    }

    /// What a drawn shape (nil = stick figure) can become in this kind of diagram, most likely first.
    /// Empty when the diagram has no matching element, in which case it stays a decoration.
    public static func choices(for shape: InkShapeKind?, rect: Rect, family: DiagramFamily, language: SpecLanguage) -> [NodeKind] {
        let wide = rect.size.width > rect.size.height * 1.6
        let mermaid = language == .mermaid
        switch (family, shape) {
        case (.flowchart, .rectangle?): return mermaid ? [.box, .rounded, .hexagon, .parallelogram, .database]
                                                       : [.box, .component, .node, .database, .queue, .cloud, .folder, .artifact]
        case (.flowchart, .ellipse?): return mermaid ? (wide ? [.stadium, .circle, .rounded] : [.circle, .stadium, .rounded]) : [.usecase, .cloud]
        case (.flowchart, .diamond?): return mermaid ? [.diamond, .hexagon] : []
        case (.classDiagram, .rectangle?): return [.classType, .abstractClass, .interfaceType, .enumType]
        case (.classDiagram, .ellipse?): return [.interfaceType, .classType]
        case (.erDiagram, .rectangle?): return [.entity]
        case (.c4, .rectangle?): return [.container, .system, .component4, .containerDb, .containerQueue, .systemExt, .containerExt]
        case (.c4, .ellipse?): return [.person, .personExt, .system, .systemExt]
        case (.c4, nil): return [.person, .personExt]
        case (.sequence, .rectangle?): return mermaid ? [.participant, .actor] : [.participant, .database, .queue, .collections, .seqBoundary, .seqControl]
        case (.sequence, .ellipse?): return mermaid ? [.actor, .participant] : [.actor, .seqEntity, .seqControl, .seqBoundary]
        case (.sequence, nil): return mermaid ? [.actor, .participant] : [.actor, .participant]
        case (_, nil): return mermaid ? [] : [.actor]
        default: return []
        }
    }

    @discardableResult
    public static func apply(_ items: [InkItem], to state: inout DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> Result {
        var result = Result()
        let needsSpec = items.contains { if case .text = $0 { false } else { true } }
        // A blank Mermaid document has no person element; a drawn figure starts a C4 context diagram instead.
        if state.language == .mermaid, state.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           items.contains(where: { if case .person = $0 { true } else { false } }) {
            state.spec = "C4Context\n"
        }
        if needsSpec && state.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.spec = state.language == .plantUML ? "@startuml\n\n@enduml\n" : "flowchart TD\n"
        }
        var parsed = Engine.reconcile(&state, measure: measure)

        var shapes: [(kind: InkShapeKind?, rect: Rect, strokes: [InkStroke], words: [(String, Rect)])] = []
        var connectors: [(from: Point, to: Point, headStart: Bool, headEnd: Bool)] = []
        var texts: [(text: String?, rect: Rect, strokes: [InkStroke])] = []
        for item in items {
            switch item {
            case let .shape(k, r): shapes.append((k, r, [], []))
            case let .person(r, s): shapes.append((nil, r, s, []))
            case let .connector(a, b, hs, he): connectors.append((a, b, hs, he))
            case let .text(t, r, s): texts.append((t, r, s))
            }
        }

        // Handwriting inside a new shape names it (unless it was written on an element inside that shape).
        let before = DiagramGeometry(parsed: parsed, state: state, measure: measure)
        texts.removeAll { t in
            guard let text = t.text, !text.isEmpty else { return false }
            let onExisting = parsed.nodes.compactMap { before.frames[$0.id] }.filter { $0.contains(t.rect.center) }.map(area).min()
            // A person's name is usually written underneath.
            let hosts = shapes.indices.filter { i in
                let r = shapes[i].rect
                let zone = shapes[i].kind == nil ? Rect(x: r.minX - 40, y: r.minY, width: r.size.width + 80, height: r.size.height + 60) : r.insetBy(-6)
                return zone.contains(t.rect.center)
            }
            guard let i = hosts.min(by: { area(shapes[$0].rect) < area(shapes[$1].rect) }) else { return false }
            if let e = onExisting, e < area(shapes[i].rect) { return false }
            shapes[i].words.append((text, t.rect))
            return true
        }

        // Shapes → nodes (or decorations). Remember where each was drawn: a big stick figure becomes
        // a small actor icon, but an arrow drawn to the figure should still connect to it.
        var drawn: [(id: String, rect: Rect)] = []
        for shape in shapes.sorted(by: { area($0.rect) < area($1.rect) }) {
            parsed = Engine.reconcile(&state, measure: measure)
            let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
            let title = shape.words.sorted { abs($0.1.minY - $1.1.minY) > 10 ? $0.1.minY < $1.1.minY : $0.1.minX < $1.1.minX }
                .map(\.0).joined(separator: " ")
            // Drawn around existing elements: it's a group of them.
            let enclosed = shape.kind == nil ? [] : enclosedNodes(in: shape.rect, parsed: parsed, geometry: geometry)
            if !enclosed.isEmpty, let groupKind = groupKind(family: parsed.family, language: state.language) {
                let parent = innermostGroup(containing: shape.rect, parsed: parsed, state: state, measure: measure, excluding: Set(enclosed))
                let id = Engine.addNode(&state, kind: groupKind, title: title.isEmpty ? (groupKind == .boundary ? "System" : "Group") : title,
                                        at: shape.rect.center, parent: parent, measure: measure)
                var editor = SpecEditor(spec: state.spec, language: state.language)
                editor.move(nodes: enclosed, into: id)
                state.spec = editor.spec
                state.layout[id] = NodeLayout(position: Point(x: shape.rect.minX.rounded(), y: shape.rect.minY.rounded()),
                                              size: Size(width: shape.rect.size.width.rounded(), height: shape.rect.size.height.rounded()))
                result.created.append(.node(id))
                drawn.append((id, shape.rect))
                if title.isEmpty { result.untitled.append(id) }
                continue
            }
            let options = choices(for: shape.kind, rect: shape.rect, family: parsed.family, language: state.language)
            guard let kind = options.first else {
                let origin = shape.rect.origin
                let d = shape.kind == nil
                    ? Decoration(kind: .ink, frame: shape.rect, text: title,
                                 strokes: shape.strokes.map { $0.points.map { Point(x: $0.x - origin.x, y: $0.y - origin.y) } })
                    : Decoration(kind: shape.kind == .ellipse ? .ellipse : .rectangle, frame: shape.rect, text: title)
                state.decorations.append(d)
                result.created.append(.decoration(d.id))
                continue
            }
            // Drawn inside an element: it becomes a child — turning a container into a boundary if need be.
            var parent = innermostGroup(containing: shape.rect, parsed: parsed, state: state, measure: measure)
            if let host = containerHost(for: shape.rect, parsed: parsed, geometry: geometry, family: parsed.family, language: state.language),
               parent.map({ p in parsed.descendants(of: p).contains { $0.id == host.id } }) ?? true {
                let caption: String?? = parsed.family == .c4 ? .some(host.kind.c4Caption?.replacingOccurrences(of: "External ", with: "") ?? "System") : nil
                if let hostFrame = geometry.frames[host.id], state.layout[host.id]?.size == nil {
                    state.layout[host.id] = NodeLayout(position: hostFrame.origin, size: hostFrame.size)
                }
                Engine.updateNode(&state, id: host.id, NodeEdit(kind: groupKind(family: parsed.family, language: state.language)!, stereotype: caption), measure: measure)
                parent = host.id
            }
            let fallbackTitle = shape.kind == nil ? "Person" : kind.displayName
            let id = Engine.addNode(&state, kind: kind, title: title.isEmpty ? fallbackTitle : title,
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
            drawn.append((id, shape.rect))
            if options.count > 1 { result.choices.append(Choice(id: id, options: options, needsName: title.isEmpty)) }
            if title.isEmpty { result.untitled.append(id) }
        }
        parsed = Engine.reconcile(&state, measure: measure)

        // Connectors → relationships / messages (or decorations).
        for c in connectors {
            var geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
            let label = takeText(near: [c.from, c.to], from: &texts, maxDistance: 36)
            func endpoint(_ p: Point) -> String? {
                node(at: p, parsed: parsed, geometry: geometry)
                    ?? drawn.filter { $0.rect.insetBy(-22).contains(p) && parsed.node($0.id) != nil }.min { area($0.rect) < area($1.rect) }?.id
            }
            if let a = endpoint(c.from), a == endpoint(c.to), parsed.family != .sequence, !parsed.node(a)!.kind.isGroup {
                result.edit = a
                continue
            }
            guard var from = endpoint(c.from), var to = endpoint(c.to),
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

    /// The group kind for this diagram, or nil if it has none (Mermaid ER and sequence diagrams).
    static func groupKind(family: DiagramFamily, language: SpecLanguage) -> NodeKind? {
        switch (family, language) {
        case (.sequence, _), (.erDiagram, .mermaid): nil
        case (.c4, _): .boundary
        default: .group
        }
    }

    /// Existing top-most elements lying (almost) entirely inside `r`.
    static func enclosedNodes(in r: Rect, parsed: ParsedDiagram, geometry: DiagramGeometry) -> [String] {
        let inside = Set(parsed.nodes.compactMap { n -> String? in
            guard let f = geometry.frames[n.id] else { return nil }
            let clipped = Rect(x: max(f.minX, r.minX), y: max(f.minY, r.minY),
                               width: max(0, min(f.maxX, r.maxX) - max(f.minX, r.minX)), height: max(0, min(f.maxY, r.maxY) - max(f.minY, r.minY)))
            return area(clipped) >= 0.85 * area(f) && area(f) < 0.8 * area(r) ? n.id : nil
        })
        return parsed.nodes.filter { inside.contains($0.id) && !($0.parent.map(inside.contains) ?? false) }.map(\.id)
    }

    /// An element big enough to hold `r` that can become a group: C4 systems, containers and components,
    /// and plain boxes. Classes, entities, people and databases never swallow what's drawn on them.
    static func containerHost(for r: Rect, parsed: ParsedDiagram, geometry: DiagramGeometry, family: DiagramFamily, language: SpecLanguage) -> DiagramNode? {
        guard groupKind(family: family, language: language) != nil else { return nil }
        let containers: Set<NodeKind> = [.system, .systemExt, .container, .containerExt, .component4, .component4Ext,
                                         .box, .rounded, .component, .node, .cloud, .folder]
        return parsed.nodes.filter { containers.contains($0.kind) }
            .compactMap { n in geometry.frames[n.id].flatMap { $0.contains(r.center) && area(r) < 0.6 * area($0) ? (n, $0) : nil } }
            .min { area($0.1) < area($1.1) }?.0
    }

    static func innermostGroup(containing r: Rect, parsed: ParsedDiagram, state: DrawingState, measure: @escaping TextMeasurer,
                               excluding: Set<String> = []) -> String? {
        let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
        return parsed.nodes.filter { $0.kind.isGroup && !excluding.contains($0.id) }
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
