import Foundation

public enum TextRole: Sendable {
    case title, body, caption, member, edgeLabel
}

/// Measures text. The app injects a real font-based measurer; tests use the approximation.
public typealias TextMeasurer = @Sendable (_ text: String, _ role: TextRole, _ maxWidth: Double?) -> Size

public let approximateMeasurer: TextMeasurer = { text, role, maxWidth in
    let charWidth: Double = switch role {
    case .title: 7.6
    case .member: 7.2
    case .caption, .edgeLabel: 6.2
    case .body: 6.8
    }
    let lineHeight: Double = role == .title ? 17 : 15
    var lines = 0
    var widest = 0.0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let w = Double(line.count) * charWidth
        if let maxWidth, w > maxWidth {
            lines += Int((w / maxWidth).rounded(.up))
            widest = maxWidth
        } else {
            lines += 1
            widest = max(widest, w)
        }
    }
    return Size(width: widest, height: Double(max(lines, 1)) * lineHeight)
}

/// Layout constants shared by geometry and rendering.
public enum Metrics {
    public static let padding = 12.0
    public static let groupPadding = 24.0
    public static let groupHeader = 26.0
    public static let c4Width = 210.0
    public static let personHead = 34.0
    public static let compartmentGap = 6.0
    public static let memberLine = 16.0
}

/// Computes node frames and edge paths for a parsed diagram + drawing state.
public struct DiagramGeometry: Sendable {
    public let parsed: ParsedDiagram
    public let state: DrawingState
    public let measure: TextMeasurer
    public private(set) var frames: [String: Rect] = [:]
    public private(set) var sequence: SequenceGeometry?
    private var edgeIndex: [String: Int] = [:]

    public init(parsed: ParsedDiagram, state: DrawingState, measure: @escaping TextMeasurer = approximateMeasurer, overrides: [String: Point] = [:]) {
        self.parsed = parsed
        self.state = state
        self.measure = measure
        if parsed.family == .sequence {
            let seq = SequenceGeometry(parsed: parsed, state: state, measure: measure, overrides: overrides)
            sequence = seq
            frames = seq.headers
            edgeIndex = Dictionary(parsed.edges.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            return
        }
        var frames: [String: Rect] = [:]
        for node in parsed.nodes where !node.kind.isGroup {
            let size = state.layout[node.id]?.size ?? Self.intrinsicSize(node, measure: measure)
            var p = state.layout[node.id]?.position ?? .zero
            if let o = overrides[node.id] { p = Point(x: p.x + o.x, y: p.y + o.y) }
            frames[node.id] = Rect(x: p.x, y: p.y, width: size.width, height: size.height)
        }
        // Groups wrap their descendants; inner groups first.
        let groups = parsed.nodes.filter(\.kind.isGroup)
        func depth(_ n: DiagramNode) -> Int {
            var d = 0
            var p = n.parent
            while let id = p, d < 50 { d += 1; p = parsed.node(id)?.parent }
            return d
        }
        for group in groups.sorted(by: { depth($0) > depth($1) }) {
            let children = parsed.children(of: group.id).compactMap { frames[$0.id] }
            let isC4 = group.kind == .boundary
            if let first = children.first {
                let box = children.dropFirst().reduce(first) { $0.union($1) }
                let pad = Metrics.groupPadding
                let top = isC4 ? pad : pad + Metrics.groupHeader
                let bottom = isC4 ? pad + Metrics.groupHeader + 8 : pad
                var frame = Rect(x: box.minX - pad, y: box.minY - top, width: box.size.width + 2 * pad, height: box.size.height + top + bottom)
                // A group drawn (or resized) bigger than its contents keeps that size.
                if let l = state.layout[group.id], let s = l.size {
                    var p = l.position
                    if let o = overrides[group.id] { p = Point(x: p.x + o.x, y: p.y + o.y) }
                    frame = frame.union(Rect(x: p.x, y: p.y, width: s.width, height: s.height))
                }
                frames[group.id] = frame
            } else {
                var p = state.layout[group.id]?.position ?? .zero
                if let o = overrides[group.id] { p = Point(x: p.x + o.x, y: p.y + o.y) }
                let s = state.layout[group.id]?.size ?? Size(width: 220, height: 140)
                frames[group.id] = Rect(x: p.x, y: p.y, width: s.width, height: s.height)
            }
        }
        self.frames = frames
    }

    public var bounds: Rect? {
        var all = Array(frames.values) + state.decorations.map { normalized($0.frame) }
        if let s = sequence {
            all.append(Rect(x: s.left, y: SequenceGeometry.top, width: max(s.right - s.left, 1), height: s.bottom - SequenceGeometry.top))
            all += s.notes.map(\.rect) + s.fragments.map(\.rect)
        }
        for edge in parsed.edges { all += edgePath(edge).map { Rect(x: $0.x, y: $0.y, width: 1, height: 1) } }
        guard let first = all.first else { return nil }
        return all.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: Intrinsic sizes

    public static func intrinsicSize(_ node: DiagramNode, measure: TextMeasurer) -> Size {
        let pad = Metrics.padding
        let title = measure(node.title, .title, node.kind.isC4 ? Metrics.c4Width - 2 * pad : 260)
        func round(_ s: Size) -> Size { Size(width: s.width.rounded(.up), height: s.height.rounded(.up)) }
        switch node.kind {
        case let k where k.isC4:
            var h = pad + title.height + 4
            let caption = measure(c4CaptionText(node), .caption, Metrics.c4Width - 2 * pad)
            h += caption.height
            if let d = node.description, !d.isEmpty { h += 8 + measure(d, .body, Metrics.c4Width - 2 * pad).height }
            h += pad
            if k == .person || k == .personExt { h += Metrics.personHead * 0.6 }
            if k.isCylinder { h += 14 }
            return round(Size(width: Metrics.c4Width, height: max(h, 110)))
        case let k where k.isClassifier || k == .entity:
            var w = title.width
            var h = pad / 2 + title.height + pad / 2
            if let s = stereotypeText(node) {
                let st = measure(s, .caption, nil)
                w = max(w, st.width)
                h += st.height
            }
            let members = node.fields + node.methods
            for m in members { w = max(w, measure(m, .member, nil).width) }
            h += Metrics.compartmentGap + Double(node.fields.count) * Metrics.memberLine + Metrics.compartmentGap
            if k != .entity { h += Metrics.compartmentGap + Double(node.methods.count) * Metrics.memberLine + Metrics.compartmentGap }
            return round(Size(width: max(w + 2 * pad, 120), height: max(h, 50)))
        case .actor, .seqBoundary, .seqControl, .seqEntity:
            return round(Size(width: max(title.width + 8, 50), height: 62 + title.height))
        case .circle:
            let d = max(title.width + 2 * pad, 56)
            return round(Size(width: d, height: d))
        case .diamond:
            return round(Size(width: max(title.width * 1.6 + 2 * pad, 100), height: max(title.height * 2 + 2 * pad, 70)))
        case .usecase:
            return round(Size(width: max(title.width * 1.3 + 2 * pad, 110), height: max(title.height + 2 * pad, 50)))
        case .database, .queue:
            return round(Size(width: max(title.width + 2 * pad, 90), height: max(title.height + 2 * pad + 16, 64)))
        default:
            var h = title.height + 2 * pad
            var w = title.width
            if let s = node.stereotype {
                let st = measure("«\(s)»", .caption, nil)
                h += st.height
                w = max(w, st.width)
            }
            if [.component, .node, .artifact, .folder, .note].contains(node.kind) { w += 20 }
            if node.kind == .hexagon || node.kind == .parallelogram || node.kind == .stadium { w += 30 }
            return round(Size(width: max(w + 2 * pad, 100), height: max(h, 44)))
        }
    }

    public static func c4CaptionText(_ node: DiagramNode) -> String {
        let base = node.kind.c4Caption ?? ""
        if let t = node.technology, !t.isEmpty { return "[\(base): \(t)]" }
        return "[\(base)]"
    }

    public static func stereotypeText(_ node: DiagramNode) -> String? {
        switch node.kind {
        case .interfaceType: return "«interface»"
        case .enumType: return "«enumeration»"
        case .abstractClass: return node.stereotype.map { "«\($0)»" } ?? nil
        default: return node.stereotype.map { "«\($0)»" }
        }
    }

    // MARK: Edges

    private func normalized(_ r: Rect) -> Rect {
        Rect(x: min(r.minX, r.maxX), y: min(r.minY, r.maxY), width: abs(r.size.width), height: abs(r.size.height))
    }

    /// Polyline for an edge, endpoints clipped to node outlines.
    public func edgePath(_ edge: DiagramEdge, waypointOverride: [Point]? = nil) -> [Point] {
        if let s = sequence { return edgeIndex[edge.id].flatMap { s.messagePaths[$0] } ?? [] }
        guard let a = frames[edge.from], let b = frames[edge.to] else { return [] }
        let layout = state.edgeLayout[edge.id] ?? EdgeLayout()
        let waypoints = waypointOverride ?? layout.waypoints
        let kindA = parsed.node(edge.from)?.kind ?? .box
        let kindB = parsed.node(edge.to)?.kind ?? .box

        if edge.from == edge.to {
            // Self loop on the top-right corner.
            let p0 = Point(x: a.maxX - a.size.width * 0.25, y: a.minY)
            let p3 = Point(x: a.maxX, y: a.minY + a.size.height * 0.25)
            return [p0, Point(x: p0.x, y: a.minY - 30), Point(x: a.maxX + 30, y: a.minY - 30), Point(x: a.maxX + 30, y: p3.y), p3]
        }

        if layout.routing == .orthogonal {
            return orthogonalPath(a, b, waypoints: waypoints)
        }
        let first = waypoints.first ?? b.center
        let last = waypoints.last ?? a.center
        let start = Self.clip(from: a, kind: kindA, toward: first)
        let end = Self.clip(from: b, kind: kindB, toward: last)
        return [start] + waypoints + [end]
    }

    private func orthogonalPath(_ a: Rect, _ b: Rect, waypoints: [Point]) -> [Point] {
        if !waypoints.isEmpty {
            var pts: [Point] = []
            var current = sidePoint(a, toward: waypoints[0])
            pts.append(current)
            for w in waypoints + [sidePoint(b, toward: waypoints.last!)] {
                if current.x != w.x && current.y != w.y { pts.append(Point(x: w.x, y: current.y)) }
                pts.append(w)
                current = w
            }
            return pts
        }
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        let horizontalGap = max(b.minX - a.maxX, a.minX - b.maxX)
        let verticalGap = max(b.minY - a.maxY, a.minY - b.maxY)
        if horizontalGap > verticalGap {
            let sx = dx > 0 ? a.maxX : a.minX
            let ex = dx > 0 ? b.minX : b.maxX
            let midX = (sx + ex) / 2
            if abs(a.midY - b.midY) < 1 { return [Point(x: sx, y: a.midY), Point(x: ex, y: b.midY)] }
            return [Point(x: sx, y: a.midY), Point(x: midX, y: a.midY), Point(x: midX, y: b.midY), Point(x: ex, y: b.midY)]
        } else {
            let sy = dy > 0 ? a.maxY : a.minY
            let ey = dy > 0 ? b.minY : b.maxY
            let midY = (sy + ey) / 2
            if abs(a.midX - b.midX) < 1 { return [Point(x: a.midX, y: sy), Point(x: b.midX, y: ey)] }
            return [Point(x: a.midX, y: sy), Point(x: a.midX, y: midY), Point(x: b.midX, y: midY), Point(x: b.midX, y: ey)]
        }
    }

    private func sidePoint(_ r: Rect, toward p: Point) -> Point {
        let dx = p.x - r.midX, dy = p.y - r.midY
        if abs(dx) * r.size.height > abs(dy) * r.size.width {
            return Point(x: dx > 0 ? r.maxX : r.minX, y: r.midY)
        }
        return Point(x: r.midX, y: dy > 0 ? r.maxY : r.minY)
    }

    /// Intersection of the ray from the rect's centre toward `p` with the node outline.
    public static func clip(from r: Rect, kind: NodeKind, toward p: Point) -> Point {
        let c = r.center
        let dx = p.x - c.x, dy = p.y - c.y
        if dx == 0 && dy == 0 { return c }
        let hw = r.size.width / 2, hh = r.size.height / 2
        switch kind {
        case .circle, .usecase:
            let t = 1 / sqrt((dx * dx) / (hw * hw) + (dy * dy) / (hh * hh))
            return Point(x: c.x + dx * t, y: c.y + dy * t)
        case .diamond:
            let t = 1 / (abs(dx) / hw + abs(dy) / hh)
            return Point(x: c.x + dx * t, y: c.y + dy * t)
        default:
            let tx = dx != 0 ? hw / abs(dx) : .infinity
            let ty = dy != 0 ? hh / abs(dy) : .infinity
            let t = min(tx, ty)
            return Point(x: c.x + dx * t, y: c.y + dy * t)
        }
    }

    /// Point at half the polyline's length, plus the stored label offset.
    public func labelPosition(_ edge: DiagramEdge, path: [Point]) -> Point {
        if let s = sequence, let i = edgeIndex[edge.id], let p = s.labelPoints[i] { return p }
        let mid = Self.pointAlong(path, fraction: 0.5)
        let o = state.edgeLayout[edge.id]?.labelOffset ?? .zero
        return Point(x: mid.x + o.x, y: mid.y + o.y)
    }

    public static func pointAlong(_ path: [Point], fraction: Double) -> Point {
        guard path.count > 1 else { return path.first ?? .zero }
        var total = 0.0
        for i in 1..<path.count { total += hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y) }
        var remaining = total * fraction
        for i in 1..<path.count {
            let seg = hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y)
            if remaining <= seg, seg > 0 {
                let t = remaining / seg
                return Point(x: path[i - 1].x + (path[i].x - path[i - 1].x) * t, y: path[i - 1].y + (path[i].y - path[i - 1].y) * t)
            }
            remaining -= seg
        }
        return path.last!
    }

    /// Distance from a point to a polyline.
    public static func distance(from p: Point, toPolyline path: [Point]) -> (distance: Double, segment: Int) {
        var best = (Double.infinity, 0)
        guard path.count > 1 else { return best }
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = max(0, min(1, t))
            let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if d < best.0 { best = (d, i - 1) }
        }
        return best
    }
}
