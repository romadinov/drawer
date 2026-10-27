import Foundation

/// Layered (Sugiyama-style) layout used for first layout of imported specs and the "Auto Layout" command,
/// plus incremental placement for elements that appear while the spec is being edited.
public enum AutoLayout {
    static let rankGap = 90.0
    static let nodeGap = 50.0
    static let groupGap = 40.0
    static let maxPerRow = 6

    /// Lays out every leaf node. Returns positions keyed by node id.
    public static func layout(_ parsed: ParsedDiagram, measure: @escaping TextMeasurer = approximateMeasurer, origin: Point = Point(x: 40, y: 40)) -> [String: NodeLayout] {
        if parsed.family == .sequence { return SequenceGeometry.layout(parsed, measure: measure, origin: origin) }
        let leaves = parsed.nodes.filter { !$0.kind.isGroup }
        guard !leaves.isEmpty else { return [:] }
        let ids = leaves.map(\.id)
        let indexOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let sizes = leaves.map { DiagramGeometry.intrinsicSize($0, measure: measure) }

        // Edge direction for ranking: parents above children for inheritance-style arrows.
        var adjacency = Array(repeating: [Int](), count: ids.count)
        var reverse = Array(repeating: [Int](), count: ids.count)
        for e in parsed.edges {
            guard var a = indexOf[e.from], var b = indexOf[e.to], a != b else { continue }
            if e.endMarker == .triangle && e.startMarker == .none { swap(&a, &b) }
            adjacency[a].append(b)
        }

        // Break cycles with a DFS, dropping back edges.
        var state = Array(repeating: 0, count: ids.count) // 0 new, 1 visiting, 2 done
        var dag = Array(repeating: [Int](), count: ids.count)
        func dfs(_ v: Int) {
            state[v] = 1
            for w in adjacency[v] {
                if state[w] == 1 { continue }
                dag[v].append(w)
                if state[w] == 0 { dfs(w) }
            }
            state[v] = 2
        }
        for v in ids.indices where state[v] == 0 { dfs(v) }
        for v in ids.indices { for w in dag[v] { reverse[w].append(v) } }

        // Longest-path ranking.
        var rank = Array(repeating: -1, count: ids.count)
        func rankOf(_ v: Int) -> Int {
            if rank[v] >= 0 { return rank[v] }
            rank[v] = 0
            rank[v] = (reverse[v].map { rankOf($0) + 1 }.max()) ?? 0
            return rank[v]
        }
        for v in ids.indices { _ = rankOf(v) }

        // Pull sources down next to their first successor so they don't all pile into row 0.
        for v in ids.indices where reverse[v].isEmpty && !dag[v].isEmpty {
            let minChild = dag[v].map { rank[$0] }.min() ?? 1
            rank[v] = max(rank[v], minChild - 1)
        }

        let maxRank = rank.max() ?? 0
        var rows = Array(repeating: [Int](), count: maxRank + 1)
        for v in ids.indices { rows[rank[v]].append(v) }

        // Barycentre ordering sweeps; keep group members together.
        func topGroup(_ v: Int) -> String {
            var p = leaves[v].parent
            var top = p
            while let id = p { top = id; p = parsed.node(id)?.parent }
            return top ?? ""
        }
        let groupOf = ids.indices.map(topGroup)
        var position = Array(repeating: 0.0, count: ids.count)
        for row in rows { for (i, v) in row.enumerated() { position[v] = Double(i) } }
        for sweep in 0..<6 {
            let down = sweep % 2 == 0
            let order = down ? Array(rows.indices) : Array(rows.indices.reversed())
            for r in order {
                var bary: [Int: Double] = [:]
                for v in rows[r] {
                    let neighbours = down ? reverse[v] : dag[v]
                    bary[v] = neighbours.isEmpty ? position[v] : neighbours.map { position[$0] }.reduce(0, +) / Double(neighbours.count)
                }
                var groupBary: [String: Double] = [:]
                for g in Set(rows[r].map { groupOf[$0] }) {
                    let members = rows[r].filter { groupOf[$0] == g }
                    groupBary[g] = members.map { bary[$0]! }.reduce(0, +) / Double(members.count)
                }
                rows[r].sort {
                    let ga = groupBary[groupOf[$0]]!, gb = groupBary[groupOf[$1]]!
                    if groupOf[$0] != groupOf[$1] { return ga != gb ? ga < gb : groupOf[$0] < groupOf[$1] }
                    return bary[$0]! != bary[$1]! ? bary[$0]! < bary[$1]! : $0 < $1
                }
                for (i, v) in rows[r].enumerated() { position[v] = Double(i) }
            }
        }

        // Wrap over-long rows (typically many disconnected nodes).
        var wrapped: [[Int]] = []
        for row in rows {
            if row.count <= maxPerRow || row.contains(where: { !dag[$0].isEmpty || !reverse[$0].isEmpty }) {
                wrapped.append(row)
            } else {
                stride(from: 0, to: row.count, by: maxPerRow).forEach { wrapped.append(Array(row[$0..<min($0 + maxPerRow, row.count)])) }
            }
        }

        // Coordinates.
        let horizontal = parsed.direction.isHorizontal
        func along(_ s: Size) -> Double { horizontal ? s.height : s.width }   // within a rank
        func across(_ s: Size) -> Double { horizontal ? s.width : s.height }  // rank thickness
        // Column bands keep every group's members in one vertical strip, so group frames
        // never swallow outsiders. Ungrouped nodes sharing rows with a group go to a band
        // on its left or right; rows without groups are centred freely.
        var groupRows: [String: ClosedRange<Int>] = [:]
        for (r, row) in wrapped.enumerated() {
            for v in row where !groupOf[v].isEmpty {
                let g = groupOf[v]
                groupRows[g] = groupRows[g].map { min($0.lowerBound, r)...max($0.upperBound, r) } ?? r...r
            }
        }
        var band = Array(repeating: "*", count: ids.count)
        for (r, row) in wrapped.enumerated() {
            let grouped = row.filter { !groupOf[$0].isEmpty }
            let rowHasGroupSpan = groupRows.values.contains { $0.contains(r) }
            let meanGrouped = grouped.isEmpty ? Double(row.count) / 2 : grouped.map { position[$0] }.reduce(0, +) / Double(grouped.count)
            for v in row {
                if !groupOf[v].isEmpty { band[v] = groupOf[v] }
                else if rowHasGroupSpan { band[v] = position[v] < meanGrouped ? "<" : ">" }
            }
        }
        let groupNames = groupRows.keys.sorted { a, b in
            let pa = ids.indices.filter { groupOf[$0] == a }.map { position[$0] }.reduce(0, +) / Double(max(1, ids.indices.filter { groupOf[$0] == a }.count))
            let pb = ids.indices.filter { groupOf[$0] == b }.map { position[$0] }.reduce(0, +) / Double(max(1, ids.indices.filter { groupOf[$0] == b }.count))
            return pa != pb ? pa < pb : a < b
        }
        let bandOrder = ["<"] + groupNames + [">"]
        func extent(_ nodes: [Int]) -> Double {
            nodes.enumerated().reduce(0) { $0 + along(sizes[$1.element]) + ($1.offset > 0 ? nodeGap : 0) }
        }
        var bandWidth: [String: Double] = [:]
        for row in wrapped {
            for b in bandOrder {
                let nodes = row.filter { band[$0] == b }
                if !nodes.isEmpty { bandWidth[b] = max(bandWidth[b] ?? 0, extent(nodes)) }
            }
        }
        var bandStart: [String: Double] = [:]
        var cursor = 0.0
        for b in bandOrder where bandWidth[b] != nil {
            if cursor > 0 { cursor += groupGap * 2 + nodeGap }
            bandStart[b] = cursor
            cursor += bandWidth[b]!
        }
        let banded = cursor
        let widest = max(banded, wrapped.map { extent($0.filter { band[$0] == "*" }) }.max() ?? 0)
        let bandOffset = (widest - banded) / 2

        var result: [String: NodeLayout] = [:]
        var cursorAcross = 0.0
        for (r, row) in wrapped.enumerated() {
            let thickness = row.map { across(sizes[$0]) }.max() ?? 0
            func place(_ nodes: [Int], start: Double, width: Double) {
                var cursorAlong = start + (width - extent(nodes)) / 2
                for v in nodes {
                    let s = sizes[v]
                    let offsetAcross = (thickness - across(s)) / 2
                    let p = horizontal
                        ? Point(x: origin.x + cursorAcross + offsetAcross, y: origin.y + cursorAlong)
                        : Point(x: origin.x + cursorAlong, y: origin.y + cursorAcross + offsetAcross)
                    result[ids[v]] = NodeLayout(position: Point(x: p.x.rounded(), y: p.y.rounded()))
                    cursorAlong += along(s) + nodeGap
                }
            }
            place(row.filter { band[$0] == "*" }, start: 0, width: widest)
            for b in bandOrder {
                guard let start = bandStart[b] else { continue }
                place(row.filter { band[$0] == b }, start: bandOffset + start, width: bandWidth[b]!)
            }
            var gap = rankGap
            if r + 1 < wrapped.count, Set(wrapped[r + 1].map { groupOf[$0] }) != Set(row.map { groupOf[$0] }) { gap += groupGap * 2 }
            cursorAcross += thickness + gap
        }

        // Flip for bottom-up / right-left.
        if parsed.direction == .bottomUp || parsed.direction == .rightLeft {
            let maxAcross = result.values.map { horizontal ? $0.position.x : $0.position.y }.max() ?? 0
            for (k, v) in result {
                var p = v.position
                if horizontal { p.x = origin.x + maxAcross - (p.x - origin.x) } else { p.y = origin.y + maxAcross - (p.y - origin.y) }
                result[k] = NodeLayout(position: p)
            }
        }
        return result
    }

    /// Places nodes that have no layout yet next to related, already placed nodes.
    public static func placeMissing(_ parsed: ParsedDiagram, state: DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> [String: NodeLayout] {
        var layout = state.layout
        let leaves = parsed.nodes.filter { !$0.kind.isGroup }
        let missing = leaves.filter { layout[$0.id] == nil }
        guard !missing.isEmpty else { return layout }
        let placedCount = leaves.count - missing.count
        if placedCount == 0 {
            // Nothing placed yet (new import): lay everything out, keep empty groups' positions.
            for (k, v) in self.layout(parsed, measure: measure) { layout[k] = v }
            return layout
        }

        if parsed.family == .sequence {
            // New participants join on the right.
            var right = leaves.compactMap { n in layout[n.id].map { $0.position.x + DiagramGeometry.intrinsicSize(n, measure: measure).width } }.max() ?? 40
            for node in missing {
                layout[node.id] = NodeLayout(position: Point(x: (right + 60).rounded(), y: SequenceGeometry.top))
                right += 60 + DiagramGeometry.intrinsicSize(node, measure: measure).width
            }
            return layout
        }
        let horizontal = parsed.direction.isHorizontal
        for node in missing {
            var current = state
            current.layout = layout
            let geometry = DiagramGeometry(parsed: parsed, state: current, measure: measure)
            let occupied = parsed.nodes.filter { !$0.kind.isGroup && layout[$0.id] != nil }.compactMap { geometry.frames[$0.id] }
            let size = DiagramGeometry.intrinsicSize(node, measure: measure)

            let preds = parsed.edges.filter { $0.to == node.id && $0.from != node.id }.compactMap { layout[$0.from] != nil ? geometry.frames[$0.from] : nil }
            let succs = parsed.edges.filter { $0.from == node.id && $0.to != node.id }.compactMap { layout[$0.to] != nil ? geometry.frames[$0.to] : nil }
            let siblings = node.parent.map { p in parsed.children(of: p).filter { $0.id != node.id && layout[$0.id] != nil }.compactMap { geometry.frames[$0.id] } } ?? []

            var candidate: Point
            if !preds.isEmpty {
                let cx = preds.map(\.midX).reduce(0, +) / Double(preds.count)
                let cy = preds.map(\.midY).reduce(0, +) / Double(preds.count)
                candidate = horizontal
                    ? Point(x: (preds.map(\.maxX).max() ?? 0) + rankGap, y: cy - size.height / 2)
                    : Point(x: cx - size.width / 2, y: (preds.map(\.maxY).max() ?? 0) + rankGap)
            } else if !succs.isEmpty {
                let cx = succs.map(\.midX).reduce(0, +) / Double(succs.count)
                let cy = succs.map(\.midY).reduce(0, +) / Double(succs.count)
                candidate = horizontal
                    ? Point(x: (succs.map(\.minX).min() ?? 0) - rankGap - size.width, y: cy - size.height / 2)
                    : Point(x: cx - size.width / 2, y: (succs.map(\.minY).min() ?? 0) - rankGap - size.height)
            } else if let last = siblings.max(by: { $0.maxX < $1.maxX }) {
                candidate = Point(x: last.maxX + nodeGap, y: last.minY)
            } else if let group = node.parent.flatMap({ geometry.frames[$0] }) {
                candidate = Point(x: group.minX + Metrics.groupPadding, y: group.minY + Metrics.groupPadding + Metrics.groupHeader)
            } else {
                let all = occupied.dropFirst().reduce(occupied.first ?? Rect(x: 40, y: 40, width: 0, height: 0)) { $0.union($1) }
                candidate = Point(x: all.minX, y: all.maxY + rankGap)
            }
            candidate = freeSpot(near: candidate, size: size, occupied: occupied, horizontal: horizontal)
            layout[node.id] = NodeLayout(position: Point(x: candidate.x.rounded(), y: candidate.y.rounded()))
        }
        return layout
    }

    static func freeSpot(near p: Point, size: Size, occupied: [Rect], horizontal: Bool) -> Point {
        var candidate = p
        for _ in 0..<200 {
            let r = Rect(x: candidate.x - 15, y: candidate.y - 15, width: size.width + 30, height: size.height + 30)
            guard let hit = occupied.first(where: { $0.intersects(r) }) else { return candidate }
            if horizontal { candidate.y = hit.maxY + nodeGap } else { candidate.x = hit.maxX + nodeGap }
        }
        return candidate
    }

    /// Adds bend points to edges whose straight line would pass through other nodes.
    public static func routeAroundObstacles(_ parsed: ParsedDiagram, state: DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> [String: EdgeLayout] {
        var edgeLayout = state.edgeLayout
        if parsed.family == .sequence { return edgeLayout }
        let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
        let horizontal = parsed.direction.isHorizontal
        for edge in parsed.edges where edge.from != edge.to {
            let existing = edgeLayout[edge.id] ?? EdgeLayout()
            guard existing.waypoints.isEmpty, existing.routing != .orthogonal,
                  let a = geometry.frames[edge.from], let b = geometry.frames[edge.to] else { continue }
            let obstacles = parsed.nodes.filter { !$0.kind.isGroup && $0.id != edge.from && $0.id != edge.to }
                .compactMap { geometry.frames[$0.id] }
                .filter { segmentHits(a.center, b.center, $0.insetBy(-8)) }
            guard let first = obstacles.first else { continue }
            let box = obstacles.dropFirst().reduce(first) { $0.union($1) }
            var l = existing
            if horizontal {
                let goAbove = (a.midY + b.midY) / 2 <= box.midY
                let y = goAbove ? box.minY - 30 : box.maxY + 30
                l.waypoints = [Point(x: box.minX, y: y), Point(x: box.maxX, y: y)]
            } else {
                let goLeft = (a.midX + b.midX) / 2 < box.midX
                let x = goLeft ? box.minX - 30 : box.maxX + 30
                l.waypoints = [Point(x: x, y: box.minY), Point(x: x, y: box.maxY)]
            }
            edgeLayout[edge.id] = l
        }
        return edgeLayout
    }

    static func segmentHits(_ p: Point, _ q: Point, _ r: Rect) -> Bool {
        let steps = 40
        for i in 1..<steps {
            let t = Double(i) / Double(steps)
            if r.contains(Point(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)) { return true }
        }
        return false
    }
}
