import DrawerCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Draws a diagram into the current flipped (top-left origin) graphics context. Used by the canvas and by export.
struct DiagramRenderer {
    let parsed: ParsedDiagram
    let state: DrawingState
    let geometry: DiagramGeometry
    var selection: Set<ElementRef> = []
    var highlighted: String?

    init(parsed: ParsedDiagram, state: DrawingState, selection: Set<ElementRef> = [], highlighted: String? = nil) {
        self.parsed = parsed
        self.state = state
        geometry = DiagramGeometry(parsed: parsed, state: state, measure: appMeasurer)
        self.selection = selection
        self.highlighted = highlighted
    }

    static func isBackground(_ d: Decoration) -> Bool {
        [.rectangle, .roundedRectangle, .ellipse].contains(d.kind)
    }

    func draw() {
        for d in state.decorations where Self.isBackground(d) { drawDecoration(d) }
        if let seq = geometry.sequence {
            drawSequence(seq)
            for d in state.decorations where !Self.isBackground(d) { drawDecoration(d) }
            return
        }
        // Groups outermost first.
        let groups = parsed.nodes.filter(\.kind.isGroup).sorted { area($0) > area($1) }
        for g in groups { drawGroup(g) }
        for e in parsed.edges { drawEdge(e) }
        for n in parsed.nodes where !n.kind.isGroup { drawNode(n) }
        for d in state.decorations where !Self.isBackground(d) { drawDecoration(d) }
    }

    private func area(_ n: DiagramNode) -> Double {
        geometry.frames[n.id].map { $0.size.width * $0.size.height } ?? 0
    }

    // MARK: Text

    static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.lineBreakMode = .byWordWrapping
        return p
    }

    @discardableResult
    static func drawText(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, alignment: NSTextAlignment = .center, italic: Bool = false) -> CGFloat {
        var f = font
        if italic { f = Fonts.italic(font) }
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: paragraph(alignment)]
        let s = NSAttributedString(string: text, attributes: attrs)
        let bounds = s.boundingRect(with: CGSize(width: rect.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        drawAttributed(s, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, bounds.height)))
        return ceil(bounds.height)
    }

    static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let s = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph(.center)])
        return ceil(s.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    // MARK: Styles

    private func palette(for node: DiagramNode) -> NodePalette {
        var p = NodePalette.for(node.kind)
        if let s = state.styles[node.id] {
            if let c = NSColor(hex: s.fill) { p.fill = c }
            if let c = NSColor(hex: s.stroke) { p.stroke = c }
            if let c = NSColor(hex: s.text) { p.text = c; p.secondaryText = c.withAlphaComponent(0.8) }
        }
        return p
    }

    private func strokeWidth(_ id: String, default d: CGFloat) -> CGFloat {
        state.styles[id]?.lineWidth.map { CGFloat($0) } ?? d
    }

    // MARK: Nodes

    private func drawNode(_ node: DiagramNode) {
        guard let f = geometry.frames[node.id] else { return }
        let r = CGRect(f)
        let p = palette(for: node)
        let selected = selection.contains(.node(node.id))
        let lw = strokeWidth(node.id, default: node.kind.isC4 ? 1 : 1.2)
        let dashed = state.styles[node.id]?.dashed == true

        let path = Self.outline(for: node.kind, in: r)
        if node.kind == .collections {
            let back = NSBezierPath(roundedRect: r.offsetBy(dx: 5, dy: -5), xRadius: 3, yRadius: 3)
            p.fill.useForFill(); back.paintFill()
            p.stroke.useForStroke(); back.lineWidth = lw; back.paintStroke()
        }
        if !node.kind.isIconWithLabel {
            let ctx = SVGSurface.current == nil ? currentGraphicsContext : nil
            ctx?.saveGState()
            ctx?.setShadow(offset: CGSize(width: 0, height: shadowOffsetDown * 1.5), blur: 3, color: NSColor.black.withAlphaComponent(0.12).cgColor)
            p.fill.useForFill()
            path.paintFill()
            ctx?.restoreGState()
            p.stroke.useForStroke()
            path.lineWidth = lw
            if dashed { path.setLineDash([6, 4], count: 2, phase: 0) }
            path.paintStroke()
        }

        switch node.kind {
        case let k where k.isC4: drawC4Content(node, r, p)
        case let k where k.isClassifier || k == .entity: drawClassifierContent(node, r, p, lw: lw)
        case .actor: drawActor(node, r, p)
        case .seqBoundary, .seqControl, .seqEntity: drawSequenceIcon(node, r, p)
        default: drawGenericContent(node, r, p)
        }

        if node.kind.isCylinder { drawCylinderTop(r, p, lw: lw) }
        if node.kind.isQueueShape { drawQueueEnd(r, p, lw: lw) }
        if node.kind == .component { drawComponentIcon(r, p) }
        if node.kind == .node { drawNode3D(r, p, lw: lw) }

        if selected || highlighted == node.id {
            let sel = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
            NodePalette.selection.withAlphaComponent(selected ? 0.9 : 0.5).useForStroke()
            sel.lineWidth = selected ? 2 : 1.5
            sel.paintStroke()
        }
    }

    static func outline(for kind: NodeKind, in r: CGRect) -> NSBezierPath {
        switch kind {
        case .rounded, .container, .containerExt, .component4, .component4Ext, .system, .systemExt, .person, .personExt:
            return NSBezierPath(roundedRect: r, xRadius: kind == .person || kind == .personExt ? 18 : 10, yRadius: kind == .person || kind == .personExt ? 18 : 10)
        case .stadium:
            return NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        case .circle, .usecase:
            return NSBezierPath(ovalIn: r)
        case .diamond:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.midY))
            p.line(to: CGPoint(x: r.midX, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.midY)); p.close()
            return p
        case .hexagon:
            let i = min(18, r.width / 4)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + i, y: r.minY)); p.line(to: CGPoint(x: r.maxX - i, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.midY)); p.line(to: CGPoint(x: r.maxX - i, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + i, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.midY)); p.close()
            return p
        case .parallelogram:
            let i = min(16, r.width / 5)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + i, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - i, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.maxY)); p.close()
            return p
        case let k where k.isCylinder:
            let e = min(10, r.height / 6)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY + e))
            p.line(to: CGPoint(x: r.minX, y: r.maxY - e))
            p.curve(to: CGPoint(x: r.maxX, y: r.maxY - e), controlPoint1: CGPoint(x: r.minX, y: r.maxY + e / 3), controlPoint2: CGPoint(x: r.maxX, y: r.maxY + e / 3))
            p.line(to: CGPoint(x: r.maxX, y: r.minY + e))
            p.curve(to: CGPoint(x: r.minX, y: r.minY + e), controlPoint1: CGPoint(x: r.maxX, y: r.minY - e / 3), controlPoint2: CGPoint(x: r.minX, y: r.minY - e / 3))
            p.close()
            return p
        case let k where k.isQueueShape:
            let e = min(10, r.width / 8)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + e, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - e, y: r.minY))
            p.curve(to: CGPoint(x: r.maxX - e, y: r.maxY), controlPoint1: CGPoint(x: r.maxX + e / 3, y: r.minY), controlPoint2: CGPoint(x: r.maxX + e / 3, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + e, y: r.maxY))
            p.curve(to: CGPoint(x: r.minX + e, y: r.minY), controlPoint1: CGPoint(x: r.minX - e / 3, y: r.maxY), controlPoint2: CGPoint(x: r.minX - e / 3, y: r.minY))
            p.close()
            return p
        case .note, .artifact:
            let c: CGFloat = 12
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.line(to: CGPoint(x: r.maxX - c, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.minY + c)); p.line(to: CGPoint(x: r.maxX, y: r.maxY))
            p.line(to: CGPoint(x: r.minX, y: r.maxY)); p.close()
            p.move(to: CGPoint(x: r.maxX - c, y: r.minY)); p.line(to: CGPoint(x: r.maxX - c, y: r.minY + c)); p.line(to: CGPoint(x: r.maxX, y: r.minY + c))
            return p
        case .folder:
            let p = NSBezierPath()
            let tabW = min(50, r.width * 0.4)
            p.move(to: CGPoint(x: r.minX, y: r.minY + 8)); p.line(to: CGPoint(x: r.minX, y: r.minY))
            p.line(to: CGPoint(x: r.minX + tabW, y: r.minY)); p.line(to: CGPoint(x: r.minX + tabW + 6, y: r.minY + 8))
            p.line(to: CGPoint(x: r.maxX, y: r.minY + 8)); p.line(to: CGPoint(x: r.maxX, y: r.maxY))
            p.line(to: CGPoint(x: r.minX, y: r.maxY)); p.close()
            return p
        case .cloud:
            return NSBezierPath(roundedRect: r, xRadius: r.height / 2.2, yRadius: r.height / 2.2)
        case .actor:
            return NSBezierPath(rect: r)
        case .classType, .interfaceType, .abstractClass, .enumType, .entity:
            return NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        default:
            return NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        }
    }

    private func drawCylinderTop(_ r: CGRect, _ p: NodePalette, lw: CGFloat) {
        let e = min(10, r.height / 6)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: r.minX, y: r.minY + e))
        path.curve(to: CGPoint(x: r.maxX, y: r.minY + e), controlPoint1: CGPoint(x: r.minX, y: r.minY + e + e * 1.33), controlPoint2: CGPoint(x: r.maxX, y: r.minY + e + e * 1.33))
        path.lineWidth = lw
        p.stroke.useForStroke()
        path.paintStroke()
    }

    private func drawQueueEnd(_ r: CGRect, _ p: NodePalette, lw: CGFloat) {
        let e = min(10, r.width / 8)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: r.maxX - e, y: r.minY))
        path.curve(to: CGPoint(x: r.maxX - e, y: r.maxY), controlPoint1: CGPoint(x: r.maxX - e - e * 1.33, y: r.minY), controlPoint2: CGPoint(x: r.maxX - e - e * 1.33, y: r.maxY))
        path.lineWidth = lw
        p.stroke.useForStroke()
        path.paintStroke()
    }

    private func drawComponentIcon(_ r: CGRect, _ p: NodePalette) {
        let x = r.maxX - 20, y = r.minY + 7
        let body = NSBezierPath(rect: CGRect(x: x, y: y, width: 12, height: 14))
        p.stroke.useForStroke()
        body.lineWidth = 1
        body.paintStroke()
        for dy in [3.0, 9.0] {
            let tab = NSBezierPath(rect: CGRect(x: x - 3, y: y + dy, width: 6, height: 3))
            p.fill.useForFill(); tab.paintFill(); tab.paintStroke()
        }
    }

    private func drawNode3D(_ r: CGRect, _ p: NodePalette, lw: CGFloat) {
        let d: CGFloat = 8
        let path = NSBezierPath()
        path.move(to: CGPoint(x: r.minX, y: r.minY)); path.line(to: CGPoint(x: r.minX + d, y: r.minY - d))
        path.line(to: CGPoint(x: r.maxX + d, y: r.minY - d)); path.line(to: CGPoint(x: r.maxX + d, y: r.maxY - d))
        path.line(to: CGPoint(x: r.maxX, y: r.maxY))
        path.move(to: CGPoint(x: r.maxX, y: r.minY)); path.line(to: CGPoint(x: r.maxX + d, y: r.minY - d))
        path.lineWidth = lw
        p.stroke.useForStroke()
        path.paintStroke()
    }

    private func drawGenericContent(_ node: DiagramNode, _ r: CGRect, _ p: NodePalette) {
        var lines: [(String, NSFont, NSColor)] = []
        if let s = node.stereotype, !s.isEmpty { lines.append(("«\(s)»", Fonts.caption, p.secondaryText)) }
        lines.append((node.title, Fonts.title, p.text))
        let inset: CGFloat = node.kind == .diamond ? r.width * 0.18 : (node.kind == .hexagon || node.kind == .parallelogram ? 18 : 10)
        let width = r.width - 2 * inset
        let total = lines.reduce(0) { $0 + Self.textHeight($1.0, font: $1.1, width: width) }
        var y = r.midY - total / 2 + (node.kind.isCylinder ? 5 : 0)
        for (text, font, color) in lines {
            y += Self.drawText(text, font: font, color: color, in: CGRect(x: r.minX + inset, y: y, width: width, height: 0))
        }
    }

    private func drawActor(_ node: DiagramNode, _ r: CGRect, _ p: NodePalette) {
        let cx = r.midX
        let top = r.minY + 4
        p.stroke.useForStroke()
        let head = NSBezierPath(ovalIn: CGRect(x: cx - 8, y: top, width: 16, height: 16))
        head.lineWidth = 1.5
        NodePalette.canvas.useForFill(); head.paintFill(); head.paintStroke()
        let body = NSBezierPath()
        body.move(to: CGPoint(x: cx, y: top + 16)); body.line(to: CGPoint(x: cx, y: top + 36))
        body.move(to: CGPoint(x: cx - 14, y: top + 23)); body.line(to: CGPoint(x: cx + 14, y: top + 23))
        body.move(to: CGPoint(x: cx, y: top + 36)); body.line(to: CGPoint(x: cx - 11, y: top + 52))
        body.move(to: CGPoint(x: cx, y: top + 36)); body.line(to: CGPoint(x: cx + 11, y: top + 52))
        body.lineWidth = 1.5
        body.paintStroke()
        Self.drawText(node.title, font: Fonts.title, color: p.text, in: CGRect(x: r.minX - 20, y: top + 56, width: r.width + 40, height: 0))
    }

    private func drawSequenceIcon(_ node: DiagramNode, _ r: CGRect, _ p: NodePalette) {
        let c = CGPoint(x: r.midX + (node.kind == .seqBoundary ? 6 : 0), y: r.minY + 26)
        let radius: CGFloat = 18
        let circle = NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        circle.lineWidth = 1.5
        NodePalette.for(.participant).fill.useForFill(); circle.paintFill()
        p.stroke.useForStroke(); circle.paintStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 1.5
        switch node.kind {
        case .seqBoundary:
            mark.move(to: CGPoint(x: c.x - radius - 12, y: c.y - radius)); mark.line(to: CGPoint(x: c.x - radius - 12, y: c.y + radius))
            mark.move(to: CGPoint(x: c.x - radius - 12, y: c.y)); mark.line(to: CGPoint(x: c.x - radius, y: c.y))
        case .seqControl:
            mark.move(to: CGPoint(x: c.x + 2, y: c.y - radius - 6)); mark.line(to: CGPoint(x: c.x - 6, y: c.y - radius)); mark.line(to: CGPoint(x: c.x + 2, y: c.y - radius + 6))
        default:
            mark.move(to: CGPoint(x: c.x - radius, y: c.y + radius + 3)); mark.line(to: CGPoint(x: c.x + radius, y: c.y + radius + 3))
        }
        mark.paintStroke()
        Self.drawText(node.title, font: Fonts.title, color: p.text, in: CGRect(x: r.minX - 30, y: r.minY + 52, width: r.width + 60, height: 0))
    }

    // MARK: Sequence

    private func drawSequence(_ seq: SequenceGeometry) {
        // Fragments behind everything.
        for f in seq.fragments {
            let r = CGRect(f.rect)
            let box = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            NSColor.dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.035)).useForFill()
            box.paintFill()
            NodePalette.edge.withAlphaComponent(0.7).useForStroke()
            box.lineWidth = 1
            box.paintStroke()
            let tag = f.kind
            let tagSize = (tag as NSString).size(withAttributes: [.font: Fonts.groupTitle])
            let tagRect = CGRect(x: r.minX, y: r.minY, width: tagSize.width + 18, height: 20)
            let pent = NSBezierPath()
            pent.move(to: CGPoint(x: tagRect.minX, y: tagRect.minY)); pent.line(to: CGPoint(x: tagRect.maxX, y: tagRect.minY))
            pent.line(to: CGPoint(x: tagRect.maxX, y: tagRect.maxY - 6)); pent.line(to: CGPoint(x: tagRect.maxX - 6, y: tagRect.maxY))
            pent.line(to: CGPoint(x: tagRect.minX, y: tagRect.maxY)); pent.close()
            NSColor.dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(white: 0.22, alpha: 1)).useForFill(); pent.paintFill()
            pent.paintStroke()
            Self.drawText(tag, font: Fonts.groupTitle, color: .labelColor, in: tagRect.insetBy(dx: 6, dy: 3), alignment: .left)
            if !f.label.isEmpty {
                Self.drawText("[\(f.label)]", font: Fonts.edgeLabel, color: .secondaryLabelColor,
                              in: CGRect(x: tagRect.maxX + 8, y: r.minY + 4, width: r.width - tagRect.width - 12, height: 0), alignment: .left)
            }
            for sep in f.separators {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: r.minX, y: sep.y)); line.line(to: CGPoint(x: r.maxX, y: sep.y))
                line.setLineDash([5, 3], count: 2, phase: 0)
                line.lineWidth = 1
                line.paintStroke()
                if !sep.label.isEmpty {
                    Self.drawText("[\(sep.label)]", font: Fonts.edgeLabel, color: .secondaryLabelColor,
                                  in: CGRect(x: r.minX + 10, y: sep.y + 3, width: r.width - 20, height: 0), alignment: .left)
                }
            }
        }
        // Lifelines.
        for (id, l) in seq.lifelines {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: l.x, y: l.top)); line.line(to: CGPoint(x: l.x, y: l.bottom))
            line.setLineDash([6, 4], count: 2, phase: 0)
            line.lineWidth = selection.contains(.node(id)) ? 1.6 : 1
            (selection.contains(.node(id)) ? NodePalette.selection : NodePalette.edge.withAlphaComponent(0.6)).useForStroke()
            line.paintStroke()
        }
        for a in seq.activations {
            let r = CGRect(a.rect)
            let path = NSBezierPath(rect: r)
            let palette = parsed.node(a.participant).map(palette(for:)) ?? NodePalette.for(.participant)
            NSColor.dynamic(light: NSColor(white: 0.94, alpha: 1), dark: NSColor(white: 0.25, alpha: 1)).useForFill()
            path.paintFill()
            palette.stroke.useForStroke()
            path.lineWidth = 1
            path.paintStroke()
        }
        for d in seq.dividers {
            let r = CGRect(x: seq.left - 20, y: d.y - 2, width: seq.right - seq.left + 40, height: 4)
            let band = NSBezierPath(rect: r)
            NodePalette.edge.withAlphaComponent(0.25).useForFill(); band.paintFill()
            let size = (d.text as NSString).size(withAttributes: [.font: Fonts.groupTitle])
            let label = CGRect(x: r.midX - size.width / 2 - 10, y: d.y - size.height / 2 - 3, width: size.width + 20, height: size.height + 6)
            let box = NSBezierPath(roundedRect: label, xRadius: 3, yRadius: 3)
            NodePalette.canvas.useForFill(); box.paintFill()
            NodePalette.edge.useForStroke(); box.lineWidth = 1; box.paintStroke()
            Self.drawText(d.text, font: Fonts.groupTitle, color: .labelColor, in: label.insetBy(dx: 10, dy: 3))
        }
        for y in seq.delays {
            Self.drawText("⋮", font: .systemFont(ofSize: 18), color: .secondaryLabelColor, in: CGRect(x: seq.left, y: y - 6, width: seq.right - seq.left, height: 24))
        }
        for e in parsed.edges { drawEdge(e) }
        for n in parsed.nodes where !n.kind.isGroup { drawNode(n) }
        for note in seq.notes {
            let r = CGRect(note.rect)
            let path = Self.outline(for: .note, in: r)
            NSColor(hex: "#FFF6B3")!.useForFill(); path.paintFill()
            NSColor(hex: "#C9B458")!.useForStroke(); path.lineWidth = 1; path.paintStroke()
            Self.drawText(note.text, font: Fonts.body, color: NSColor(white: 0.1, alpha: 1), in: r.insetBy(dx: 10, dy: 7), alignment: .left)
        }
    }

    private func drawC4Content(_ node: DiagramNode, _ r: CGRect, _ p: NodePalette) {
        let pad = CGFloat(Metrics.padding)
        let width = r.width - 2 * pad
        var y = r.minY + pad
        if node.kind == .person || node.kind == .personExt {
            // Head silhouette above the title.
            let d = CGFloat(Metrics.personHead) * 0.55
            let head = NSBezierPath(ovalIn: CGRect(x: r.midX - d / 2, y: y - 2, width: d, height: d))
            p.text.withAlphaComponent(0.9).useForFill()
            head.paintFill()
            y += d + 2
        }
        if node.kind.isCylinder { y += 10 }
        let content: [(String, NSFont, NSColor)] = [
            (node.title, Fonts.title, p.text),
            (DiagramGeometry.c4CaptionText(node), Fonts.caption, p.secondaryText),
        ] + ((node.description?.isEmpty == false) ? [(node.description!, Fonts.body, p.text)] : [])
        let total = content.reduce(0) { $0 + Self.textHeight($1.0, font: $1.1, width: width) } + (content.count > 2 ? 8 : 0) + 4
        y = max(y, r.midY - total / 2 + (node.kind == .person || node.kind == .personExt ? 12 : 0))
        for (i, (text, font, color)) in content.enumerated() {
            if i == 1 { y += 2 }
            if i == 2 { y += 8 }
            y += Self.drawText(text, font: font, color: color, in: CGRect(x: r.minX + pad, y: y, width: width, height: 0))
        }
    }

    private func drawClassifierContent(_ node: DiagramNode, _ r: CGRect, _ p: NodePalette, lw: CGFloat) {
        let pad = CGFloat(Metrics.padding)
        var y = r.minY + pad / 2
        if let s = DiagramGeometry.stereotypeText(node) {
            y += Self.drawText(s, font: Fonts.caption, color: p.secondaryText, in: CGRect(x: r.minX + 4, y: y, width: r.width - 8, height: 0))
        }
        y += Self.drawText(node.title, font: Fonts.title, color: p.text, in: CGRect(x: r.minX + 4, y: y, width: r.width - 8, height: 0),
                           italic: node.kind == .abstractClass)
        y += pad / 2
        // Header band tint
        func separator(_ y: CGFloat) {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: r.minX, y: y)); line.line(to: CGPoint(x: r.maxX, y: y))
            line.lineWidth = lw * 0.8
            p.stroke.useForStroke()
            line.paintStroke()
        }
        separator(y)
        y += CGFloat(Metrics.compartmentGap)
        for field in node.fields {
            Self.drawText(field, font: Fonts.member, color: p.text, in: CGRect(x: r.minX + pad, y: y, width: r.width - 2 * pad, height: 0), alignment: .left)
            y += CGFloat(Metrics.memberLine)
        }
        y += CGFloat(Metrics.compartmentGap)
        if node.kind != .entity {
            separator(y)
            y += CGFloat(Metrics.compartmentGap)
            for method in node.methods {
                Self.drawText(method, font: Fonts.member, color: p.text, in: CGRect(x: r.minX + pad, y: y, width: r.width - 2 * pad, height: 0), alignment: .left)
                y += CGFloat(Metrics.memberLine)
            }
        }
    }

    // MARK: Groups

    private func drawGroup(_ node: DiagramNode) {
        guard let f = geometry.frames[node.id] else { return }
        let r = CGRect(f)
        let p = palette(for: node)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        p.fill.useForFill()
        path.paintFill()
        path.lineWidth = strokeWidth(node.id, default: 1.2)
        path.setLineDash([7, 4], count: 2, phase: 0)
        p.stroke.useForStroke()
        path.paintStroke()
        let selected = selection.contains(.node(node.id))
        if node.kind == .boundary {
            var y = r.maxY - CGFloat(Metrics.groupHeader) - 12
            y += Self.drawText(node.title, font: Fonts.groupTitle, color: p.text, in: CGRect(x: r.minX + 12, y: y, width: r.width - 24, height: 0), alignment: .left)
            let caption = "[\(node.stereotype ?? "Boundary")]"
            Self.drawText(caption, font: Fonts.caption, color: p.secondaryText, in: CGRect(x: r.minX + 12, y: y, width: r.width - 24, height: 0), alignment: .left)
        } else {
            let title = node.stereotype.map { "«\($0)» " } ?? ""
            Self.drawText(title + node.title, font: Fonts.groupTitle, color: p.text,
                          in: CGRect(x: r.minX + 12, y: r.minY + 7, width: r.width - 24, height: 0), alignment: .left)
        }
        if selected || highlighted == node.id {
            let sel = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
            NodePalette.selection.withAlphaComponent(selected ? 0.9 : 0.5).useForStroke()
            sel.lineWidth = 2
            sel.paintStroke()
        }
    }

    // MARK: Edges

    static func markerInset(_ m: EdgeMarker) -> CGFloat {
        switch m {
        case .triangle: 13
        case .diamond, .filledDiamond: 16
        case .filledArrow: 8
        case .circle: 8
        default: 0
        }
    }

    func edgeColor(_ edge: DiagramEdge) -> NSColor {
        NSColor(hex: state.styles["edge:" + edge.id]?.stroke) ?? NodePalette.edge
    }

    private func drawEdge(_ edge: DiagramEdge) {
        let points = geometry.edgePath(edge).map(CGPoint.init)
        guard points.count >= 2, edge.line != .invisible else { return }
        let selected = selection.contains(.edge(edge.id))
        let color = selected ? NodePalette.selection : edgeColor(edge)
        let style = state.styles["edge:" + edge.id]
        let lw: CGFloat = style?.lineWidth.map { CGFloat($0) } ?? (edge.line == .thick ? 2.6 : 1.3)

        // Shorten ends so the line doesn't poke through hollow markers.
        var pts = points
        func shorten(_ tip: Int, _ prev: Int, by d: CGFloat) {
            guard d > 0 else { return }
            let dx = pts[tip].x - pts[prev].x, dy = pts[tip].y - pts[prev].y
            let len = max(hypot(dx, dy), 0.001)
            let k = min(d, len - 1) / len
            pts[tip] = CGPoint(x: pts[tip].x - dx * k, y: pts[tip].y - dy * k)
        }
        shorten(pts.count - 1, pts.count - 2, by: Self.markerInset(edge.endMarker))
        shorten(0, 1, by: Self.markerInset(edge.startMarker))

        let path = NSBezierPath()
        let routing = state.edgeLayout[edge.id]?.routing ?? .straight
        path.move(to: pts[0])
        if routing == .curved && pts.count > 2 {
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                if i == pts.count - 2 { path.curve(to: pts[i + 1], controlPoint1: pts[i], controlPoint2: pts[i]) }
                else { path.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i]) }
            }
        } else {
            for p in pts.dropFirst() { path.line(to: p) }
        }
        path.lineWidth = lw
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        if edge.line == .dashed || style?.dashed == true { path.setLineDash([6, 4], count: 2, phase: 0) }
        if edge.line == .dotted { path.setLineDash([2, 3], count: 2, phase: 0) }
        color.useForStroke()
        path.paintStroke()

        drawMarker(edge.endMarker, tip: points[points.count - 1], from: points[points.count - 2], color: color, lw: lw)
        drawMarker(edge.startMarker, tip: points[0], from: points[1], color: color, lw: lw)

        // Labels
        if let label = labelText(edge) {
            let pos = CGPoint(geometry.labelPosition(edge, path: geometry.edgePath(edge)))
            let rect = Self.labelRect(label, at: pos)
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4)
            NodePalette.canvas.withAlphaComponent(0.92).useForFill()
            bg.paintFill()
            if selected {
                NodePalette.selection.withAlphaComponent(0.6).useForStroke()
                bg.lineWidth = 1
                bg.paintStroke()
            }
            let attributed = Self.labelString(label, edge: edge, color: selected ? NodePalette.selection : NSColor.labelColor)
            Self.drawAttributed(attributed, in: rect)
        }
        if let s = edge.fromLabel, !s.isEmpty { drawEndLabel(s, tip: points[0], toward: points[1]) }
        if let s = edge.toLabel, !s.isEmpty { drawEndLabel(s, tip: points[points.count - 1], toward: points[points.count - 2]) }
    }

    func labelText(_ edge: DiagramEdge) -> String? {
        var parts: [String] = []
        if let seq = geometry.sequence, parsed.sequence?.autonumber == true,
           let i = parsed.edges.firstIndex(where: { $0.id == edge.id }), let n = seq.messageNumbers[i] {
            return "\(n) " + (edge.label ?? "")
        }
        if let l = edge.label, !l.isEmpty { parts.append(l) }
        if let t = edge.technology, !t.isEmpty { parts.append("[\(t)]") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func labelString(_ text: String, edge: DiagramEdge, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: Fonts.edgeLabel, .foregroundColor: color, .paragraphStyle: paragraph(.center)])
        if let t = edge.technology, !t.isEmpty {
            let r = (text as NSString).range(of: "[\(t)]", options: .backwards)
            if r.location != NSNotFound {
                s.addAttributes([.font: Fonts.caption, .foregroundColor: color.withAlphaComponent(0.7)], range: r)
            }
        }
        return s
    }

    static func labelRect(_ text: String, at p: CGPoint) -> CGRect {
        let s = NSAttributedString(string: text, attributes: [.font: Fonts.edgeLabel, .paragraphStyle: paragraph(.center)])
        let b = s.boundingRect(with: CGSize(width: 180, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let w = min(ceil(b.width) + 4, 184)
        return CGRect(x: p.x - w / 2, y: p.y - ceil(b.height) / 2, width: w, height: ceil(b.height))
    }

    private func drawEndLabel(_ text: String, tip: CGPoint, toward: CGPoint) {
        let dx = toward.x - tip.x, dy = toward.y - tip.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let p = CGPoint(x: tip.x + ux * 22 - uy * 12, y: tip.y + uy * 22 + ux * 12)
        let size = (text as NSString).size(withAttributes: [.font: Fonts.caption])
        Self.drawText(text, font: Fonts.caption, color: .secondaryLabelColor,
                      in: CGRect(x: p.x - size.width / 2 - 2, y: p.y - size.height / 2, width: size.width + 4, height: size.height))
    }

    private func drawMarker(_ marker: EdgeMarker, tip: CGPoint, from: CGPoint, color: NSColor, lw: CGFloat) {
        guard marker != .none else { return }
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len          // along the edge, pointing at the tip
        let px = -uy, py = ux                      // perpendicular
        func pt(_ back: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - ux * back + px * side, y: tip.y - uy * back + py * side)
        }
        let path = NSBezierPath()
        path.lineWidth = max(lw, 1.2)
        path.lineJoinStyle = .miter
        color.useForStroke()
        switch marker {
        case .arrow:
            path.move(to: pt(11, -6)); path.line(to: tip); path.line(to: pt(11, 6))
            path.paintStroke()
        case .filledArrow:
            path.move(to: tip); path.line(to: pt(10, -5)); path.line(to: pt(10, 5)); path.close()
            color.useForFill(); path.paintFill(); path.paintStroke()
        case .triangle:
            path.move(to: tip); path.line(to: pt(13, -7.5)); path.line(to: pt(13, 7.5)); path.close()
            NodePalette.canvas.useForFill(); path.paintFill(); path.paintStroke()
        case .diamond, .filledDiamond:
            path.move(to: tip); path.line(to: pt(8, -5.5)); path.line(to: pt(16, 0)); path.line(to: pt(8, 5.5)); path.close()
            (marker == .filledDiamond ? color : NodePalette.canvas).useForFill(); path.paintFill(); path.paintStroke()
        case .circle:
            let c = pt(4, 0)
            let o = NSBezierPath(ovalIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            o.lineWidth = path.lineWidth
            NodePalette.canvas.useForFill(); o.paintFill(); o.paintStroke()
        case .cross:
            path.move(to: pt(2, -5)); path.line(to: pt(10, 5)); path.move(to: pt(2, 5)); path.line(to: pt(10, -5))
            path.paintStroke()
        case .exactlyOne, .zeroOrOne, .oneOrMany, .zeroOrMany:
            let many = marker == .oneOrMany || marker == .zeroOrMany
            let zero = marker == .zeroOrOne || marker == .zeroOrMany
            if many {
                path.move(to: pt(0, -7)); path.line(to: pt(12, 0)); path.line(to: pt(0, 7))
                path.move(to: tip); path.line(to: pt(12, 0))
            }
            let bar1: CGFloat = many ? 15 : 8
            path.move(to: pt(bar1, -7)); path.line(to: pt(bar1, 7))
            if !zero {
                let bar2: CGFloat = many ? 19 : 13
                path.move(to: pt(bar2, -7)); path.line(to: pt(bar2, 7))
            }
            path.paintStroke()
            if zero {
                let c = pt(bar1 + 9, 0)
                let o = NSBezierPath(ovalIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
                o.lineWidth = path.lineWidth
                NodePalette.canvas.useForFill(); o.paintFill(); o.paintStroke()
            }
        case .none: break
        }
    }

    // MARK: Decorations

    func drawDecoration(_ d: Decoration) {
        let r = CGRect(d.frame).standardized
        let selected = selection.contains(.decoration(d.id))
        let stroke = NSColor(hex: d.style.stroke) ?? NodePalette.edge
        let textColor = NSColor(hex: d.style.text) ?? NSColor.labelColor
        let lw = CGFloat(d.style.lineWidth ?? 1.5)
        let font = NSFont.systemFont(ofSize: d.fontSize)
        switch d.kind {
        case .rectangle, .roundedRectangle, .ellipse:
            let path: NSBezierPath = d.kind == .ellipse ? NSBezierPath(ovalIn: r)
                : NSBezierPath(roundedRect: r, xRadius: d.kind == .roundedRectangle ? 14 : 2, yRadius: d.kind == .roundedRectangle ? 14 : 2)
            (NSColor(hex: d.style.fill) ?? NSColor.systemBlue.withAlphaComponent(0.07)).useForFill()
            path.paintFill()
            if d.style.dashed == true { path.setLineDash([7, 4], count: 2, phase: 0) }
            path.lineWidth = lw
            stroke.useForStroke()
            path.paintStroke()
            if !d.text.isEmpty {
                Self.drawText(d.text, font: .systemFont(ofSize: d.fontSize, weight: .semibold), color: textColor,
                              in: CGRect(x: r.minX + 10, y: r.minY + 8, width: r.width - 20, height: 0), alignment: .left)
            }
        case .note:
            let path = Self.outline(for: .note, in: r)
            (NSColor(hex: d.style.fill) ?? NSColor(hex: "#FFF6B3")!).useForFill()
            path.paintFill()
            path.lineWidth = 1
            (NSColor(hex: d.style.stroke) ?? NSColor(hex: "#C9B458")!).useForStroke()
            path.paintStroke()
            Self.drawText(d.text, font: font, color: NSColor(hex: d.style.text) ?? NSColor(white: 0.1, alpha: 1),
                          in: CGRect(x: r.minX + 10, y: r.minY + 10, width: r.width - 26, height: 0), alignment: .left)
        case .text:
            Self.drawText(d.text.isEmpty ? " " : d.text, font: font, color: textColor, in: r.insetBy(dx: 2, dy: 2), alignment: .left)
        case .ink:
            Self.strokeInk(d.strokes ?? [], offset: CGPoint(d.frame.origin), color: stroke, width: CGFloat(d.style.lineWidth ?? 2))
        case .line, .arrow:
            let a = CGPoint(d.frame.origin)
            let b = CGPoint(x: d.frame.origin.x + d.frame.size.width, y: d.frame.origin.y + d.frame.size.height)
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            path.lineWidth = lw
            path.lineCapStyle = .round
            if d.style.dashed == true { path.setLineDash([6, 4], count: 2, phase: 0) }
            stroke.useForStroke()
            path.paintStroke()
            if d.kind == .arrow { drawMarker(.filledArrow, tip: b, from: a, color: stroke, lw: lw) }
            if !d.text.isEmpty {
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 10)
                let size = (d.text as NSString).size(withAttributes: [.font: font])
                Self.drawText(d.text, font: font, color: textColor, in: CGRect(x: mid.x - size.width / 2 - 2, y: mid.y - size.height / 2, width: size.width + 4, height: size.height))
            }
        }
        if selected {
            let sel = NSBezierPath(rect: (d.kind == .line || d.kind == .arrow ? r : r.insetBy(dx: -3, dy: -3)))
            sel.setLineDash([3, 3], count: 2, phase: 0)
            sel.lineWidth = 1
            NodePalette.selection.useForStroke()
            sel.paintStroke()
        }
    }

    /// Freehand strokes (pending ink and ink decorations).
    static func strokeInk(_ strokes: [[Point]], offset: CGPoint = .zero, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: CGPoint(x: first.x + offset.x, y: first.y + offset.y))
            if stroke.count == 1 { path.line(to: CGPoint(x: first.x + offset.x + 0.1, y: first.y + offset.y)) }
            for p in stroke.dropFirst() { path.line(to: CGPoint(x: p.x + offset.x, y: p.y + offset.y)) }
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.useForStroke()
        path.paintStroke()
    }
}
