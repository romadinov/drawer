import Foundation

/// Computed geometry for a sequence diagram: participant headers sit on one baseline, messages
/// flow downwards in spec order, and the user controls horizontal positions and extra spacing.
public struct SequenceGeometry: Sendable {
    public struct Lifeline: Sendable { public var x: Double; public var top: Double; public var bottom: Double }
    public struct Activation: Sendable { public var participant: String; public var rect: Rect }
    public struct Fragment: Sendable {
        public var kind: String
        public var label: String
        public var rect: Rect
        public var separators: [(y: Double, label: String)]
    }
    public struct Note: Sendable { public var text: String; public var rect: Rect }
    public struct Divider: Sendable { public var text: String; public var y: Double }

    public var lifelines: [String: Lifeline] = [:]
    public var headers: [String: Rect] = [:]
    public var messagePaths: [Int: [Point]] = [:]
    public var labelPoints: [Int: Point] = [:]
    public var messageNumbers: [Int: Int] = [:]
    public var activations: [Activation] = []
    public var fragments: [Fragment] = []
    public var notes: [Note] = []
    public var dividers: [Divider] = []
    public var delays: [Double] = []
    public var left = 0.0
    public var right = 0.0
    public var bottom = 0.0

    static let top = 40.0

    init(parsed: ParsedDiagram, state: DrawingState, measure: TextMeasurer, overrides: [String: Point]) {
        let participants = parsed.nodes.filter { !$0.kind.isGroup }
        var sizes: [String: Size] = [:]
        for p in participants { sizes[p.id] = state.layout[p.id]?.size ?? DiagramGeometry.intrinsicSize(p, measure: measure) }
        let headerHeight = sizes.values.map(\.height).max() ?? 40
        for p in participants {
            let s = sizes[p.id]!
            var x = state.layout[p.id]?.position.x ?? 0
            if let o = overrides[p.id] { x += o.x }
            headers[p.id] = Rect(x: x, y: Self.top + headerHeight - s.height, width: s.width, height: s.height)
        }
        let headerBottom = Self.top + headerHeight
        func lx(_ id: String) -> Double { headers[id]?.midX ?? 0 }
        left = headers.values.map(\.minX).min() ?? 0
        right = headers.values.map(\.maxX).max() ?? 0

        var y = headerBottom + 30
        var active: [String: [Double]] = [:]
        var openFragments: [(kind: String, label: String, startY: Double, participants: Set<String>, separators: [(Double, String)])] = []
        var number = 0
        func touch(_ ids: [String]) {
            for i in openFragments.indices { openFragments[i].participants.formUnion(ids) }
        }
        func endpointX(_ id: String, toward other: Double) -> Double {
            let depth = active[id]?.count ?? 0
            guard depth > 0 else { return lx(id) }
            let half = 5.0 + Double(depth - 1) * 4
            return lx(id) + (other >= lx(id) ? half : -half)
        }
        let events = parsed.sequence?.events ?? []
        for event in events {
            switch event.kind {
            case let .message(i, activate, deactivate):
                guard i < parsed.edges.count else { continue }
                let edge = parsed.edges[i]
                number += 1
                messageNumbers[i] = number
                y += state.edgeLayout[edge.id]?.extraSpacing ?? 0
                let labelText = (parsed.sequence?.autonumber == true ? "\(number) " : "") + (edge.label ?? "")
                let labelSize = measure(labelText.isEmpty ? " " : labelText, .edgeLabel, 240)
                touch([edge.from, edge.to])
                if edge.from == edge.to {
                    y += labelSize.height * 0.3
                    let x = endpointX(edge.from, toward: .infinity)
                    messagePaths[i] = [Point(x: x, y: y), Point(x: x + 40, y: y), Point(x: x + 40, y: y + 22), Point(x: lx(edge.from) + 5, y: y + 22)]
                    labelPoints[i] = Point(x: x + 48 + labelSize.width / 2, y: y + 11)
                    y += 22
                } else {
                    y += labelSize.height + 2
                    let x1 = endpointX(edge.from, toward: lx(edge.to))
                    if activate { active[edge.to, default: []].append(y) }
                    let x2 = endpointX(edge.to, toward: lx(edge.from))
                    messagePaths[i] = [Point(x: x1, y: y), Point(x: x2, y: y)]
                    labelPoints[i] = Point(x: (x1 + x2) / 2, y: y - labelSize.height / 2 - 3)
                }
                if activate && edge.from == edge.to { active[edge.to, default: []].append(y) }
                if deactivate, let start = active[edge.from]?.popLast() {
                    activations.append(Activation(participant: edge.from, rect: activationRect(edge.from, start, y, depth: active[edge.from]?.count ?? 0)))
                }
                y += 24
            case let .note(text, ids, position):
                let size = measure(text.isEmpty ? " " : text, .body, 220)
                let w = size.width + 20, h = size.height + 14
                let xs = ids.map(lx)
                var rect: Rect
                switch position {
                case .over:
                    let minX = xs.min() ?? left, maxX = xs.max() ?? left
                    let width = max(w, maxX - minX + 60)
                    rect = Rect(x: (minX + maxX) / 2 - width / 2, y: y, width: width, height: h)
                case .left:
                    rect = Rect(x: (xs.first ?? left) - 10 - w, y: y, width: w, height: h)
                case .right:
                    rect = Rect(x: (xs.first ?? left) + 10, y: y, width: w, height: h)
                }
                notes.append(Note(text: text, rect: rect))
                touch(ids)
                left = min(left, rect.minX)
                right = max(right, rect.maxX)
                y += h + 14
            case let .divider(text):
                y += 10
                dividers.append(Divider(text: text, y: y))
                y += 26
            case .delay:
                delays.append(y + 6)
                y += 34
            case .spacer:
                y += 30
            case let .fragmentStart(kind, label):
                openFragments.append((kind, label, y, [], []))
                y += 32
            case let .fragmentElse(label):
                if !openFragments.isEmpty { openFragments[openFragments.count - 1].separators.append((y, label)) }
                y += 26
            case .fragmentEnd:
                guard let f = openFragments.popLast() else { continue }
                y += 6
                let depth = Double(openFragments.count)
                let xs = f.participants.isEmpty ? headers.values.map(\.midX) : f.participants.map(lx)
                let margin = max(24, 46 - depth * 10)
                let minX = (xs.min() ?? 0) - margin, maxX = (xs.max() ?? 0) + margin + (f.participants.count == 1 ? 60 : 0)
                fragments.append(Fragment(kind: f.kind, label: f.label, rect: Rect(x: minX, y: f.startY - 4, width: maxX - minX, height: y - f.startY + 4),
                                          separators: f.separators.map { (y: $0.0, label: $0.1) }))
                touch(Array(f.participants))
                left = min(left, minX)
                right = max(right, maxX)
                y += 14
            case let .activate(id):
                active[id, default: []].append(y - 18)
            case let .deactivate(id):
                if let start = active[id]?.popLast() {
                    activations.append(Activation(participant: id, rect: activationRect(id, start, y - 14, depth: active[id]?.count ?? 0)))
                }
            }
        }
        for (id, starts) in active {
            for (d, start) in starts.enumerated() {
                activations.append(Activation(participant: id, rect: activationRect(id, start, y, depth: d)))
            }
        }
        bottom = y + 20
        for p in participants { lifelines[p.id] = Lifeline(x: lx(p.id), top: headerBottom, bottom: bottom) }

        func activationRect(_ id: String, _ start: Double, _ end: Double, depth: Int) -> Rect {
            Rect(x: lx(id) - 5 + Double(depth) * 4, y: start, width: 10, height: max(end - start, 12))
        }
    }

    /// Initial horizontal positions: participants in spec order, spaced to fit message labels.
    static func layout(_ parsed: ParsedDiagram, measure: TextMeasurer, origin: Point) -> [String: NodeLayout] {
        let participants = parsed.nodes.filter { !$0.kind.isGroup }
        var result: [String: NodeLayout] = [:]
        var x = origin.x
        for (i, p) in participants.enumerated() {
            let size = DiagramGeometry.intrinsicSize(p, measure: measure)
            if i > 0 {
                let prev = participants[i - 1]
                let prevSize = DiagramGeometry.intrinsicSize(prev, measure: measure)
                let widest = parsed.edges
                    .filter { Set([$0.from, $0.to]) == Set([prev.id, p.id]) }
                    .map { measure($0.label ?? "", .edgeLabel, 240).width }
                    .max() ?? 0
                let centreGap = max(prevSize.width / 2 + size.width / 2 + 50, widest + 50)
                let prevCentre = (result[prev.id]?.position.x ?? x) + prevSize.width / 2
                x = prevCentre + centreGap - size.width / 2
            }
            result[p.id] = NodeLayout(position: Point(x: x.rounded(), y: top))
        }
        return result
    }
}
