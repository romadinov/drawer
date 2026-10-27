import Foundation

/// One pen-down … pen-up sequence of points, in diagram coordinates.
public struct InkStroke: Equatable, Sendable {
    public var points: [Point]
    public init(_ points: [Point]) { self.points = points }

    public var bounds: Rect { InkMath.bounds(points) }
    public var length: Double { InkMath.length(points) }
    var start: Point { points.first ?? .zero }
    var end: Point { points.last ?? .zero }
}

public enum InkShapeKind: String, Sendable {
    case rectangle, ellipse, diamond
}

/// What a batch of strokes turned out to be. Text still has to be read (OCR happens in the app,
/// which has Vision); `text` is nil until then, and stays nil if nothing legible was found.
public enum InkItem: Equatable, Sendable {
    case shape(InkShapeKind, Rect)
    /// A stick figure. Its strokes are kept in case the diagram has no person element.
    case person(Rect, strokes: [InkStroke])
    case connector(from: Point, to: Point, headAtStart: Bool, headAtEnd: Bool)
    case text(String?, bounds: Rect, strokes: [InkStroke])

    public var bounds: Rect {
        switch self {
        case let .shape(_, r), let .person(r, _): r
        case let .connector(a, b, _, _): InkMath.bounds([a, b])
        case let .text(_, r, _): r
        }
    }
}

/// Turns freehand strokes into rectangles, ellipses, diamonds, lines/arrows and text clusters.
/// Purely geometric, so the same recogniser runs on the Mac and the iPad.
public enum InkRecognizer {
    public static func recognize(_ input: [InkStroke]) -> [InkItem] {
        let strokes = input.filter { !$0.points.isEmpty }
        var used = Set<Int>()
        var shapes: [(kind: InkShapeKind, rect: Rect, members: [Int])] = []
        var people: [InkItem] = []

        // 0. Stick figures, before their limbs get mistaken for lines and arrowheads.
        let notBoxes = strokes.indices.filter { i in
            let b = strokes[i].bounds
            return closedShape(strokes[i].points) == nil || max(b.size.width, b.size.height) <= 90
        }
        for group in touchingGroups(strokes, notBoxes) where isStickFigure(group.map { strokes[$0] }) {
            let figure = group.map { strokes[$0] }
            people.append(.person(InkMath.bounds(figure.flatMap(\.points)), strokes: figure))
            used.formUnion(group)
        }

        // 1. Single-stroke closed shapes.
        for (i, s) in strokes.enumerated() where !used.contains(i) {
            if let kind = closedShape(s.points) { shapes.append((kind, s.bounds, [i])); used.insert(i) }
        }
        // 2. Closed shapes drawn in several strokes (e.g. a box as four sides).
        for chain in closedChains(strokes, excluding: used) {
            let kind = closedShape(chain.points, alreadyClosed: true) ?? .rectangle
            shapes.append((kind, InkMath.bounds(chain.points), chain.members)); used.formUnion(chain.members)
        }
        // 3. Lines and arrows: straight strokes, one-stroke arrows, and shafts with separately drawn heads.
        var connectors: [(index: Int, from: Point, to: Point, headStart: Bool, headEnd: Bool)] = []
        for (i, s) in strokes.enumerated() where !used.contains(i) {
            if let a = oneStrokeArrow(s.points) {
                connectors.append((i, a.from, a.to, a.headStart, a.headEnd)); used.insert(i)
            } else if isStraight(s.points), s.length >= 40 {
                connectors.append((i, s.start, s.end, false, false)); used.insert(i)
            } else if isCurvedConnector(s) {
                connectors.append((i, s.start, s.end, false, false)); used.insert(i)
            }
        }
        for c in connectors.indices {
            let (from, to) = (connectors[c].from, connectors[c].to)
            let length = InkMath.distance(from, to)
            for (j, s) in strokes.enumerated() where !used.contains(j) {
                if isHead(s, at: to, toward: from, shaftLength: length) { connectors[c].headEnd = true; used.insert(j) }
                else if isHead(s, at: from, toward: to, shaftLength: length) { connectors[c].headStart = true; used.insert(j) }
            }
        }
        // 4. A small "shape" sitting in a line of handwriting is really a letter (o, D, 0…).
        let loose = strokes.indices.filter { !used.contains($0) }
        shapes.removeAll { shape in
            let r = shape.rect
            guard max(r.size.width, r.size.height) < 80 else { return false }
            let grow = min(r.size.height, 40) * 0.8
            let zone = Rect(x: r.minX - grow, y: r.minY - grow / 2, width: r.size.width + 2 * grow, height: r.size.height + grow)
            let inLine = loose.contains { j in
                let b = strokes[j].bounds
                return max(b.size.width, b.size.height) < 80 && zone.intersects(b) && !r.contains(b.center)
            }
            if inLine { used.subtract(shape.members) }
            return inLine
        }
        var items: [InkItem] = people + shapes.map { .shape($0.kind, $0.rect) }
        items += connectors.map { .connector(from: $0.from, to: $0.to, headAtStart: $0.headStart, headAtEnd: $0.headEnd) }
        // 5. Everything else is handwriting, clustered into words/lines.
        let rest = strokes.indices.filter { !used.contains($0) }.map { strokes[$0] }
        for cluster in clusterText(rest) {
            items.append(.text(nil, bounds: InkMath.bounds(cluster.flatMap(\.points)), strokes: cluster))
        }
        return items
    }

    // MARK: Closed shapes

    static func closedShape(_ points: [Point], alreadyClosed: Bool = false) -> InkShapeKind? {
        guard points.count >= 8 else { return nil }
        let r = InkMath.bounds(points)
        let w = r.size.width, h = r.size.height
        let minDim = min(w, h), maxDim = max(w, h)
        guard minDim >= 18, maxDim >= 30 else { return nil }
        let perimeter = 2 * (w + h)
        let length = InkMath.length(points)
        if !alreadyClosed {
            let gap = InkMath.distance(points.first!, points.last!)
            guard gap < max(18, 0.22 * maxDim), length > 0.6 * perimeter * 0.785 else { return nil }
        }
        // A closed stroke that wanders far more than its outline is a scribble, not a shape.
        guard length < perimeter * 1.9 else { return nil }

        let corners = [Point(x: r.minX, y: r.minY), Point(x: r.maxX, y: r.minY), Point(x: r.maxX, y: r.maxY), Point(x: r.minX, y: r.maxY)]
        let cornerGap = corners.map { c in points.map { InkMath.distance($0, c) }.min()! }.reduce(0, +) / 4
        let mids = [Point(x: r.midX, y: r.minY), Point(x: r.maxX, y: r.midY), Point(x: r.midX, y: r.maxY), Point(x: r.minX, y: r.midY)]
        let midGap = mids.map { m in points.map { InkMath.distance($0, m) }.min()! }.max()!
        let fill = InkMath.area(InkMath.convexHull(points)) / max(w * h, 1)

        if cornerGap / minDim < 0.12 || fill > 0.9 { return .rectangle }
        if fill < 0.68 && midGap / minDim < 0.14 { return .diamond }
        return .ellipse
    }

    struct Chain { var members: [Int]; var points: [Point] }

    /// Joins open strokes end to end; a chain that comes back to its start is one closed shape.
    static func closedChains(_ strokes: [InkStroke], excluding used: Set<Int>) -> [Chain] {
        var available = strokes.indices.filter { !used.contains($0) && strokes[$0].length >= 25 }
        var result: [Chain] = []
        while let first = available.first {
            available.removeFirst()
            var chain = Chain(members: [first], points: strokes[first].points)
            var extended = true
            while extended {
                extended = false
                let size = InkMath.bounds(chain.points)
                let tol = max(16, 0.1 * max(size.size.width, size.size.height))
                for (k, j) in available.enumerated() {
                    let s = strokes[j].points
                    if InkMath.distance(chain.points.last!, s.first!) < tol { chain.points += s }
                    else if InkMath.distance(chain.points.last!, s.last!) < tol { chain.points += s.reversed() }
                    else if InkMath.distance(chain.points.first!, s.last!) < tol { chain.points = s + chain.points }
                    else if InkMath.distance(chain.points.first!, s.first!) < tol { chain.points = s.reversed() + chain.points }
                    else { continue }
                    chain.members.append(j)
                    available.remove(at: k)
                    extended = true
                    break
                }
            }
            let r = InkMath.bounds(chain.points)
            let tol = max(18, 0.12 * max(r.size.width, r.size.height))
            if chain.members.count >= 2, InkMath.distance(chain.points.first!, chain.points.last!) < tol,
               min(r.size.width, r.size.height) >= 18, max(r.size.width, r.size.height) >= 30 {
                result.append(chain)
            } else {
                // Not closed: give the strokes back (except the first, which can't start a closed chain).
                available += chain.members.dropFirst()
                available.sort()
            }
        }
        return result
    }

    // MARK: Stick figures

    /// Strokes that touch each other (within a few points).
    static func touchingGroups(_ strokes: [InkStroke], _ indices: [Int]) -> [[Int]] {
        var parent = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        func find(_ i: Int) -> Int { var i = i; while parent[i]! != i { i = parent[i]! }; return i }
        let margin = 10.0
        for (k, i) in indices.enumerated() {
            for j in indices[(k + 1)...] {
                let a = strokes[i].bounds, b = strokes[j].bounds
                guard Rect(x: a.minX - margin, y: a.minY - margin, width: a.size.width + 2 * margin, height: a.size.height + 2 * margin).intersects(b) else { continue }
                let close = strokes[i].points.contains { p in strokes[j].points.contains { InkMath.distance(p, $0) < margin } }
                if close { parent[find(i)] = find(j) }
            }
        }
        return Dictionary(grouping: indices, by: find).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// A tall, sparse figure with a vertical spine near the middle, arms reaching out on both
    /// sides in the upper part and legs spreading apart at the bottom. A head is optional.
    static func isStickFigure(_ strokes: [InkStroke]) -> Bool {
        guard (1...6).contains(strokes.count) else { return false }
        let points = strokes.flatMap(\.points)
        let r = InkMath.bounds(points)
        let w = r.size.width, h = r.size.height
        guard h >= 60, h >= 1.1 * w else { return false }
        let ink = strokes.reduce(0) { $0 + $1.length }
        guard ink >= 1.6 * h, ink <= 4.5 * h else { return false }

        let segments = strokes.flatMap { s -> [(Point, Point)] in
            let v = InkMath.simplify(s.points, epsilon: max(3, 0.04 * h))
            return Array(zip(v, v.dropFirst()))
        }
        let vertical = segments.filter { abs($0.1.x - $0.0.x) <= 0.35 * abs($0.1.y - $0.0.y) && abs($0.1.y - $0.0.y) >= 0.3 * h }
        guard let spine = vertical.max(by: { abs($0.1.y - $0.0.y) < abs($1.1.y - $1.0.y) }) else { return false }
        let spineX = (spine.0.x + spine.1.x) / 2
        guard abs(spineX - r.midX) <= 0.3 * w + 5, min(spine.0.y, spine.1.y) <= r.minY + 0.35 * h else { return false }

        let upper = points.filter { $0.y < r.minY + 0.6 * h }.map(\.x)
        guard let left = upper.min(), let right = upper.max(), spineX - left >= 0.15 * h, right - spineX >= 0.15 * h else { return false }
        let feet = points.filter { $0.y > r.maxY - 0.2 * h }.map(\.x)
        guard let l = feet.min(), let rr = feet.max(), rr - l >= 0.15 * h else { return false }
        return true
    }

    // MARK: Lines and arrows

    static func isStraight(_ points: [Point]) -> Bool {
        guard points.count >= 2 else { return false }
        let l = InkMath.length(points)
        return l > 0 && InkMath.distance(points.first!, points.last!) / l > 0.93
    }

    /// A long open stroke whose ends are far apart (a hand-drawn curved connector), as opposed to cursive writing.
    static func isCurvedConnector(_ s: InkStroke) -> Bool {
        let l = s.length
        let r = s.bounds
        return l >= 90 && InkMath.distance(s.start, s.end) / l > 0.6 && max(r.size.width, r.size.height) >= 90
    }

    /// Shaft plus head drawn without lifting the pen.
    static func oneStrokeArrow(_ points: [Point]) -> (from: Point, to: Point, headStart: Bool, headEnd: Bool)? {
        let r = InkMath.bounds(points)
        let diag = hypot(r.size.width, r.size.height)
        guard diag >= 40 else { return nil }
        let v = InkMath.simplify(points, epsilon: max(4, 0.05 * diag))
        guard v.count >= 4 else { return nil }
        var shaft = 0
        for i in 0..<(v.count - 1) where InkMath.distance(v[i], v[i + 1]) > InkMath.distance(v[shaft], v[shaft + 1]) { shaft = i }
        let shaftLength = InkMath.distance(v[shaft], v[shaft + 1])
        let total = InkMath.length(v)
        guard shaftLength >= 40, shaftLength >= 0.5 * total else { return nil }
        let before = Array(v[...shaft]), after = Array(v[(shaft + 1)...])
        func isHeadPart(_ part: [Point], tip: Point) -> Bool {
            let l = InkMath.length(part)
            return l >= 0.12 * shaftLength && l <= 0.8 * shaftLength && part.allSatisfy { InkMath.distance($0, tip) <= 0.45 * shaftLength }
        }
        let headEnd = after.count >= 3 && isHeadPart(after, tip: v[shaft + 1])
        let headStart = before.count >= 3 && isHeadPart(before, tip: v[shaft])
        guard headEnd || headStart else { return nil }
        // Anything left over that isn't a head means this was something else (a zig-zag, a letter).
        if !headEnd && InkMath.length(after) > 0.15 * shaftLength { return nil }
        if !headStart && InkMath.length(before) > 0.15 * shaftLength { return nil }
        return (v[shaft], v[shaft + 1], headStart, headEnd)
    }

    /// A short "V" or tick drawn separately at a shaft's end: small, touching the tip, and folded back along the shaft.
    static func isHead(_ s: InkStroke, at tip: Point, toward tail: Point, shaftLength: Double) -> Bool {
        let r = s.bounds
        let diag = hypot(r.size.width, r.size.height)
        let reach = max(28, min(0.2 * shaftLength, 60))
        guard diag >= 6, s.points.allSatisfy({ InkMath.distance($0, tip) <= reach }) else { return false }
        let near = s.points.map { InkMath.distance($0, tip) }.min() ?? .infinity
        guard near <= 12 + 0.04 * shaftLength else { return false }
        let ux = (tail.x - tip.x) / max(shaftLength, 1), uy = (tail.y - tip.y) / max(shaftLength, 1)
        let back = s.points.map { ($0.x - tip.x) * ux + ($0.y - tip.y) * uy }
        let dist = s.points.map { InkMath.distance($0, tip) }
        return back.reduce(0, +) > 0.3 * dist.reduce(0, +)
    }

    // MARK: Text

    static func clusterText(_ strokes: [InkStroke]) -> [[InkStroke]] {
        guard !strokes.isEmpty else { return [] }
        let heights = strokes.map { max($0.bounds.size.height, 6) }.sorted()
        let h = max(heights[heights.count / 2], 10)
        let boxes = strokes.map { s -> Rect in
            let b = s.bounds
            return Rect(x: b.minX - 0.7 * h, y: b.minY - 0.3 * h, width: b.size.width + 1.4 * h, height: b.size.height + 0.6 * h)
        }
        var parent = Array(strokes.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in strokes.indices { for j in strokes.indices where j > i && boxes[i].intersects(boxes[j]) { parent[find(i)] = find(j) } }
        var groups: [Int: [InkStroke]] = [:]
        var order: [Int] = []
        for i in strokes.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(strokes[i])
        }
        return order.map { groups[$0]! }
    }
}

enum InkMath {
    static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func length(_ p: [Point]) -> Double {
        zip(p, p.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    static func bounds(_ p: [Point]) -> Rect {
        guard let f = p.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var x0 = f.x, y0 = f.y, x1 = f.x, y1 = f.y
        for q in p { x0 = min(x0, q.x); y0 = min(y0, q.y); x1 = max(x1, q.x); y1 = max(y1, q.y) }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Ramer–Douglas–Peucker.
    static func simplify(_ p: [Point], epsilon: Double) -> [Point] {
        guard p.count > 2 else { return p }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true; keep[p.count - 1] = true
        var stack = [(0, p.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var best = a, bestD = 0.0
            for i in (a + 1)..<b {
                let d = DiagramGeometry.distance(from: p[i], toPolyline: [p[a], p[b]]).distance
                if d > bestD { bestD = d; best = i }
            }
            if bestD > epsilon { keep[best] = true; stack.append((a, best)); stack.append((best, b)) }
        }
        return p.indices.filter { keep[$0] }.map { p[$0] }
    }

    /// Andrew's monotone chain.
    static func convexHull(_ points: [Point]) -> [Point] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Point] = [], upper: [Point] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func area(_ polygon: [Point]) -> Double {
        guard polygon.count > 2 else { return 0 }
        var s = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }
}
