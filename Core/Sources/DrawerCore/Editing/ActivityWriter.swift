import Foundation

/// Writes an activity graph back as structured PlantUML: decisions become `if`/`switch`, back edges
/// `while`/`repeat`, fork bars `fork … end fork`, nodes with several outgoing flows `split`. Swimlanes and
/// partitions follow their elements. A flow the syntax can't express jumps through `(1)` connector circles.
struct ActivityWriter {
    let nodes: [DiagramNode]
    let edges: [DiagramEdge]

    private var flow: [DiagramNode] { nodes.filter { !$0.kind.isGroup && $0.kind != .note } }

    /// Body lines (between the preamble and `@enduml`), and the order the elements will be read back in.
    func write() -> (text: String, order: [String]) {
        var targets: [String] = []
        for _ in 0..<4 {
            var emitter = Emission(writer: self, connectorTargets: targets)
            emitter.run()
            if Set(emitter.jumpTargets) == Set(targets) { return (emitter.lines.joined(separator: "\n"), emitter.order) }
            targets = flow.map(\.id).filter { emitter.jumpTargets.contains($0) || targets.contains($0) }
        }
        var emitter = Emission(writer: self, connectorTargets: targets)
        emitter.run()
        return (emitter.lines.joined(separator: "\n"), emitter.order)
    }

    private struct Emission {
        let writer: ActivityWriter
        let connectorTargets: [String]
        var lines: [String] = []
        var order: [String] = []
        var emitted: Set<String> = []
        var jumpTargets: [String] = []
        var depth = 0
        var lane: String?
        var partitions: [(id: String, depth: Int)] = []

        let byID: [String: DiagramNode]
        let outs: [String: [DiagramEdge]]
        let ins: [String: [DiagramEdge]]
        let notes: [String: [DiagramNode]]
        var back: Set<String> = []
        var topo: [String: Int] = [:]
        var loopHandled: Set<String> = []

        init(writer: ActivityWriter, connectorTargets: [String]) {
            self.writer = writer
            self.connectorTargets = connectorTargets
            byID = Dictionary(writer.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let flowIDs = Set(writer.flow.map(\.id))
            let flowEdges = writer.edges.filter { flowIDs.contains($0.from) && flowIDs.contains($0.to) }
            outs = Dictionary(grouping: flowEdges, by: \.from)
            ins = Dictionary(grouping: flowEdges, by: \.to)
            var notes: [String: [DiagramNode]] = [:]
            for e in writer.edges {
                if byID[e.from]?.kind == .note, flowIDs.contains(e.to), let n = byID[e.from] { notes[e.to, default: []].append(n) }
                else if byID[e.to]?.kind == .note, flowIDs.contains(e.from), let n = byID[e.to] { notes[e.from, default: []].append(n) }
            }
            self.notes = notes
            classify()
        }

        /// Entry points: start nodes, then elements nothing flows into, then whatever is left (cycles).
        var entries: [String] {
            let flow = writer.flow
            return flow.filter { $0.kind == .activityStart }.map(\.id)
                + flow.filter { $0.kind != .activityStart && (ins[$0.id] ?? []).isEmpty }.map(\.id)
                + flow.map(\.id)
        }

        /// Finds back edges (DFS from the entries) and a topological order of the rest.
        private mutating func classify() {
            var state: [String: Int] = [:]
            var post: [String] = []
            var back: Set<String> = []
            func dfs(_ v: String) {
                state[v] = 1
                for e in outs[v] ?? [] {
                    switch state[e.to] {
                    case 1?: back.insert(e.id)
                    case nil: dfs(e.to)
                    default: break
                    }
                }
                state[v] = 2
                post.append(v)
            }
            for v in entries where state[v] == nil { dfs(v) }
            self.back = back
            for (i, v) in post.reversed().enumerated() { topo[v] = i }
        }

        func forward(_ v: String) -> [DiagramEdge] { (outs[v] ?? []).filter { !back.contains($0.id) } }

        /// Everything reachable from `v` along forward edges, without passing `stop`.
        func reach(_ v: String, stop: String?) -> Set<String> {
            var seen: Set<String> = []
            var stack = [v]
            while let x = stack.popLast() {
                if x == stop || !seen.insert(x).inserted { continue }
                stack += forward(x).map(\.to)
            }
            return seen
        }

        /// Where branches starting at `targets` meet again (nil when they don't).
        func join(of targets: [String], until: String?) -> String? {
            let sets = targets.map { reach($0, stop: until) }
            let union = sets.reduce(into: Set<String>()) { $0.formUnion($1) }
            for j in union.sorted(by: { (topo[$0] ?? 0) < (topo[$1] ?? 0) }) {
                let containing = sets.filter { $0.contains(j) }
                guard containing.count >= 2 else { continue }
                let after = reach(j, stop: until)
                let ok = sets.allSatisfy { s in s.contains(j) || (s.isDisjoint(with: after) && !(until.map(s.contains) ?? false)) }
                if ok { return j }
            }
            return nil
        }

        mutating func run() {
            let lanes = writer.nodes.filter { $0.kind == .lane }
            if lanes.count > 1 { for l in lanes { lines.append("|\(text(l.title))|"); lane = l.id; order.append(l.id) } }
            for v in entries where !emitted.contains(v) { sequence(from: v, until: nil) }
            closePartitions(atDepth: 0)
            for n in writer.nodes where n.kind.isGroup && !order.contains(n.id) {
                // Empty swimlanes and partitions.
                if n.kind == .lane { lines.append("|\(text(n.title))|") } else { lines.append("partition \"\(text(n.title))\" {"); lines.append("}") }
                order.append(n.id)
            }
            for n in writer.nodes where n.kind == .note && !order.contains(n.id) {
                lines.append(contentsOf: noteLines(n, floating: true))
                order.append(n.id)
            }
            while lines.last == "detach" { lines.removeLast() }
        }

        var indent: String { String(repeating: "  ", count: depth) }
        func text(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\\n") }
        func label(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ")", with: "]") }
        mutating func line(_ s: String) { lines.append(indent + s) }

        func laneOf(_ id: String) -> String? {
            var p = byID[id]?.parent
            while let x = p, let n = byID[x] {
                if n.kind == .lane { return x }
                p = n.parent
            }
            return nil
        }
        func partitionOf(_ id: String) -> String? {
            byID[id]?.parent.flatMap { byID[$0]?.kind == .group ? $0 : nil }
        }

        /// Switches swimlane and partition before an element's statement.
        mutating func enter(_ id: String) {
            let p = partitionOf(id)
            while let top = partitions.last, top.depth == depth, top.id != p {
                partitions.removeLast()
                depth -= 1
                line("}")
            }
            if let l = laneOf(id), l != lane {
                lane = l
                lines.append("|\(text(byID[l]?.title ?? l))|")
                if !order.contains(l) { order.append(l) }
            }
            if let p, !partitions.contains(where: { $0.id == p }) {
                line("partition \"\(text(byID[p]?.title ?? p))\" {")
                if !order.contains(p) { order.append(p) }
                depth += 1
                partitions.append((p, depth))
            }
        }

        mutating func closePartitions(atDepth d: Int) {
            while let top = partitions.last, top.depth > d {
                partitions.removeLast()
                depth -= 1
                line("}")
            }
        }

        mutating func emitNotes(_ id: String) {
            for n in notes[id] ?? [] where !order.contains(n.id) {
                for l in noteLines(n, floating: false) { line(l) }
                order.append(n.id)
            }
        }

        func noteLines(_ n: DiagramNode, floating: Bool) -> [String] {
            var side = (n.technology ?? "right").replacingOccurrences(of: "floating ", with: "")
            if !["left", "right", "top", "bottom"].contains(side) { side = "right" }
            let head = (floating ? "floating note " : "note ") + side
            let body = n.title.split(separator: "\n", omittingEmptySubsequences: false)
            if body.count <= 1 { return [head + ": " + n.title] }
            return [head] + body.map { "  " + $0 } + ["end note"]
        }

        mutating func mark(_ id: String) {
            emitted.insert(id)
            order.append(id)
        }

        /// A flow into an element that was already written: through a connector circle.
        mutating func jump(to id: String) {
            if !jumpTargets.contains(id) { jumpTargets.append(id) }
            let n = (connectorTargets.firstIndex(of: id) ?? connectorTargets.count) + 1
            line("(\(n))")
            line("detach")
        }

        mutating func arrow(_ e: DiagramEdge) {
            let style: String = switch e.line {
            case .dashed: "-[dashed]->"
            case .dotted: "-[dotted]->"
            case .thick: "-[bold]->"
            case .invisible: "-[hidden]->"
            case .solid: "->"
            }
            let l = (e.label ?? "").replacingOccurrences(of: "\n", with: "\\n")
            if !l.isEmpty || e.line != .solid { line(style + (l.isEmpty ? ";" : " \(l);")) }
        }

        /// Writes the flow from `start` until it reaches `until` (the join of the enclosing structure).
        mutating func sequence(from start: String, until: String?) {
            var current: String? = start
            while let c = current {
                if c == until { return }
                if emitted.contains(c) { jump(to: c); return }
                guard let node = byID[c] else { return }
                if let i = connectorTargets.firstIndex(of: c) { enter(c); line("(\(i + 1))") }

                // Loops: a back edge into `c`.
                let backIns = (ins[c] ?? []).filter { back.contains($0.id) }
                if !backIns.isEmpty, !loopHandled.contains(c) {
                    loopHandled.insert(c)
                    if let next = loop(header: c, node: node, backIns: backIns, until: until) { current = next; continue }
                    // Otherwise a plain element; the flow coming back jumps to it through a connector.
                }

                // Back edges stay: the one that closes a `while` reaches `until`, any other jumps.
                let outs = self.outs[c] ?? []
                switch node.kind {
                case .diamond:
                    enter(c)
                    mark(c)
                    current = branch(c, node: node, outs: outs, until: until)
                    continue
                case .forkBar where outs.count > 1:
                    enter(c)
                    mark(c)
                    line("fork")
                    emitNotes(c)
                    let byID = self.byID
                    current = parallel(outs: outs, until: until, again: "fork again", close: { j in byID[j]?.kind == .forkBar ? "end fork" : "end merge" })
                    continue
                default:
                    break
                }
                enter(c)
                mark(c)
                statement(node)
                emitNotes(c)
                switch outs.count {
                case 0:
                    if node.kind != .activityStop && node.kind != .activityEnd { line("detach") }
                    current = nil
                case 1:
                    arrow(outs[0])
                    current = outs[0].to
                default:
                    line("split")
                    current = parallel(outs: outs, until: until, again: "split again", close: { _ in "end split" })
                }
            }
        }

        mutating func statement(_ node: DiagramNode) {
            switch node.kind {
            case .activityStart: line("start")
            case .activityStop: line("stop")
            case .activityEnd: line("end")
            case .forkBar: line("fork"); line("end fork")
            case .circle: line("(\(node.title))")
            default:
                let terminator = node.technology.flatMap { $0.count == 1 && "|<>/]}".contains($0) ? $0 : nil } ?? ";"
                line(":" + node.title.replacingOccurrences(of: ";", with: ",") + terminator)
            }
        }

        /// `if`/`switch` for a decision; returns where the flow continues.
        mutating func branch(_ c: String, node: DiagramNode, outs: [DiagramEdge], until: String?) -> String? {
            let cond = label(node.title)
            emitNotes(c)
            if outs.isEmpty {
                line("if (\(cond)) then")
                line("endif")
                line("detach")
                return nil
            }
            if outs.count == 1 {
                line("if (\(cond)) then" + (outs[0].label.map { " (\(label($0)))" } ?? ""))
                depth += 1
                let d = depth
                sequence(from: outs[0].to, until: until)
                closePartitions(atDepth: d - 1)
                depth = d - 1
                line("endif")
                // The other way out isn't drawn yet; at the top level, keep it from joining the next flow.
                if until == nil { line("detach") }
                return nil
            }
            let j = join(of: outs.map(\.to), until: until)
            func run(_ e: DiagramEdge) {
                depth += 1
                let d = depth
                sequence(from: e.to, until: j ?? until)
                closePartitions(atDepth: d - 1)
                depth = d - 1
            }
            if outs.count == 2 {
                line("if (\(cond)) then" + (outs[0].label.map { " (\(label($0)))" } ?? ""))
                run(outs[0])
                line("else" + (outs[1].label.map { " (\(label($0)))" } ?? ""))
                run(outs[1])
                line("endif")
            } else {
                line("switch (\(cond))")
                for e in outs {
                    line("case (\(label(e.label)))")
                    run(e)
                }
                line("endswitch")
            }
            return j
        }

        /// `fork` / `split` branches; returns where the flow continues.
        mutating func parallel(outs: [DiagramEdge], until: String?, again: String, close: (String) -> String) -> String? {
            let j = join(of: outs.map(\.to), until: until)
            for (i, e) in outs.enumerated() {
                if i > 0 { line(again) }
                depth += 1
                let d = depth
                arrow(e)
                sequence(from: e.to, until: j ?? until)
                closePartitions(atDepth: d - 1)
                depth = d - 1
            }
            guard let j else { line(close("")); return nil }
            let end = close(j)
            line(end)
            if end == "end fork" {
                // The join bar is written by "end fork".
                mark(j)
                emitNotes(j)
                let next = forward(j)
                if next.count == 1 { arrow(next[0]); return next[0].to }
                if next.isEmpty { return nil }
                line("split")
                return parallel(outs: next, until: until, again: "split again", close: { _ in "end split" })
            }
            return j
        }

        /// `while` (the decision is the loop's head) or `repeat` (a decision at the end loops back).
        /// Returns where the flow continues after the loop, or nil when the pattern doesn't fit.
        mutating func loop(header c: String, node: DiagramNode, backIns: [DiagramEdge], until: String?) -> String? {
            let outs = outs[c] ?? []
            // while: the head decides between the body (which comes back) and the exit.
            if node.kind == .diamond, outs.count == 2, backIns.count == 1 {
                let source = backIns[0].from
                let inBody = outs.filter { $0.to == c || $0.to == source || reach($0.to, stop: c).contains(source) }
                if inBody.count == 1, let exit = outs.first(where: { $0.id != inBody[0].id }) {
                    enter(c)
                    mark(c)
                    line("while (\(label(node.title)))" + (inBody[0].label.map { " is (\(label($0)))" } ?? ""))
                    emitNotes(c)
                    depth += 1
                    let d = depth
                    if inBody[0].to != c { sequence(from: inBody[0].to, until: c) }
                    closePartitions(atDepth: d - 1)
                    depth = d - 1
                    line("endwhile" + (exit.label.map { " (\(label($0)))" } ?? ""))
                    return exit.to
                }
            }
            // repeat: a decision at the end goes back (maybe through a "backward" activity) or on.
            for e in backIns {
                var decision = e.from
                var backward: String?
                if byID[decision]?.kind != .diamond, let into = ins[decision], into.count == 1, (self.outs[decision] ?? []).count == 1,
                   byID[into[0].from]?.kind == .diamond {
                    backward = decision
                    decision = into[0].from
                }
                guard let d = byID[decision], d.kind == .diamond else { continue }
                let dOuts = self.outs[decision] ?? []
                guard dOuts.count == 2, let again = dOuts.first(where: { $0.to == (backward ?? c) }),
                      let exit = dOuts.first(where: { $0.id != again.id }) else { continue }
                enter(c)
                line("repeat")
                depth += 1
                let dd = depth
                sequence(from: c, until: decision)
                closePartitions(atDepth: dd - 1)
                depth = dd - 1
                if let backward, let b = byID[backward] {
                    mark(backward)
                    line("backward :" + b.title.replacingOccurrences(of: ";", with: ",") + ";")
                }
                enter(decision)
                mark(decision)
                line("repeat while (\(label(d.title)))" + (again.label.map { " is (\(label($0)))" } ?? "") + (exit.label.map { " not (\(label($0)))" } ?? ""))
                emitNotes(decision)
                return exit.to
            }
            return nil
        }
    }
}
