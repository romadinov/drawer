import Foundation

/// Excalidraw drawings in and out: `.excalidraw` files, Excalidraw's clipboard, and PNG/SVG exports with the scene embedded.
///
/// Coming in, an Excalidraw scene is treated like ink that has already been recognised: rectangles, ellipses and diamonds
/// become elements of the diagram (so a sketch pasted into a C4 diagram becomes containers), text inside a shape names it,
/// arrows between shapes become relationships, and freehand lines stay as ink.
/// Going out, the diagram is drawn with Excalidraw elements, labels bound to their shapes and arrows bound to their ends.
/// Files written by Drawer also carry the diagram itself, so they open in Drawer exactly as they were saved.
public enum Excalidraw {
    public static let fileExtension = "excalidraw"
    public static let mimeType = "application/vnd.excalidraw+json"
    static let source = "https://github.com/romadinov/drawer"

    /// The elements of a scene (as Excalidraw JSON objects), plus the Drawer diagram when the file was written by Drawer.
    public struct Scene: @unchecked Sendable {
        public var elements: [[String: Any]]
        public var drawer: DrawingState?
    }

    // MARK: Reading

    /// A scene from a `.excalidraw` file, Excalidraw's clipboard JSON, or a PNG/SVG exported with "Embed scene".
    public static func scene(from data: Data) -> Scene? {
        if data.starts(with: EmbeddedDiagram.pngSignature) {
            let keyword = Array(mimeType.utf8) + [0]
            guard let chunk = EmbeddedDiagram.pngChunks(data).first(where: { $0.type == "tEXt" && $0.data.starts(with: keyword) }) else { return nil }
            return scene(fromJSON: latin1(chunk.data.dropFirst(keyword.count)))
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.contains("<svg") {
            return text.contains("payload-type:\(mimeType)") ? sceneFromSVG(text) : nil
        }
        return scene(fromJSON: text)
    }

    static func scene(fromJSON text: String) -> Scene? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        // PNG and SVG payloads wrap the scene: {"version":"1","encoding":"bstring","compressed":true,"encoded":"…"}.
        if let encoded = object["encoded"] as? String {
            var bytes = Data(encoded.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            if object["compressed"] as? Bool == true { guard let inflated = inflate(bytes) else { return nil }; bytes = inflated }
            return String(data: bytes, encoding: .utf8).flatMap(scene(fromJSON:))
        }
        guard let type = object["type"] as? String, ["excalidraw", "excalidraw/clipboard", "excalidraw-api/clipboard"].contains(type),
              let elements = object["elements"] as? [[String: Any]] else { return nil }
        var drawer: DrawingState?
        if let embedded = object["drawer"], let json = try? JSONSerialization.data(withJSONObject: embedded) {
            drawer = try? JSONDecoder().decode(DrawingState.self, from: json)
        }
        return Scene(elements: elements.filter { $0["isDeleted"] as? Bool != true }, drawer: drawer)
    }

    static func sceneFromSVG(_ svg: String) -> Scene? {
        guard let start = svg.range(of: "<!-- payload-start -->"), let end = svg.range(of: "<!-- payload-end -->", range: start.upperBound..<svg.endIndex),
              let bytes = Data(base64Encoded: svg[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }) else { return nil }
        // Version 2 base64-encodes a byte string (one byte per character); version 1 encoded UTF-8.
        let v1 = svg.range(of: "<!-- payload-version:") == nil || svg.contains("<!-- payload-version:1 -->")
        return scene(fromJSON: v1 ? String(decoding: bytes, as: UTF8.self) : latin1(bytes))
    }

    private static func latin1(_ data: Data) -> String { String(data.map { Character(Unicode.Scalar($0)) }) }

    /// pako.deflate output is zlib-wrapped; Foundation's `.zlib` is raw DEFLATE, so drop the header and checksum.
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 6, data[data.startIndex] & 0x0F == 8 else { return nil }
        return try? (data.dropFirst(2).dropLast(4) as NSData).decompressed(using: .zlib) as Data
    }

    /// A new diagram from a scene (a Mermaid flowchart, which has a shape for everything Excalidraw draws).
    public static func state(from scene: Scene, measure: @escaping TextMeasurer = approximateMeasurer) -> DrawingState {
        if let drawer = scene.drawer { return drawer }
        var state = DrawingState(language: .mermaid, spec: "flowchart TD\n")
        paste(scene, into: &state, measure: measure)
        return state
    }

    /// Adds a scene to a diagram, to the right of what is already there, as elements of that diagram. Returns what was added.
    @discardableResult
    public static func paste(_ scene: Scene, into state: inout DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> Set<ElementRef> {
        if let drawer = scene.drawer { return DiagramClipboard.paste(drawer, into: &state, measure: measure) }
        var (items, shapes, labels, icons, notes) = inkItems(scene.elements)
        guard let first = items.first?.bounds ?? notes.first?.frame else { return [] }
        let source = (items.map(\.bounds) + notes.map(\.frame)).reduce(first) { $0.union($1) }
        let parsed = Engine.reconcile(&state, measure: measure)
        let existing = DiagramGeometry(parsed: parsed, state: state, measure: measure).bounds
        let shift = existing.map { Point(x: $0.maxX + 80 - source.minX, y: $0.minY - source.minY) }
            ?? Point(x: 40 - source.minX, y: 40 - source.minY)
        items = items.map { $0.offset(by: shift) }
        shapes = shapes.map { ($0.rect.offset(by: shift), $0.style) }
        labels = labels.map { ($0.text, $0.rect.offset(by: shift)) }
        icons = icons.map { ($0.rect.offset(by: shift), $0.kind) }
        notes = notes.map { var d = $0; d.frame = d.frame.offset(by: shift); return d }
        state.decorations += notes

        let result = InkCommit.apply(items, to: &state, measure: measure)
        // Arrow labels go on the relationship nearest to them (they'd otherwise name whatever shape they sit in).
        var after = Engine.reconcile(&state, measure: measure)
        for label in labels {
            let geometry = DiagramGeometry(parsed: after, state: state, measure: measure)
            let candidates = result.created.compactMap { ref -> (DiagramEdge, Double)? in
                guard case let .edge(id) = ref, let e = after.edge(id), (e.label ?? "").isEmpty else { return nil }
                return (e, DiagramGeometry.distance(from: label.rect.center, toPolyline: geometry.edgePath(e)).distance)
            }
            guard let nearest = candidates.filter({ $0.1 < 60 }).min(by: { $0.1 < $1.1 }) else { continue }
            Engine.updateEdge(&state, id: nearest.0.id, EdgeEdit(label: .some(label.text)), measure: measure)
            after = Engine.reconcile(&state, measure: measure)
        }
        // A cylinder drawn from parts is a database, a sideways one a queue — if the diagram has one.
        for icon in icons {
            let geometry = DiagramGeometry(parsed: after, state: state, measure: measure)
            let wanted: [NodeKind] = icon.kind == .database ? [.containerDb, .systemDb, .component4Db, .database]
                                                            : [.containerQueue, .systemQueue, .component4Queue, .queue]
            guard let node = after.nodes.first(where: { n in
                      result.created.contains(.node(n.id)) && geometry.frames[n.id].map { icon.rect.contains($0.center) } == true }),
                  let kind = wanted.first(where: NodeKind.alternatives(to: node.kind, family: after.family, language: state.language).contains)
            else { continue }
            Engine.updateNode(&state, id: node.id, NodeEdit(kind: kind), measure: measure)
            after = Engine.reconcile(&state, measure: measure)
        }
        // Keep the colours: each new element takes the style of the smallest shape it sits in.
        let geometry = DiagramGeometry(parsed: after, state: state, measure: measure)
        for case let .node(id) in result.created {
            guard let center = geometry.frames[id]?.center,
                  let shape = shapes.filter({ $0.rect.contains(center) }).min(by: { $0.rect.area < $1.rect.area }),
                  !shape.style.isEmpty else { continue }
            state.styles[id] = shape.style
        }
        return Set(result.created + notes.map { .decoration($0.id) })
    }

    /// Excalidraw elements as recognised ink, the drawn shapes with their colours, the labels bound to arrows,
    /// and icons assembled from several shapes that look like a database or a queue.
    /// Notes written over several lines outside any shape are kept as they are, as text.
    static func inkItems(_ elements: [[String: Any]]) -> (items: [InkItem], shapes: [(rect: Rect, style: ElementStyle)],
                                                       labels: [(text: String, rect: Rect)], icons: [(rect: Rect, kind: NodeKind)],
                                                       notes: [Decoration]) {
        let byID = Dictionary(elements.compactMap { e in (e["id"] as? String).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var items: [InkItem] = []
        var icons: [(Rect, NodeKind)] = []

        // People draw icons — a cylinder, a stick figure, a queue — from several shapes and group them with a label.
        // Each such group is one element: the outermost group of a few shapes with no arrows in it.
        let groups = Dictionary(grouping: elements.filter { ($0["groupIds"] as? [String])?.isEmpty == false }) { ($0["groupIds"] as! [String]).last! }
        var inIcon = Set<String>()
        for (_, members) in groups {
            let parts = members.filter { ["rectangle", "ellipse", "diamond", "line"].contains($0["type"] as? String) }
            let texts = members.filter { $0["type"] as? String == "text" }
            guard parts.count >= 2, parts.count + texts.count == members.count, members.count <= 14, texts.count <= 2,
                  texts.allSatisfy({ $0["containerId"] as? String == nil }) else { continue }
            let bounds = parts.dropFirst().reduce(parts[0].rect) { $0.union($1.rect) }
            let ellipses = parts.filter { $0["type"] as? String == "ellipse" }.map(\.rect)
            let hasRectangle = parts.contains { $0["type"] as? String == "rectangle" }
            let name = texts.sorted { $0.rect.minY < $1.rect.minY }.compactMap { $0["text"] as? String }
                .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let isFigure = !hasRectangle && ellipses.count == 1 && ellipses[0].size.width < 0.7 * bounds.size.width
                && ellipses[0].midY < bounds.minY + 0.4 * bounds.size.height
            if isFigure {
                let strokes = parts.map { p -> InkStroke in
                    p["type"] as? String == "ellipse"
                        ? InkStroke((0...12).map { i in let a = Double(i) / 12 * 2 * .pi, r = p.rect
                            return Point(x: r.midX + cos(a) * r.size.width / 2, y: r.midY + sin(a) * r.size.height / 2) })
                        : InkStroke(p.absolutePoints)
                }
                items.append(.person(bounds, strokes: strokes))
            } else {
                items.append(.shape(.rectangle, bounds))
                // Two ellipses one above the other make a cylinder (a database); side by side, a pipe (a queue).
                let pairs = ellipses.flatMap { a in ellipses.map { (a, $0) } }.filter { $0.0 != $0.1 }
                if pairs.contains(where: { abs($0.midX - $1.midX) < 0.2 * $0.size.width && abs($0.midY - $1.midY) > 0.5 * $0.size.height }) {
                    icons.append((bounds, .database))
                } else if pairs.contains(where: { abs($0.midY - $1.midY) < 0.2 * $0.size.height && abs($0.midX - $1.midX) > 0.5 * $0.size.width }) {
                    icons.append((bounds, .queue))
                }
            }
            // The label usually sits above or below the icon: move it inside, so it names it.
            if !name.isEmpty {
                items.append(.text(name, bounds: Rect(x: bounds.midX - 1, y: isFigure ? bounds.maxY + 4 : bounds.midY - 1, width: 2, height: 2), strokes: []))
            }
            for m in members { if let id = m["id"] as? String { inIcon.insert(id) } }
        }
        var elements = elements.filter { !inIcon.contains($0["id"] as? String ?? "") }
        // A huge rectangle behind everything is a page background, not a group.
        let rects = elements.map { ($0["id"] as? String ?? "", $0.rect) }
        elements.removeAll { e in
            guard e["type"] as? String == "rectangle", e["boundElements"].map({ ($0 as? [Any])?.isEmpty ?? true }) ?? true else { return false }
            let r = e.rect, id = e["id"] as? String ?? ""
            let others = rects.filter { $0.0 != id }.map(\.1)
            guard let first = others.first else { return false }
            let content = others.dropFirst().reduce(first) { $0.union($1) }
            return r.contains(content.origin) && r.contains(Point(x: content.maxX, y: content.maxY)) && r.area > 6 * content.area
        }

        let shapeKinds: [String: InkShapeKind] = ["rectangle": .rectangle, "ellipse": .ellipse, "diamond": .diamond, "frame": .rectangle,
                                                  "magicframe": .rectangle, "stickynote": .rectangle, "embeddable": .rectangle, "iframe": .rectangle]
        let shapeRects = elements.compactMap { e in (e["type"] as? String).flatMap { shapeKinds[$0] }.map { _ in e.rect } }
        var shapes: [(Rect, ElementStyle)] = []
        var labels: [(String, Rect)] = []
        var notes: [Decoration] = []
        let arrowPaths = elements.filter { ["arrow", "line"].contains($0["type"] as? String) }.map(\.absolutePoints).filter { $0.count >= 2 }
        for e in elements {
            let type = e["type"] as? String ?? ""
            let r = e.rect
            if let kind = shapeKinds[type] {
                items.append(.shape(kind, r))
                // The label's colour is the element's text colour (light text on a dark box, say).
                var style = e.style
                let label = (e["boundElements"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }
                    .flatMap { $0["id"] as? String }.flatMap { byID[$0] }
                    ?? elements.first { $0["type"] as? String == "text" && $0["containerId"] as? String == e["id"] as? String }
                style.text = label?.style.stroke
                shapes.append((r, style))
                if let name = e["name"] as? String, !name.isEmpty {
                    items.append(.text(name, bounds: Rect(x: r.minX + 8, y: r.minY + 6, width: Double(name.count) * 8, height: 18), strokes: []))
                }
                continue
            }
            switch type {
            case "text":
                let lines = (e["originalText"] as? String ?? e["text"] as? String ?? "")
                    .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let text = lines.joined(separator: " ")
                guard !text.isEmpty else { continue }
                // Text on its own — not in a shape, not by an arrow it might label — stays text, keeping its lines and size.
                let byArrow = arrowPaths.contains { DiagramGeometry.distance(from: r.center, toPolyline: $0).distance < 40 + r.size.height / 2 }
                if lines.count > 1 || !byArrow, e["containerId"] as? String == nil, !shapeRects.contains(where: { $0.contains(r.center) }) {
                    let raw = (e["text"] as? String ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
                    notes.append(Decoration(kind: .text, frame: r, text: raw, fontSize: (e["fontSize"] as? NSNumber)?.doubleValue ?? 20,
                                            style: ElementStyle(text: e.style.stroke)))
                    continue
                }
                if let container = (e["containerId"] as? String).flatMap({ byID[$0] }), ["arrow", "line"].contains(container["type"] as? String) {
                    labels.append((text, r))
                } else {
                    items.append(.text(text, bounds: r, strokes: []))
                }
            case "arrow", "line":
                let points = e.absolutePoints
                guard let a = points.first, let b = points.last, points.count >= 2 else { continue }
                if e["polygon"] as? Bool == true { items.append(.shape(.rectangle, InkMath.bounds(points))); continue }
                // Aim a bound end at the middle of its shape, unless that shape holds others (then the middle is probably one of them).
                func end(_ p: Point, _ key: String) -> Point {
                    guard let binding = e[key] as? [String: Any], let id = binding["elementId"] as? String, let target = byID[id],
                          (target["type"] as? String).flatMap({ shapeKinds[$0] }) != nil else { return p }
                    let t = target.rect
                    let holdsOthers = shapeRects.contains { $0 != t && $0.area < t.area && t.contains($0.center) }
                    return holdsOthers ? p : t.center
                }
                func head(_ key: String, default value: Bool) -> Bool {
                    guard let v = e[key] else { return value }
                    return !(v is NSNull)
                }
                items.append(.connector(from: end(a, "startBinding"), to: end(b, "endBinding"),
                                        headAtStart: head("startArrowhead", default: false), headAtEnd: head("endArrowhead", default: type == "arrow")))
            case "freedraw":
                let points = e.absolutePoints
                guard points.count > 1 else { continue }
                items.append(.text(nil, bounds: InkMath.bounds(points), strokes: [InkStroke(points)]))
            default:
                continue
            }
        }
        return (items, shapes, labels, icons, notes)
    }

    // MARK: Writing

    /// A `.excalidraw` file of the diagram. It also carries the diagram, so Drawer reopens it exactly.
    public static func file(_ state: DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> Data {
        var object: [String: Any] = [
            "type": "excalidraw", "version": 2, "source": source,
            "elements": elements(state, measure: measure),
            "appState": ["viewBackgroundColor": "#ffffff", "gridSize": NSNull()] as [String: Any],
            "files": [String: Any](),
        ]
        if let drawer = try? JSONSerialization.jsonObject(with: EmbeddedDiagram.json(state)) { object["drawer"] = drawer }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// What Excalidraw puts on the clipboard (as plain text) when copying elements, so it can be pasted into Excalidraw.
    public static func clipboard(_ state: DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> String {
        let object: [String: Any] = ["type": "excalidraw/clipboard", "elements": elements(state, measure: measure)]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func elements(_ state: DrawingState, measure: @escaping TextMeasurer) -> [[String: Any]] {
        var state = state
        let parsed = Engine.reconcile(&state, measure: measure)
        let geometry = DiagramGeometry(parsed: parsed, state: state, measure: measure)
        var b = Builder()

        if let title = parsed.title, !title.isEmpty, let bounds = geometry.bounds {
            b.text(title, x: bounds.minX, y: bounds.minY - 48, fontSize: 24)
        }

        // Groups (outermost first, so they sit behind), then elements.
        func depth(_ n: DiagramNode) -> Int {
            var d = 0, p = n.parent
            while let id = p, d < 50 { d += 1; p = parsed.node(id)?.parent }
            return d
        }
        var shapeIDs: [String: String] = [:]
        for group in parsed.nodes.filter(\.kind.isGroup).sorted(by: { depth($0) < depth($1) }) {
            guard let f = geometry.frames[group.id] else { continue }
            let style = state.styles[group.id] ?? ElementStyle()
            shapeIDs[group.id] = b.shape("rectangle", f, stroke: style.stroke ?? "#868e96", fill: style.fill ?? "transparent",
                                         strokeWidth: style.lineWidth ?? 1, dashed: style.dashed ?? true)
            let caption = group.stereotype.map { "  [\($0)]" } ?? ""
            // Where Drawer draws the caption: at the top of a group, at the bottom of a C4 boundary — clear of the elements inside.
            b.text(group.title + caption, x: f.minX + 10, y: group.kind == .boundary ? f.maxY - 30 : f.minY + 8, fontSize: 16,
                   color: style.text ?? "#495057")
        }
        let frames = geometry.sequence?.headers ?? geometry.frames
        for node in parsed.nodes where !node.kind.isGroup {
            guard let f = frames[node.id] else { continue }
            shapeIDs[node.id] = b.node(node, frame: f, style: state.styles[node.id] ?? ElementStyle())
        }

        if let seq = geometry.sequence {
            b.sequence(seq, parsed: parsed)
        } else {
            for edge in parsed.edges where edge.line != .invisible {
                let path = geometry.edgePath(edge)
                guard path.count >= 2 else { continue }
                let style = state.styles["edge:" + edge.id] ?? ElementStyle()
                let curved = state.edgeLayout[edge.id]?.routing == .curved
                let label = [edge.label, edge.technology.map { "[\($0)]" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                b.arrow(path, edge: edge, style: style, curved: curved,
                        from: shapeIDs[edge.from].map { ($0, frames[edge.from]!) }, to: shapeIDs[edge.to].map { ($0, frames[edge.to]!) },
                        label: label, labelAt: geometry.labelPosition(edge, path: path))
                if let l = edge.fromLabel, !l.isEmpty {
                    let p = DiagramGeometry.pointAlong(path, fraction: 0.12)
                    b.text(l, x: p.x + 6, y: p.y - 22, fontSize: 14)
                }
                if let l = edge.toLabel, !l.isEmpty {
                    let p = DiagramGeometry.pointAlong(path, fraction: 0.88)
                    b.text(l, x: p.x + 6, y: p.y - 22, fontSize: 14)
                }
            }
        }

        for d in state.decorations { b.decoration(d) }
        return b.elements
    }

    /// Default colours for element kinds, as Drawer draws them in the light appearance.
    static func palette(_ kind: NodeKind) -> (fill: String, stroke: String, text: String) {
        switch kind {
        case .person: ("#08427b", "#073b6f", "#ffffff")
        case .personExt: ("#686868", "#4d4d4d", "#ffffff")
        case .system, .systemDb, .systemQueue: ("#1168bd", "#3c7fc0", "#ffffff")
        case .systemExt, .systemDbExt: ("#999999", "#8a8a8a", "#ffffff")
        case .container, .containerDb, .containerQueue: ("#438dd5", "#3c7fc0", "#ffffff")
        case .containerExt, .containerDbExt: ("#b3b3b3", "#a6a6a6", "#ffffff")
        case .component4, .component4Db, .component4Queue: ("#85bbf0", "#78a8d8", "#1e1e1e")
        case .component4Ext: ("#cccccc", "#bfbfbf", "#1e1e1e")
        case .classType, .interfaceType, .abstractClass, .enumType: ("#fffbea", "#a38a3a", "#1e1e1e")
        case .entity: ("#f0f6ff", "#4a78b5", "#1e1e1e")
        case .note: ("#fff6b3", "#c9b458", "#1e1e1e")
        default: ("transparent", "#1e1e1e", "#1e1e1e")
        }
    }

    static func arrowhead(_ marker: EdgeMarker) -> Any {
        switch marker {
        case .none: NSNull()
        case .arrow: "arrow"
        case .filledArrow: "triangle"
        case .triangle: "triangle_outline"
        case .diamond: "diamond_outline"
        case .filledDiamond: "diamond"
        case .circle: "circle_outline"
        case .cross: "bar"
        case .exactlyOne: "cardinality_exactly_one"
        case .zeroOrOne: "cardinality_zero_or_one"
        case .oneOrMany: "cardinality_one_or_many"
        case .zeroOrMany: "cardinality_zero_or_many"
        }
    }

    /// Builds Excalidraw elements, keeping track of which arrows and labels are bound to which shapes.
    struct Builder {
        var elements: [[String: Any]] = []
        private var index: [String: Int] = [:]
        static let fontFamily = 5          // Excalifont, Excalidraw's hand-drawn default
        static let lineHeight = 1.25
        static let charWidth = 0.6         // of the font size, on average (Excalifont is wide)

        private mutating func add(_ e: [String: Any]) {
            index[e["id"] as! String] = elements.count
            elements.append(e)
        }

        private mutating func bind(_ id: String, type: String, to container: String) {
            guard let i = index[container] else { return }
            var bound = elements[i]["boundElements"] as? [[String: Any]] ?? []
            bound.append(["id": id, "type": type])
            elements[i]["boundElements"] = bound
        }

        private func base(_ type: String, _ r: Rect, stroke: String = "#1e1e1e", fill: String = "transparent",
                          strokeWidth: Double = 2, dashed: Bool = false, dotted: Bool = false, rounded: Int? = nil) -> [String: Any] {
            let n = elements.count + 1
            return [
                "id": "drawer-\(n)", "type": type,
                "x": r.minX, "y": r.minY, "width": abs(r.size.width), "height": abs(r.size.height), "angle": 0,
                "strokeColor": stroke, "backgroundColor": fill, "fillStyle": "solid", "strokeWidth": strokeWidth,
                "strokeStyle": dotted ? "dotted" : dashed ? "dashed" : "solid", "roughness": 1, "opacity": 100,
                "groupIds": [String](), "frameId": NSNull(), "roundness": rounded.map { ["type": $0] as Any } ?? NSNull(),
                "seed": (n * 7919) % 2_000_000_000 + 1, "version": 1, "versionNonce": 0, "isDeleted": false,
                "boundElements": [[String: Any]](), "updated": 1, "link": NSNull(), "locked": false,
            ]
        }

        @discardableResult
        mutating func shape(_ type: String, _ r: Rect, stroke: String = "#1e1e1e", fill: String = "transparent",
                            strokeWidth: Double = 2, dashed: Bool = false, rounded: Bool = false) -> String {
            let e = base(type, r, stroke: stroke, fill: fill, strokeWidth: strokeWidth, dashed: dashed,
                         rounded: rounded ? (type == "rectangle" ? 3 : 2) : nil)
            add(e)
            return e["id"] as! String
        }

        /// Free text with its top-left corner at x, y (or centred on x when `centered`).
        mutating func text(_ s: String, x: Double, y: Double, fontSize: Double = 16, color: String = "#1e1e1e", centered: Bool = false) {
            let size = Self.measure(s, fontSize: fontSize)
            var e = base("text", Rect(x: centered ? x - size.width / 2 : x, y: y, width: size.width, height: size.height), stroke: color)
            e.merge(textFields(s, wrapped: s, fontSize: fontSize, align: centered ? "center" : "left", valign: "top", container: nil)) { $1 }
            add(e)
        }

        /// Text bound to a shape or arrow, wrapped to fit and centred on `center`.
        mutating func label(_ s: String, in container: String, center: Point, maxWidth: Double?, fontSize: Double = 16, color: String = "#1e1e1e") {
            let wrapped = maxWidth.map { Self.wrap(s, width: $0, fontSize: fontSize) } ?? s
            let size = Self.measure(wrapped, fontSize: fontSize)
            var e = base("text", Rect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), stroke: color)
            e.merge(textFields(wrapped, original: s, fontSize: fontSize, align: "center", valign: "middle", container: container)) { $1 }
            add(e)
            bind(e["id"] as! String, type: "text", to: container)
        }

        private func textFields(_ text: String, wrapped: String? = nil, original: String? = nil, fontSize: Double,
                                align: String, valign: String, container: String?) -> [String: Any] {
            ["text": wrapped ?? text, "originalText": original ?? text, "fontSize": fontSize, "fontFamily": Self.fontFamily,
             "textAlign": align, "verticalAlign": valign, "containerId": container ?? NSNull() as Any,
             "lineHeight": Self.lineHeight, "autoResize": true]
        }

        static func measure(_ s: String, fontSize: Double) -> Size {
            let lines = s.components(separatedBy: "\n")
            let longest = lines.map(\.count).max() ?? 0
            return Size(width: (Double(longest) * fontSize * charWidth).rounded(.up), height: Double(lines.count) * fontSize * lineHeight)
        }

        static func wrap(_ s: String, width: Double, fontSize: Double) -> String {
            let perLine = max(4, Int(width / (fontSize * charWidth)))
            return s.components(separatedBy: "\n").map { line -> String in
                var out: [String] = [], current = ""
                for word in line.split(separator: " ") {
                    if !current.isEmpty && current.count + 1 + word.count > perLine { out.append(current); current = "" }
                    current += (current.isEmpty ? "" : " ") + word
                }
                out.append(current)
                return out.joined(separator: "\n")
            }.joined(separator: "\n")
        }

        mutating func node(_ node: DiagramNode, frame: Rect, style: ElementStyle) -> String {
            let colors = Excalidraw.palette(node.kind)
            var lines = [DiagramGeometry.stereotypeText(node), node.title].compactMap { $0 }
            if node.kind.isC4 { lines.append(DiagramGeometry.c4CaptionText(node)) }
            if let d = node.description, !d.isEmpty { lines.append(d) }
            if !node.fields.isEmpty { lines.append("") ; lines += node.fields }
            if !node.methods.isEmpty { lines.append(""); lines += node.methods }
            let text = lines.joined(separator: "\n")
            // Excalidraw's hand-drawn font is wider than Drawer's: use a smaller size if that fits, else make the shape taller.
            let width = max(frame.size.width - 16, 40)
            let fontSize = [16.0, 14, 12].first { Self.measure(Self.wrap(text, width: width, fontSize: $0), fontSize: $0).height <= frame.size.height - 12 } ?? 12
            let needed = Self.measure(Self.wrap(text, width: width, fontSize: fontSize), fontSize: fontSize).height + 16
            var f = frame
            if needed > f.size.height { f = Rect(x: f.minX, y: f.midY - needed / 2, width: f.size.width, height: needed) }
            let type: String = switch node.kind {
            case .circle, .usecase, .actor, .seqBoundary, .seqControl, .seqEntity: "ellipse"
            case .diamond: "diamond"
            default: "rectangle"
            }
            let rounded = node.kind.isC4 || [.rounded, .stadium, .database, .queue, .participant, .collections].contains(node.kind)
            let id = shape(type, f, stroke: style.stroke ?? colors.stroke, fill: style.fill ?? colors.fill,
                           strokeWidth: style.lineWidth ?? 2, dashed: style.dashed ?? false, rounded: rounded)
            label(text, in: id, center: f.center, maxWidth: width, fontSize: fontSize, color: style.text ?? colors.text)
            return id
        }

        mutating func arrow(_ path: [Point], edge: DiagramEdge, style: ElementStyle, curved: Bool,
                            from: (id: String, frame: Rect)?, to: (id: String, frame: Rect)?, label text: String, labelAt: Point) {
            let id = line(path, arrow: true, stroke: style.stroke ?? "#1e1e1e", width: edge.line == .thick ? 4 : style.lineWidth ?? 2,
                          dashed: edge.line == .dashed || style.dashed == true, dotted: edge.line == .dotted, curved: curved,
                          start: Excalidraw.arrowhead(edge.startMarker), end: Excalidraw.arrowhead(edge.endMarker))
            let i = index[id]!
            func binding(_ end: (id: String, frame: Rect)?, at p: Point) -> Any {
                guard let end else { return NSNull() }
                let r = end.frame
                let fx = r.size.width > 0 ? min(max((p.x - r.minX) / r.size.width, 0), 1) : 0.5
                let fy = r.size.height > 0 ? min(max((p.y - r.minY) / r.size.height, 0), 1) : 0.5
                bind(id, type: "arrow", to: end.id)
                // `fixedPoint` + `mode` is the current form; `focus` + `gap` is what older versions read.
                return ["elementId": end.id, "fixedPoint": [fx, fy], "mode": "orbit", "focus": 0, "gap": 4] as [String: Any]
            }
            elements[i]["startBinding"] = binding(from, at: path.first!)
            elements[i]["endBinding"] = binding(to, at: path.last!)
            if !text.isEmpty { label(text, in: id, center: labelAt, maxWidth: 200, fontSize: 14, color: style.text ?? "#1e1e1e") }
        }

        @discardableResult
        mutating func line(_ path: [Point], arrow: Bool, stroke: String = "#1e1e1e", width: Double = 2, dashed: Bool = false,
                           dotted: Bool = false, curved: Bool = false, start: Any = NSNull(), end: Any = NSNull()) -> String {
            let o = path[0]
            let bounds = InkMath.bounds(path)
            var e = base(arrow ? "arrow" : "line", Rect(x: o.x, y: o.y, width: bounds.size.width, height: bounds.size.height),
                         stroke: stroke, strokeWidth: width, dashed: dashed, dotted: dotted, rounded: curved ? 2 : nil)
            e["points"] = path.map { [$0.x - o.x, $0.y - o.y] }
            e["startBinding"] = NSNull()
            e["endBinding"] = NSNull()
            e["startArrowhead"] = arrow ? start : NSNull()
            e["endArrowhead"] = arrow ? end : NSNull()
            e["elbowed"] = false
            add(e)
            return e["id"] as! String
        }

        mutating func sequence(_ seq: SequenceGeometry, parsed: ParsedDiagram) {
            for (_, lane) in seq.lifelines.sorted(by: { $0.value.x < $1.value.x }) {
                line([Point(x: lane.x, y: lane.top), Point(x: lane.x, y: lane.bottom)], arrow: false, stroke: "#868e96", width: 1, dashed: true)
            }
            for f in seq.fragments {
                shape("rectangle", f.rect, stroke: "#868e96", strokeWidth: 1)
                text(f.label.isEmpty ? f.kind : "\(f.kind) [\(f.label)]", x: f.rect.minX + 8, y: f.rect.minY + 4, fontSize: 14, color: "#495057")
                for s in f.separators {
                    line([Point(x: f.rect.minX, y: s.y), Point(x: f.rect.maxX, y: s.y)], arrow: false, stroke: "#868e96", width: 1, dashed: true)
                    if !s.label.isEmpty { text("[\(s.label)]", x: f.rect.minX + 8, y: s.y + 4, fontSize: 14, color: "#495057") }
                }
            }
            for a in seq.activations { shape("rectangle", a.rect, fill: "#ffffff", strokeWidth: 1) }
            for (i, edge) in parsed.edges.enumerated() {
                guard let path = seq.messagePaths[i], path.count >= 2 else { continue }
                line(path, arrow: true, dashed: edge.line == .dashed, dotted: edge.line == .dotted,
                     start: Excalidraw.arrowhead(edge.startMarker), end: Excalidraw.arrowhead(edge.endMarker))
                let number = seq.messageNumbers[i].map { "\($0). " } ?? ""
                let text = number + (edge.label ?? "")
                if !text.isEmpty, let p = seq.labelPoints[i] {
                    // Just above the arrow, as Drawer draws it.
                    self.text(text, x: p.x, y: p.y - Self.measure(text, fontSize: 14).height + 2, fontSize: 14, centered: true)
                }
            }
            for n in seq.notes {
                let id = shape("rectangle", n.rect, stroke: "#c9b458", fill: "#fff6b3", strokeWidth: 1)
                label(n.text, in: id, center: n.rect.center, maxWidth: n.rect.size.width - 12, fontSize: 14)
            }
            for d in seq.dividers {
                line([Point(x: seq.left, y: d.y), Point(x: seq.right, y: d.y)], arrow: false, stroke: "#868e96", width: 1)
                if !d.text.isEmpty { text(d.text, x: (seq.left + seq.right) / 2, y: d.y - 22, fontSize: 14, centered: true) }
            }
        }

        mutating func decoration(_ d: Decoration) {
            let stroke = d.style.stroke ?? "#1e1e1e", color = d.style.text ?? "#1e1e1e"
            let r = d.frame
            switch d.kind {
            case .text:
                text(d.text, x: r.minX, y: r.minY, fontSize: d.fontSize, color: color)
            case .rectangle, .roundedRectangle, .note, .ellipse:
                let note = d.kind == .note
                let id = shape(d.kind == .ellipse ? "ellipse" : "rectangle", r, stroke: d.style.stroke ?? (note ? "#c9b458" : "#1e1e1e"),
                               fill: d.style.fill ?? (note ? "#fff6b3" : "transparent"), strokeWidth: d.style.lineWidth ?? (note ? 1 : 2),
                               dashed: d.style.dashed ?? false, rounded: d.kind == .roundedRectangle)
                if !d.text.isEmpty { label(d.text, in: id, center: r.center, maxWidth: r.size.width - 12, fontSize: d.fontSize, color: color) }
            case .line, .arrow:
                let id = line([r.origin, Point(x: r.maxX, y: r.maxY)], arrow: d.kind == .arrow, stroke: stroke, width: d.style.lineWidth ?? 2,
                              dashed: d.style.dashed ?? false, end: "arrow")
                if !d.text.isEmpty { label(d.text, in: id, center: r.center, maxWidth: 200, fontSize: d.fontSize, color: color) }
            case .ink:
                for stroke in d.strokes ?? [] where stroke.count > 1 {
                    let points = stroke.map { Point(x: $0.x + r.minX, y: $0.y + r.minY) }
                    let o = points[0], bounds = InkMath.bounds(points)
                    var e = base("freedraw", Rect(x: o.x, y: o.y, width: bounds.size.width, height: bounds.size.height),
                                 stroke: d.style.stroke ?? "#1e1e1e", strokeWidth: d.style.lineWidth ?? 2)
                    e["points"] = points.map { [$0.x - o.x, $0.y - o.y] }
                    e["pressures"] = [Double]()
                    e["simulatePressure"] = true
                    add(e)
                }
            }
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func number(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }

    /// Bounds, normalised for negative sizes.
    var rect: Rect {
        let x = number("x"), y = number("y"), w = number("width"), h = number("height")
        return Rect(x: Swift.min(x, x + w), y: Swift.min(y, y + h), width: abs(w), height: abs(h))
    }

    var absolutePoints: [Point] {
        let x = number("x"), y = number("y")
        return (self["points"] as? [[Any]] ?? []).compactMap { p in
            guard p.count >= 2, let px = (p[0] as? NSNumber)?.doubleValue, let py = (p[1] as? NSNumber)?.doubleValue else { return nil }
            return Point(x: x + px, y: y + py)
        }
    }

    var style: ElementStyle {
        func color(_ key: String, default value: Set<String>) -> String? {
            guard let c = self[key] as? String, c.hasPrefix("#"), !value.contains(c.lowercased()) else { return nil }
            return c
        }
        var s = ElementStyle(fill: color("backgroundColor", default: []), stroke: color("strokeColor", default: ["#1e1e1e", "#000000", "#000"]))
        if let dash = self["strokeStyle"] as? String, dash != "solid" { s.dashed = true }
        return s
    }
}

private extension Rect {
    var area: Double { size.width * size.height }
    func offset(by d: Point) -> Rect { Rect(x: minX + d.x, y: minY + d.y, width: size.width, height: size.height) }
}

private extension InkItem {
    func offset(by d: Point) -> InkItem {
        func move(_ p: Point) -> Point { Point(x: p.x + d.x, y: p.y + d.y) }
        func move(_ strokes: [InkStroke]) -> [InkStroke] { strokes.map { InkStroke($0.points.map(move)) } }
        return switch self {
        case let .shape(k, r): .shape(k, r.offset(by: d))
        case let .person(r, s): .person(r.offset(by: d), strokes: move(s))
        case let .connector(a, b, hs, he): .connector(from: move(a), to: move(b), headAtStart: hs, headAtEnd: he)
        case let .text(t, r, s): .text(t, bounds: r.offset(by: d), strokes: move(s))
        }
    }
}
