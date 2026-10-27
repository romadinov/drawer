import SwiftUI
import UIKit
import DrawerCore

enum MobileTool: Hashable { case select, draw }

/// Lets SwiftUI ask the canvas for things only it knows (visible area) or to do things (fit).
@MainActor
final class CanvasHandle {
    weak var view: CanvasUIView?
    var visibleCenter: Point { view?.visibleCenter ?? Point(x: 200, y: 200) }
    func zoomToFit() { view?.zoomToFit() }
}

struct MobileCanvas: UIViewRepresentable {
    let document: DrawerDocument
    let revision: Int
    let selection: Set<ElementRef>
    var tool: MobileTool
    var handle: CanvasHandle
    var onEdit: (ElementRef) -> Void

    func makeUIView(context: Context) -> CanvasUIView {
        let v = CanvasUIView()
        v.ink.onChange = { [weak v] in v?.setNeedsDisplay() }
        handle.view = v
        return v
    }

    func updateUIView(_ v: CanvasUIView, context: Context) {
        v.document = document
        v.ink.document = document
        v.tool = tool
        v.onEdit = onEdit
        handle.view = v
        v.setNeedsDisplay()
    }
}

/// Finger: tap to select, drag to move (or pan on empty space), two fingers to pan and pinch to zoom.
/// Apple Pencil always draws; in Draw mode a finger draws too.
final class CanvasUIView: UIView, UIGestureRecognizerDelegate {
    weak var document: DrawerDocument?
    let ink = InkSession()
    var tool: MobileTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .draw { ink.commit() }
            oneFinger.isEnabled = tool == .select
            tap.isEnabled = tool == .select
            doubleTap.isEnabled = tool == .select
        }
    }
    var onEdit: (ElementRef) -> Void = { _ in }

    private var zoom: CGFloat = 1
    private var pan = CGPoint(x: 24, y: 24)
    private var didInitialFit = false
    private var moving: (refs: Set<ElementRef>, start: CGPoint, current: CGPoint)?
    private var panStart: CGPoint?
    private var inkTouch: UITouch?

    private lazy var oneFinger = UIPanGestureRecognizer(target: self, action: #selector(oneFingerPan(_:)))
    private lazy var twoFinger = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = NodePalette.canvas
        contentMode = .redraw
        isMultipleTouchEnabled = true
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        oneFinger.maximumNumberOfTouches = 1
        twoFinger.minimumNumberOfTouches = 2
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        for g in [oneFinger, twoFinger, pinch, tap, doubleTap] as [UIGestureRecognizer] {
            g.allowedTouchTypes = fingers
            g.delegate = self
            addGestureRecognizer(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g == pinch && other == twoFinger) || (g == twoFinger && other == pinch)
    }

    // MARK: Coordinates

    private func toDiagram(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }

    var visibleCenter: Point { toDiagram(CGPoint(x: bounds.midX, y: bounds.midY)).point }

    func zoomToFit() {
        guard let doc = document, bounds.width > 0,
              let b = DiagramGeometry(parsed: doc.parsed, state: doc.state, measure: appMeasurer).bounds else { return }
        let r = CGRect(b).insetBy(dx: -30, dy: -30)
        zoom = min(max(min(bounds.width / r.width, bounds.height / r.height), 0.2), 2)
        pan = CGPoint(x: bounds.midX - r.midX * zoom, y: bounds.midY - r.midY * zoom)
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didInitialFit, bounds.width > 0, document != nil {
            didInitialFit = true
            zoomToFit()
        }
    }

    // MARK: Drawing

    private func previewState(_ doc: DrawerDocument) -> DrawingState {
        guard let m = moving else { return doc.state }
        var s = doc.state
        Engine.move(&s, m.refs, by: Point(x: m.current.x - m.start.x, y: m.current.y - m.start.y), parsed: doc.parsed, measure: appMeasurer)
        return s
    }

    override func draw(_ rect: CGRect) {
        guard let doc = document, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        DiagramRenderer(parsed: doc.parsed, state: previewState(doc), selection: doc.selection).draw()
        if !ink.isEmpty { DiagramRenderer.strokeInk(ink.pending, color: NodePalette.selection, width: 2.2) }
        ctx.restoreGState()
        if doc.parsed.nodes.isEmpty && doc.state.decorations.isEmpty && ink.isEmpty {
            DiagramRenderer.drawText("Draw boxes, circles, diamonds and arrows with Apple Pencil (or a finger in Draw mode), and write names inside them.\nThey become diagram elements when you pause.",
                                     font: .systemFont(ofSize: 15), color: .secondaryLabel,
                                     in: CGRect(x: bounds.midX - 180, y: bounds.midY - 40, width: 360, height: 80))
        }
    }

    // MARK: Ink (raw touches; gestures only see fingers)

    private func drawsInk(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (tool == .draw && touch.type == .direct)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if inkTouch != nil, inkTouch?.type == .direct, touches.contains(where: { $0.type == .direct }) {
            // A second finger: this is a pan/pinch, not writing.
            ink.abandonStroke(); inkTouch = nil
            return
        }
        guard inkTouch == nil, let t = touches.first(where: drawsInk) else { return }
        inkTouch = t
        ink.begin(at: toDiagram(t.location(in: self)).point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = inkTouch, touches.contains(t) else { return }
        for c in event?.coalescedTouches(for: t) ?? [t] { ink.add(toDiagram(c.location(in: self)).point) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = inkTouch, touches.contains(t) else { return }
        inkTouch = nil
        ink.end()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = inkTouch, touches.contains(t) else { return }
        inkTouch = nil
        ink.abandonStroke()
    }

    // MARK: Gestures

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let doc = document else { return }
        let ref = hit(toDiagram(g.location(in: self)), doc: doc)
        doc.selection = ref.map { [$0] } ?? []
        setNeedsDisplay()
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let doc = document, let ref = hit(toDiagram(g.location(in: self)), doc: doc) else { return }
        doc.selection = [ref]
        onEdit(ref)
    }

    @objc private func oneFingerPan(_ g: UIPanGestureRecognizer) {
        guard let doc = document else { return }
        let v = g.location(in: self)
        switch g.state {
        case .began:
            let start = toDiagram(CGPoint(x: v.x - g.translation(in: self).x, y: v.y - g.translation(in: self).y))
            if let ref = hit(start, doc: doc), !isEdge(ref) {
                if !doc.selection.contains(ref) { doc.selection = [ref] }
                moving = (doc.selection.filter { !isEdge($0) }, start, toDiagram(v))
            } else {
                panStart = pan
            }
        case .changed:
            if moving != nil { moving?.current = toDiagram(v) }
            else if let s = panStart { pan = CGPoint(x: s.x + g.translation(in: self).x, y: s.y + g.translation(in: self).y) }
        case .ended:
            if let m = moving {
                let delta = Point(x: m.current.x - m.start.x, y: m.current.y - m.start.y)
                moving = nil
                if hypot(delta.x, delta.y) > 0.5 {
                    doc.change("Move") { state, parsed in Engine.move(&state, m.refs, by: delta, parsed: parsed, measure: appMeasurer) }
                }
            }
            panStart = nil
        default:
            moving = nil; panStart = nil
        }
        setNeedsDisplay()
    }

    @objc private func twoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        pan = CGPoint(x: pan.x + t.x, y: pan.y + t.y)
        g.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let loc = g.location(in: self)
        let anchor = toDiagram(loc)
        zoom = min(max(zoom * g.scale, 0.15), 5)
        g.scale = 1
        pan = CGPoint(x: loc.x - anchor.x * zoom, y: loc.y - anchor.y * zoom)
        setNeedsDisplay()
    }

    // MARK: Hit testing

    private func isEdge(_ r: ElementRef) -> Bool { if case .edge = r { true } else { false } }

    private func hit(_ p: CGPoint, doc: DrawerDocument) -> ElementRef? {
        let state = doc.state
        let geometry = DiagramGeometry(parsed: doc.parsed, state: state, measure: appMeasurer)
        let tol = 10 / zoom
        func contains(_ d: Decoration) -> Bool {
            if d.kind == .line || d.kind == .arrow {
                let a = d.frame.origin
                return DiagramGeometry.distance(from: p.point, toPolyline: [a, Point(x: a.x + d.frame.size.width, y: a.y + d.frame.size.height)]).distance < tol
            }
            return CGRect(d.frame).standardized.insetBy(dx: -tol / 2, dy: -tol / 2).contains(p)
        }
        for d in state.decorations.reversed() where !DiagramRenderer.isBackground(d) && contains(d) { return .decoration(d.id) }
        let nodes = doc.parsed.nodes.compactMap { n in geometry.frames[n.id].flatMap { CGRect($0).contains(p) ? (n, CGRect($0)) : nil } }
        if let n = nodes.filter({ !$0.0.kind.isGroup }).min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) { return .node(n.0.id) }
        if let e = doc.parsed.edges.first(where: { DiagramGeometry.distance(from: p.point, toPolyline: geometry.edgePath($0)).distance < tol }) {
            return .edge(e.id)
        }
        if let seq = geometry.sequence,
           let lane = seq.lifelines.first(where: { abs($0.value.x - p.x) < tol && p.y >= $0.value.top && p.y <= $0.value.bottom }) {
            return .node(lane.key)
        }
        if let g = nodes.filter({ $0.0.kind.isGroup }).min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) { return .node(g.0.id) }
        for d in state.decorations.reversed() where DiagramRenderer.isBackground(d) && contains(d) { return .decoration(d.id) }
        return nil
    }
}
