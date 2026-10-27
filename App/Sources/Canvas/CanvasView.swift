import AppKit
import SwiftUI
import DrawerCore

enum Tool: Hashable {
    case select
    case connect
    /// Freehand: strokes are recognised as shapes, arrows and handwriting.
    case draw
    case node(NodeKind)
    case decoration(Decoration.Kind)
}

/// SwiftUI wrapper. `revision` is passed so SwiftUI calls `updateNSView` on every document change.
struct CanvasView: NSViewRepresentable {
    let document: DrawerDocument
    let revision: Int
    let selection: Set<ElementRef>
    /// The recognised element to ask about (passed so a change reaches `updateNSView`).
    var choice: String?
    @Binding var tool: Tool
    @Binding var zoom: CGFloat
    var undoManager: UndoManager?
    var fitRequest: Int

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.document = document
        v.onToolReset = { tool = .select }
        v.onToolChange = { tool = $0 }
        v.onZoomChange = { zoom = $0 }
        v.ink.document = document
        v.ink.onChange = { [weak v] in v?.needsDisplay = true }
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.document = document
        v.ink.document = document
        v.tool = tool
        document.undoManager = undoManager
        if abs(v.zoom - zoom) > 0.001 { v.setZoom(zoom, around: nil) }
        if v.lastFitRequest != fitRequest {
            v.lastFitRequest = fitRequest
            v.zoomToFit()
        }
        v.needsDisplay = true
        DispatchQueue.main.async { v.presentChoiceIfNeeded() }
        if let pending = document.pendingInlineEdit {
            document.pendingInlineEdit = nil
            DispatchQueue.main.async { v.beginInlineEdit(pending) }
        }
    }
}

final class CanvasNSView: NSView, NSTextFieldDelegate, NSPopoverDelegate {
    weak var document: DrawerDocument?
    var tool: Tool = .select {
        didSet {
            window?.invalidateCursorRects(for: self)
            if oldValue == .draw && tool != .draw { ink.commit() }
        }
    }
    let ink = InkSession()
    var onToolReset: () -> Void = {}
    var onToolChange: (Tool) -> Void = { _ in }
    var onZoomChange: (CGFloat) -> Void = { _ in }
    var lastFitRequest = 0

    private(set) var zoom: CGFloat = 1
    private var pan = CGPoint(x: 0, y: 0)
    private var didInitialFit = false

    private enum Interaction {
        case none
        case marquee(start: CGPoint, current: CGPoint, additive: Set<ElementRef>)
        case moving(refs: Set<ElementRef>, start: CGPoint, current: CGPoint)
        case resizing(id: String, start: CGPoint, original: Rect, current: CGPoint)
        case resizingDecoration(id: UUID, start: CGPoint, original: Rect, current: CGPoint)
        case waypoint(edge: String, index: Int, points: [Point])
        case spacing(edge: String, start: CGPoint, original: Double, current: CGPoint)
        case label(edge: String, start: CGPoint, original: Point, current: CGPoint)
        case connecting(from: String, current: CGPoint)
        case creating(kind: Decoration.Kind, start: CGPoint, current: CGPoint)
        case panning(startPan: CGPoint, start: CGPoint)
        case inking
    }
    private var interaction = Interaction.none
    private var hoverTarget: String?
    private var spaceDown = false
    private var inlineEditor: NSTextField?
    private var inlineTarget: ElementRef? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Coordinates

    private func toDiagram(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y) }
    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }
    private func location(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    func setZoom(_ z: CGFloat, around viewPoint: CGPoint?) {
        let newZoom = min(max(z, 0.1), 5)
        let anchor = viewPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let d = toDiagram(anchor)
        zoom = newZoom
        pan = CGPoint(x: anchor.x - d.x * zoom, y: anchor.y - d.y * zoom)
        needsDisplay = true
        repositionInlineEditor()
    }

    func zoomToFit() {
        guard let doc = document, let b = currentGeometry(doc).bounds, bounds.width > 10 else { return }
        let r = CGRect(b).insetBy(dx: -40, dy: -40)
        let z = min(max(min(bounds.width / r.width, bounds.height / r.height), 0.2), 1.5)
        zoom = z
        pan = CGPoint(x: bounds.midX - r.midX * z, y: bounds.midY - r.midY * z)
        onZoomChange(z)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if !didInitialFit, bounds.width > 10, let doc = document, !doc.parsed.nodes.isEmpty {
            didInitialFit = true
            zoomToFit()
        }
    }

    // MARK: Preview state during drags

    private func previewState(_ doc: DrawerDocument) -> DrawingState {
        var s = doc.state
        switch interaction {
        case let .moving(refs, start, current):
            let d = toDiagram(current), s0 = toDiagram(start)
            Engine.move(&s, refs, by: Point(x: d.x - s0.x, y: d.y - s0.y), parsed: doc.parsed, measure: appMeasurer)
        case let .resizing(id, start, original, current):
            let d = toDiagram(current), s0 = toDiagram(start)
            var l = s.layout[id] ?? NodeLayout(position: original.origin)
            l.size = Size(width: max(40, original.size.width + d.x - s0.x).rounded(), height: max(30, original.size.height + d.y - s0.y).rounded())
            s.layout[id] = l
        case let .resizingDecoration(id, start, original, current):
            let d = toDiagram(current), s0 = toDiagram(start)
            if let i = s.decorations.firstIndex(where: { $0.id == id }) {
                let isLine = [.line, .arrow].contains(s.decorations[i].kind)
                s.decorations[i].frame.size = Size(width: isLine ? original.size.width + d.x - s0.x : max(20, original.size.width + d.x - s0.x),
                                                   height: isLine ? original.size.height + d.y - s0.y : max(16, original.size.height + d.y - s0.y))
            }
        case let .waypoint(edge, _, points):
            var l = s.edgeLayout[edge] ?? EdgeLayout()
            l.waypoints = points
            s.edgeLayout[edge] = l
        case let .spacing(edge, start, original, current):
            var l = s.edgeLayout[edge] ?? EdgeLayout()
            let value = max(-20, original + (current.y - start.y) / zoom).rounded()
            l.extraSpacing = value == 0 ? nil : value
            s.edgeLayout[edge] = l
        case let .label(edge, start, original, current):
            let d = toDiagram(current), s0 = toDiagram(start)
            var l = s.edgeLayout[edge] ?? EdgeLayout()
            l.labelOffset = Point(x: original.x + d.x - s0.x, y: original.y + d.y - s0.y)
            s.edgeLayout[edge] = l
        default:
            break
        }
        return s
    }

    private func currentGeometry(_ doc: DrawerDocument) -> DiagramGeometry {
        DiagramGeometry(parsed: doc.parsed, state: previewState(doc), measure: appMeasurer)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NodePalette.canvas.setFill()
        bounds.fill()
        guard let doc = document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawGrid(ctx)
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        let state = previewState(doc)
        let renderer = DiagramRenderer(parsed: doc.parsed, state: state, selection: doc.selection, highlighted: hoverTarget, editing: inlineTarget)
        renderer.draw()
        drawSelectionHandles(doc, renderer: renderer)
        switch interaction {
        case let .connecting(from, current):
            if let f = renderer.geometry.frames[from] {
                let p = toDiagram(current)
                let path = NSBezierPath()
                path.move(to: CGPoint(x: f.midX, y: f.midY))
                path.line(to: p)
                path.lineWidth = 1.5 / zoom
                path.setLineDash([5 / zoom, 4 / zoom], count: 2, phase: 0)
                NodePalette.selection.setStroke()
                path.stroke()
            }
        case let .creating(kind, start, current):
            let r = Decoration(kind: kind, frame: decorationFrame(kind, start, current), text: kind == .note ? "Note" : "")
            DiagramRenderer(parsed: .empty, state: DrawingState(decorations: [r])).drawDecoration(r)
        default: break
        }
        if !ink.isEmpty { DiagramRenderer.strokeInk(ink.pending, color: NodePalette.selection, width: 2.2) }
        ctx.restoreGState()
        if case let .marquee(start, current, _) = interaction {
            let r = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            NodePalette.selection.withAlphaComponent(0.1).setFill()
            r.fill()
            NodePalette.selection.setStroke()
            NSBezierPath(rect: r).stroke()
        }
        if doc.parsed.nodes.isEmpty && doc.state.decorations.isEmpty {
            guard ink.isEmpty else { return }
            DiagramRenderer.drawText(tool == .draw
                                     ? "Draw boxes, circles, diamonds and arrows, and write names inside them. They turn into diagram elements when you pause."
                                     : "Write a PlantUML or Mermaid spec on the left, pick a template, draw freehand (D), or choose a shape from the toolbar and click here.",
                                     font: .systemFont(ofSize: 13), color: .secondaryLabelColor,
                                     in: CGRect(x: bounds.midX - 220, y: bounds.midY - 20, width: 440, height: 40))
        }
    }

    private func drawGrid(_ ctx: CGContext) {
        let spacing = 20 * zoom
        guard spacing > 6 else { return }
        NodePalette.grid.setFill()
        let startX = pan.x.truncatingRemainder(dividingBy: spacing)
        let startY = pan.y.truncatingRemainder(dividingBy: spacing)
        var x = startX
        while x < bounds.maxX {
            var y = startY
            while y < bounds.maxY {
                ctx.fill(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                y += spacing
            }
            x += spacing
        }
    }

    private func drawSelectionHandles(_ doc: DrawerDocument, renderer: DiagramRenderer) {
        let size = 8 / zoom
        func handle(_ p: CGPoint, round: Bool = false) {
            let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            let path = round ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
            NSColor.white.setFill(); path.fill()
            NodePalette.selection.setStroke(); path.lineWidth = 1.2 / zoom; path.stroke()
        }
        guard doc.selection.count == 1, let ref = doc.selection.first else { return }
        switch ref {
        case let .node(id):
            if let f = renderer.geometry.frames[id], doc.parsed.node(id)?.kind.isGroup == false {
                handle(CGPoint(x: f.maxX, y: f.maxY))
            }
        case let .edge(id):
            if let l = renderer.state.edgeLayout[id] {
                for w in l.waypoints { handle(CGPoint(w), round: true) }
            }
        case let .decoration(id):
            if let d = renderer.state.decorations.first(where: { $0.id == id }) {
                handle(CGPoint(x: d.frame.origin.x + d.frame.size.width, y: d.frame.origin.y + d.frame.size.height))
            }
        }
    }

    // MARK: Hit testing (diagram coordinates)

    private enum Hit {
        case node(String)
        case group(String)
        case edge(String, segment: Int)
        case edgeLabel(String)
        case waypoint(String, Int)
        case resizeHandle(String)
        case decorationHandle(UUID)
        case decoration(UUID)
    }

    private func hitTest(_ p: CGPoint, doc: DrawerDocument) -> Hit? {
        let geometry = currentGeometry(doc)
        let state = geometry.state
        let tolerance = 6 / zoom
        let pt = p.point
        if doc.selection.count == 1, let ref = doc.selection.first {
            switch ref {
            case let .node(id):
                if let f = geometry.frames[id], doc.parsed.node(id)?.kind.isGroup == false,
                   hypot(p.x - f.maxX, p.y - f.maxY) < tolerance * 1.5 { return .resizeHandle(id) }
            case let .edge(id):
                for (i, w) in (state.edgeLayout[id]?.waypoints ?? []).enumerated() where hypot(p.x - w.x, p.y - w.y) < tolerance * 1.5 {
                    return .waypoint(id, i)
                }
            case let .decoration(id):
                if let d = state.decorations.first(where: { $0.id == id }),
                   hypot(p.x - (d.frame.origin.x + d.frame.size.width), p.y - (d.frame.origin.y + d.frame.size.height)) < tolerance * 1.5 {
                    return .decorationHandle(id)
                }
            }
        }
        for d in state.decorations.reversed() where !DiagramRenderer.isBackground(d) {
            if decorationContains(d, p, tolerance: tolerance) { return .decoration(d.id) }
        }
        let renderer = DiagramRenderer(parsed: doc.parsed, state: state)
        for e in doc.parsed.edges.reversed() {
            guard let text = renderer.labelText(e) else { continue }
            let path = geometry.edgePath(e)
            let r = DiagramRenderer.labelRect(text, at: CGPoint(geometry.labelPosition(e, path: path)))
            if r.insetBy(dx: -3, dy: -2).contains(p) { return .edgeLabel(e.id) }
        }
        if let seq = geometry.sequence {
            var bestEdge: (String, Double)?
            for e in doc.parsed.edges {
                let d = DiagramGeometry.distance(from: pt, toPolyline: geometry.edgePath(e)).distance
                if d < tolerance, d < (bestEdge?.1 ?? .infinity) { bestEdge = (e.id, d) }
            }
            if let bestEdge { return .edge(bestEdge.0, segment: 0) }
            for (id, l) in seq.lifelines where abs(p.x - l.x) < tolerance * 1.5 && p.y >= l.top && p.y <= l.bottom { return .node(id) }
        }
        let leaves = doc.parsed.nodes.filter { !$0.kind.isGroup }
            .compactMap { n in geometry.frames[n.id].map { (n, $0) } }
            .filter { $0.1.contains(pt) }
            .sorted { $0.1.size.width * $0.1.size.height < $1.1.size.width * $1.1.size.height }
        if let n = leaves.first { return .node(n.0.id) }
        var best: (String, Double, Int)?
        for e in doc.parsed.edges {
            let (d, seg) = DiagramGeometry.distance(from: pt, toPolyline: geometry.edgePath(e))
            if d < tolerance, d < (best?.1 ?? .infinity) { best = (e.id, d, seg) }
        }
        if let best { return .edge(best.0, segment: best.2) }
        let groups = doc.parsed.nodes.filter(\.kind.isGroup)
            .compactMap { n in geometry.frames[n.id].map { (n, $0) } }
            .filter { $0.1.contains(pt) }
            .sorted { $0.1.size.width * $0.1.size.height < $1.1.size.width * $1.1.size.height }
        if let g = groups.first { return .group(g.0.id) }
        for d in state.decorations.reversed() where DiagramRenderer.isBackground(d) {
            if decorationContains(d, p, tolerance: tolerance) { return .decoration(d.id) }
        }
        return nil
    }

    private func decorationContains(_ d: Decoration, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        if d.kind == .line || d.kind == .arrow {
            let a = d.frame.origin
            let b = Point(x: a.x + d.frame.size.width, y: a.y + d.frame.size.height)
            return DiagramGeometry.distance(from: p.point, toPolyline: [a, b]).distance < tolerance
        }
        return CGRect(d.frame).standardized.insetBy(dx: -2, dy: -2).contains(p)
    }

    private func ref(for hit: Hit) -> ElementRef? {
        switch hit {
        case let .node(id), let .group(id), let .resizeHandle(id): .node(id)
        case let .edge(id, _), let .edgeLabel(id), let .waypoint(id, _): .edge(id)
        case let .decoration(id), let .decorationHandle(id): .decoration(id)
        }
    }

    private func deepestGroup(at p: CGPoint, doc: DrawerDocument) -> String? {
        let geometry = currentGeometry(doc)
        return doc.parsed.nodes.filter(\.kind.isGroup)
            .compactMap { n in geometry.frames[n.id].map { (n.id, $0) } }
            .filter { $0.1.contains(p.point) }
            .min { $0.1.size.width * $0.1.size.height < $1.1.size.width * $1.1.size.height }?.0
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitInlineEdit()
        guard let doc = document else { return }
        let v = location(event)
        let p = toDiagram(v)
        let shift = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)

        if spaceDown {
            interaction = .panning(startPan: pan, start: v)
            return
        }

        switch tool {
        case .draw:
            interaction = .inking
            ink.begin(at: p.point)
            return
        case let .node(kind):
            let parent = (kind.isGroup ? nil : deepestGroup(at: p, doc: doc))
            doc.addNode(kind: kind, at: p.point, parent: parent)
            if !event.modifierFlags.contains(.option) { onToolReset() }
            return
        case let .decoration(kind):
            interaction = .creating(kind: kind, start: p, current: p)
            return
        case .connect:
            if let hit = hitTest(p, doc: doc), case let .node(id) = hit {
                interaction = .connecting(from: id, current: v); connectStartY = p.y
            }
            return
        case .select:
            break
        }

        let hit = hitTest(p, doc: doc)
        if event.clickCount == 2, let hit {
            switch hit {
            case let .waypoint(edge, index):
                doc.change("Remove Bend") { state, _ in state.edgeLayout[edge]?.waypoints.remove(at: index) }
            case let .node(id), let .group(id): beginInlineEdit(.node(id))
            case let .edge(id, _), let .edgeLabel(id): beginInlineEdit(.edge(id))
            case let .decoration(id): beginInlineEdit(.decoration(id))
            default: break
            }
            return
        }

        guard let hit else {
            interaction = .marquee(start: v, current: v, additive: shift ? doc.selection : [])
            if !shift { select([]) }
            return
        }
        if event.modifierFlags.contains(.option), case let .node(id) = hit {
            interaction = .connecting(from: id, current: v); connectStartY = p.y
            return
        }
        let r = ref(for: hit)!
        if shift {
            var s = doc.selection
            if s.contains(r) { s.remove(r) } else { s.insert(r) }
            select(s)
        } else if !doc.selection.contains(r) {
            select([r])
        }

        let geometry = currentGeometry(doc)
        switch hit {
        case let .resizeHandle(id):
            interaction = .resizing(id: id, start: v, original: geometry.frames[id]!, current: v)
        case let .decorationHandle(id):
            interaction = .resizingDecoration(id: id, start: v, original: doc.state.decorations.first { $0.id == id }!.frame, current: v)
        case let .waypoint(edge, index):
            interaction = .waypoint(edge: edge, index: index, points: doc.state.edgeLayout[edge]?.waypoints ?? [])
        case let .edge(id, _) where geometry.sequence != nil:
            // Sequence messages: drag up/down to change the space above the message.
            interaction = .spacing(edge: id, start: v, original: doc.state.edgeLayout[id]?.extraSpacing ?? 0, current: v)
        case let .edge(id, segment):
            // Dragging the line inserts a bend point.
            guard doc.parsed.edge(id) != nil else { break }
            var points = doc.state.edgeLayout[id]?.waypoints ?? []
            let routing = doc.state.edgeLayout[id]?.routing ?? .straight
            let insertAt = routing == .orthogonal ? points.count : min(segment, points.count)
            points.insert(p.point, at: insertAt)
            interaction = .waypoint(edge: id, index: insertAt, points: points)
        case let .edgeLabel(id):
            interaction = .label(edge: id, start: v, original: doc.state.edgeLayout[id]?.labelOffset ?? .zero, current: v)
        case .node, .group, .decoration:
            let refs = doc.selection.filter { if case .edge = $0 { false } else { true } }
            interaction = .moving(refs: refs, start: v, current: v)
        }
    }

    private var didDrag = false
    private var connectLeftOrigin = false
    private var connectStartY: CGFloat = 0
    private var isSequence: Bool { document?.parsed.family == .sequence }

    /// The first message drawn below `y` — a new message dragged at `y` is inserted before it in the spec.
    private func messageBelow(_ y: CGFloat, doc: DrawerDocument) -> String? {
        let geometry = currentGeometry(doc)
        guard let seq = geometry.sequence else { return nil }
        return doc.parsed.edges.indices
            .compactMap { i in seq.messagePaths[i]?.first.map { (i, $0.y) } }
            .filter { $0.1 > Double(y) }
            .min { $0.1 < $1.1 }
            .map { doc.parsed.edges[$0.0].id }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let doc = document else { return }
        let v = location(event)
        didDrag = true
        switch interaction {
        case .inking:
            ink.add(toDiagram(v).point)
        case let .marquee(start, _, additive):
            interaction = .marquee(start: start, current: v, additive: additive)
            let r = CGRect(x: min(start.x, v.x), y: min(start.y, v.y), width: abs(v.x - start.x), height: abs(v.y - start.y))
            let a = toDiagram(r.origin), b = toDiagram(CGPoint(x: r.maxX, y: r.maxY))
            let dr = Rect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            let geometry = currentGeometry(doc)
            var s = additive
            for n in doc.parsed.nodes where !n.kind.isGroup {
                if let f = geometry.frames[n.id], dr.contains(f.origin), dr.contains(Point(x: f.maxX, y: f.maxY)) { s.insert(.node(n.id)) }
            }
            for d in doc.state.decorations where dr.intersects(CGRect(d.frame).standardized.rect) { s.insert(.decoration(d.id)) }
            select(s)
        case let .moving(refs, start, _):
            var current = v
            if !event.modifierFlags.contains(.command) {
                // Snap the movement to the 10pt grid.
                let d = toDiagram(v), s0 = toDiagram(start)
                let dx = ((d.x - s0.x) / 10).rounded() * 10, dy = ((d.y - s0.y) / 10).rounded() * 10
                current = toView(CGPoint(x: s0.x + dx, y: s0.y + dy))
            }
            interaction = .moving(refs: refs, start: start, current: current)
        case let .resizing(id, start, original, _):
            interaction = .resizing(id: id, start: start, original: original, current: v)
        case let .resizingDecoration(id, start, original, _):
            interaction = .resizingDecoration(id: id, start: start, original: original, current: v)
        case let .waypoint(edge, index, points):
            var pts = points
            let p = toDiagram(v)
            pts[index] = Point(x: p.x.rounded(), y: p.y.rounded())
            interaction = .waypoint(edge: edge, index: index, points: pts)
        case let .label(edge, start, original, _):
            interaction = .label(edge: edge, start: start, original: original, current: v)
        case let .spacing(edge, start, original, _):
            interaction = .spacing(edge: edge, start: start, original: original, current: v)
        case let .connecting(from, _):
            interaction = .connecting(from: from, current: v)
            let over: String? = if case let .node(id)? = hitTest(toDiagram(v), doc: doc) { id } else { nil }
            if over != from { connectLeftOrigin = true }
            if let over, over != from || isSequence { hoverTarget = over } else { hoverTarget = nil }
        case let .creating(kind, start, _):
            interaction = .creating(kind: kind, start: start, current: toDiagram(v))
        case let .panning(startPan, start):
            pan = CGPoint(x: startPan.x + v.x - start.x, y: startPan.y + v.y - start.y)
            repositionInlineEditor()
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let doc = document else { interaction = .none; return }
        let v = location(event)
        let finished = interaction
        let preview = previewState(doc)
        interaction = .none
        hoverTarget = nil
        switch finished {
        case .inking:
            ink.end()
        case let .moving(_, start, current) where hypot(current.x - start.x, current.y - start.y) > 0.5:
            doc.change("Move") { state, _ in state = preview }
        case .resizing, .resizingDecoration, .label:
            doc.change("Resize") { state, _ in state = preview }
        case .spacing:
            if didDrag { doc.change("Change Spacing") { state, _ in state = preview } }
        case .waypoint:
            // A plain click on an edge only selects it; a drag bends it.
            if didDrag { doc.change("Bend Connection") { state, _ in state = preview } }
        case let .connecting(from, _):
            let target: String? = if case let .node(to)? = hitTest(toDiagram(v), doc: doc) { to } else { nil }
            defer { connectLeftOrigin = false }
            if target == from && (!isSequence || !connectLeftOrigin) {
                // Let go on the block it started from: that's not a connection, edit the block instead.
                if case .connect = tool, !event.modifierFlags.contains(.option) { onToolReset() }
                select([.node(from)])
                DispatchQueue.main.async { self.beginInlineEdit(.node(from)) }
            } else if case let .node(to)? = hitTest(toDiagram(v), doc: doc), to != from || isSequence {
                doc.connect(from, to, before: isSequence ? messageBelow(connectStartY, doc: doc) : nil)
                if case .connect = tool, !event.modifierFlags.contains(.option) { onToolReset() }
            }
        case let .creating(kind, start, current):
            let frame = decorationFrame(kind, start, current)
            let d = Decoration(kind: kind, frame: frame, text: kind == .note ? "Note" : (kind == .text ? "Text" : ""),
                               fontSize: kind == .text ? 15 : 13)
            doc.change("Add \(kind.rawValue.capitalized)") { state, _ in state.decorations.append(d) }
            doc.selection = [.decoration(d.id)]
            onToolReset()
            if kind == .text || kind == .note { DispatchQueue.main.async { self.beginInlineEdit(.decoration(d.id)) } }
        default:
            break
        }
        didDrag = false
        needsDisplay = true
    }

    private func decorationFrame(_ kind: Decoration.Kind, _ start: CGPoint, _ current: CGPoint) -> Rect {
        let dx = current.x - start.x, dy = current.y - start.y
        if kind == .line || kind == .arrow {
            if hypot(dx, dy) < 4 { return Rect(x: start.x, y: start.y, width: 120, height: 0) }
            return Rect(x: start.x, y: start.y, width: dx, height: dy)
        }
        if abs(dx) < 4 && abs(dy) < 4 {
            let size: Size = switch kind {
            case .text: Size(width: 160, height: 24)
            case .note: Size(width: 170, height: 90)
            default: Size(width: 240, height: 160)
            }
            return Rect(x: start.x, y: start.y, width: size.width, height: size.height)
        }
        return Rect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(dx), height: abs(dy))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let doc = document else { return }
        let p = toDiagram(location(event))
        var newHover: String?
        if case .connect = tool, case let .node(id)? = hitTest(p, doc: doc) { newHover = id }
        if newHover != hoverTarget { hoverTarget = newHover; needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            setZoom(zoom * factor, around: location(event))
            onZoomChange(zoom)
            return
        }
        pan.x += event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
        pan.y += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        repositionInlineEditor()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: location(event))
        onZoomChange(zoom)
    }

    override func otherMouseDown(with event: NSEvent) { interaction = .panning(startPan: pan, start: location(event)) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { interaction = .none }

    override func resetCursorRects() {
        switch tool {
        case .select: addCursorRect(bounds, cursor: spaceDown ? .openHand : .arrow)
        case .draw: addCursorRect(bounds, cursor: spaceDown ? .openHand : .crosshair)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let doc = document else { return }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            doc.deleteSelection()
        case 53: // escape
            if !ink.isEmpty { ink.cancel() }
            else if case .select = tool { select([]) } else { onToolReset() }
            interaction = .none
            needsDisplay = true
        case 49: // space
            if !spaceDown { spaceDown = true; window?.invalidateCursorRects(for: self) }
        case 123, 124, 125, 126:
            let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: Point = switch event.keyCode {
            case 123: Point(x: -step, y: 0)
            case 124: Point(x: step, y: 0)
            case 125: Point(x: 0, y: step)
            default: Point(x: 0, y: -step)
            }
            let sel = doc.selection
            doc.change("Nudge") { state, parsed in Engine.move(&state, sel, by: delta, parsed: parsed, measure: appMeasurer) }
        case 36 where !ink.isEmpty: // return → recognise now
            ink.commit()
        case 36: // return → edit
            if doc.selection.count == 1, let r = doc.selection.first { beginInlineEdit(r) }
        default:
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            switch (plain, event.charactersIgnoringModifiers?.lowercased()) {
            case (true, "v"): onToolChange(.select)
            case (true, "c"): onToolChange(.connect)
            case (true, "d"): onToolChange(.draw)
            default: super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false; window?.invalidateCursorRects(for: self) }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let doc = document else { return }
        select(Set(doc.parsed.nodes.map { ElementRef.node($0.id) } + doc.parsed.edges.map { .edge($0.id) } + doc.state.decorations.map { .decoration($0.id) }))
    }

    /// ⌘C: the selection (or the whole diagram) as an image for other apps, and as a diagram for Drawer.
    @objc func copy(_ sender: Any?) {
        guard let doc = document else { return }
        Exporter.copy(doc)
    }

    @objc func cut(_ sender: Any?) {
        guard let doc = document, !doc.selection.isEmpty else { return }
        Exporter.copy(doc)
        doc.deleteSelection()
    }

    /// ⌘V: a diagram copied from Drawer, or a PNG/SVG exported by Drawer, becomes editable elements.
    @objc func paste(_ sender: Any?) {
        guard let doc = document else { return }
        guard let diagram = Exporter.pastedDiagram() else { NSSound.beep(); return }
        doc.paste(diagram)
        if doc.parsed.nodes.count == SpecParser.parse(diagram.spec, language: diagram.language).nodes.count { zoomToFit() }
    }

    @objc func delete(_ sender: Any?) { document?.deleteSelection() }

    private func select(_ s: Set<ElementRef>) {
        guard let doc = document, doc.selection != s else { return }
        doc.selectionOrigin = .canvas
        doc.selection = s
        needsDisplay = true
    }

    // MARK: Recognition question

    private var choicePopover: NSPopover?
    private var shownChoice: String?

    /// Pops up "What is this?" next to a recognised element whose kind was a guess.
    func presentChoiceIfNeeded() {
        guard let doc = document else { return }
        let current = doc.currentChoice?.id
        guard current != shownChoice else { return }
        shownChoice = current
        choicePopover?.delegate = nil
        choicePopover?.close()
        choicePopover = nil
        guard let id = current, window != nil, let f = currentGeometry(doc).frames[id] else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ChoicePrompt(document: doc))
        popover.delegate = self
        popover.show(relativeTo: toView(CGRect(f)), of: self, preferredEdge: .maxX)
        choicePopover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        // Closed by clicking elsewhere: keep the guess and ask about the next one, if any.
        choicePopover = nil
        if let doc = document, doc.currentChoice?.id == shownChoice {
            shownChoice = nil
            doc.skipChoice()
        }
        presentChoiceIfNeeded()
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let doc = document else { return nil }
        let p = toDiagram(location(event))
        let menu = NSMenu()
        if let hit = hitTest(p, doc: doc), let r = ref(for: hit) {
            if !doc.selection.contains(r) { select([r]) }
            switch r {
            case let .node(id):
                menu.addItem(item("Rename", #selector(menuRename(_:))))
                if let node = doc.parsed.node(id) {
                    let kinds = NodeKind.alternatives(to: node.kind, family: doc.parsed.family, language: doc.state.language)
                    if kinds.count > 1 {
                        let change = NSMenuItem(title: "Change Type", action: nil, keyEquivalent: "")
                        let sub = NSMenu()
                        for k in kinds {
                            let i = item(k.displayName, #selector(menuChangeKind(_:)))
                            i.representedObject = k.rawValue
                            i.state = k == node.kind ? .on : .off
                            sub.addItem(i)
                        }
                        change.submenu = sub
                        menu.addItem(change)
                    }
                }
                if doc.state.layout[id]?.size != nil { menu.addItem(item("Reset Size", #selector(menuResetSize(_:)))) }
            case .edge:
                menu.addItem(item("Edit Label", #selector(menuRename(_:))))
                let routing = NSMenuItem(title: "Routing", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for r in EdgeRouting.allCases {
                    let i = item(r.rawValue.capitalized, #selector(menuRouting(_:)))
                    i.representedObject = r.rawValue
                    sub.addItem(i)
                }
                routing.submenu = sub
                menu.addItem(routing)
                menu.addItem(item("Remove Bends", #selector(menuClearBends(_:))))
                menu.addItem(item("Reset Label Position", #selector(menuResetLabel(_:))))
                menu.addItem(item("Reverse Direction", #selector(menuReverse(_:))))
            case .decoration:
                menu.addItem(item("Edit Text", #selector(menuRename(_:))))
                menu.addItem(item("Bring to Front", #selector(menuFront(_:))))
                menu.addItem(item("Send to Back", #selector(menuBack(_:))))
            }
            menu.addItem(.separator())
            menu.addItem(item("Delete", #selector(delete(_:))))
        } else {
            menu.addItem(item("Zoom to Fit", #selector(menuFit(_:))))
            menu.addItem(item("Select All", #selector(selectAll(_:))))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func menuRename(_ sender: Any?) { if let r = document?.selection.first { beginInlineEdit(r) } }
    @objc private func menuFit(_ sender: Any?) { zoomToFit() }
    @objc private func menuChangeKind(_ sender: NSMenuItem) {
        guard let doc = document, let raw = sender.representedObject as? String, let kind = NodeKind(rawValue: raw),
              case let .node(id)? = doc.selection.first else { return }
        doc.pendingChoices.removeAll { $0.id == id }
        doc.updateNode(id, NodeEdit(kind: kind))
    }
    @objc private func menuResetSize(_ sender: Any?) {
        guard let doc = document else { return }
        let ids = doc.selection.compactMap { if case let .node(id) = $0 { id } else { nil } }
        doc.change("Reset Size") { state, _ in for id in ids { state.layout[id]?.size = nil } }
    }
    private var selectedEdges: [String] { document?.selection.compactMap { if case let .edge(id) = $0 { id } else { nil } } ?? [] }
    @objc private func menuRouting(_ sender: NSMenuItem) {
        guard let doc = document, let raw = sender.representedObject as? String, let routing = EdgeRouting(rawValue: raw) else { return }
        let ids = selectedEdges
        doc.change("Change Routing") { state, _ in
            for id in ids { var l = state.edgeLayout[id] ?? EdgeLayout(); l.routing = routing; state.edgeLayout[id] = l }
        }
    }
    @objc private func menuClearBends(_ sender: Any?) {
        let ids = selectedEdges
        document?.change("Remove Bends") { state, _ in for id in ids { state.edgeLayout[id]?.waypoints = [] } }
    }
    @objc private func menuResetLabel(_ sender: Any?) {
        let ids = selectedEdges
        document?.change("Reset Label") { state, _ in for id in ids { state.edgeLayout[id]?.labelOffset = .zero } }
    }
    @objc private func menuReverse(_ sender: Any?) {
        if let id = selectedEdges.first { document?.updateEdge(id, EdgeEdit(reverse: true)) }
    }
    private var selectedDecorations: Set<UUID> { Set(document?.selection.compactMap { if case let .decoration(id) = $0 { id } else { nil } } ?? []) }
    @objc private func menuFront(_ sender: Any?) {
        let ids = selectedDecorations
        document?.change("Bring to Front") { state, _ in
            let moving = state.decorations.filter { ids.contains($0.id) }
            state.decorations.removeAll { ids.contains($0.id) }
            state.decorations += moving
        }
    }
    @objc private func menuBack(_ sender: Any?) {
        let ids = selectedDecorations
        document?.change("Send to Back") { state, _ in
            let moving = state.decorations.filter { ids.contains($0.id) }
            state.decorations.removeAll { ids.contains($0.id) }
            state.decorations.insert(contentsOf: moving, at: 0)
        }
    }

    // MARK: Inline editing

    func beginInlineEdit(_ ref: ElementRef) {
        guard let doc = document else { return }
        commitInlineEdit()
        let geometry = currentGeometry(doc)
        var rect: CGRect
        var text: String
        var font = Fonts.title
        switch ref {
        case let .node(id):
            guard let f = geometry.frames[id], let n = doc.parsed.node(id) else { return }
            text = n.title
            let r = CGRect(f)
            rect = n.kind.isGroup ? CGRect(x: r.minX + 8, y: r.minY + 4, width: max(160, r.width - 16), height: 22)
                : CGRect(x: r.minX + 4, y: r.midY - 12, width: max(r.width - 8, 120), height: 24)
            if n.kind.isClassifier || n.kind == .entity || n.kind.isC4 { rect.origin.y = r.minY + 6 }
            if n.kind == .actor { rect = CGRect(x: r.minX - 30, y: r.maxY - 22, width: r.width + 60, height: 22) }
        case let .edge(id):
            guard let e = doc.parsed.edge(id) else { return }
            let path = geometry.edgePath(e)
            let p = CGPoint(geometry.labelPosition(e, path: path))
            text = e.label ?? ""
            rect = CGRect(x: p.x - 80, y: p.y - 11, width: 160, height: 22)
            font = Fonts.edgeLabel
        case let .decoration(id):
            guard let d = doc.state.decorations.first(where: { $0.id == id }) else { return }
            text = d.text
            let r = CGRect(d.frame).standardized
            rect = d.kind == .line || d.kind == .arrow ? CGRect(x: r.midX - 80, y: r.midY - 20, width: 160, height: 22)
                : CGRect(x: r.minX, y: r.minY, width: max(r.width, 120), height: max(min(r.height, 80), 22))
            font = .systemFont(ofSize: d.fontSize)
        }
        let field = NSTextField(string: text)
        field.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * zoom)
        field.alignment = {
            if case .decoration = ref { return .left }
            return .center
        }()
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.borderWidth = 1.5
        field.layer?.cornerRadius = 3
        field.delegate = self
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.frame = toView(rect)
        inlineRect = rect
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        inlineEditor = field
        inlineTarget = ref
    }

    private var inlineRect: CGRect = .zero

    private func repositionInlineEditor() {
        guard let field = inlineEditor else { return }
        field.frame = toView(inlineRect)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineEdit()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            commitInlineEdit()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitInlineEdit() }

    private func cancelInlineEdit() {
        inlineEditor?.removeFromSuperview()
        inlineEditor = nil
        inlineTarget = nil
        window?.makeFirstResponder(self)
    }

    private func commitInlineEdit() {
        guard let field = inlineEditor, let target = inlineTarget, let doc = document else { return }
        let text = field.stringValue
        inlineEditor = nil
        inlineTarget = nil
        field.removeFromSuperview()
        switch target {
        case let .node(id):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t != doc.parsed.node(id)?.title { doc.updateNode(id, NodeEdit(title: t)) }
        case let .edge(id):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t != (doc.parsed.edge(id)?.label ?? "") { doc.updateEdge(id, EdgeEdit(label: .some(t.isEmpty ? nil : t))) }
        case let .decoration(id):
            doc.change("Edit Text") { state, _ in
                if let i = state.decorations.firstIndex(where: { $0.id == id }) { state.decorations[i].text = text }
            }
        }
        needsDisplay = true
    }
}
