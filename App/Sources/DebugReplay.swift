#if DEBUG
import AppKit
import DrawerCore

/// Debug aid: `Drawer --replay-ink out.json` draws a few shapes into a new class diagram through the canvas's
/// real mouse handlers (no real cursor involved), then writes what was recognised and what ink is still pending.
@MainActor
enum DebugReplay {
    static func start(output: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run(output: output) }
    }

    static func canvas(in view: NSView?) -> CanvasNSView? {
        guard let view else { return nil }
        if let c = view as? CanvasNSView { return c }
        for v in view.subviews { if let c = canvas(in: v) { return c } }
        return nil
    }

    static func run(output: String) {
        guard let canvas = NSApp.windows.lazy.compactMap({ canvas(in: $0.contentView) }).first, let doc = canvas.document else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(output: output) }
            return
        }
        doc.start(spec: DiagramStarter.blankSpec(.classDiagram, language: .plantUML), language: .plantUML)
        canvas.onToolChange(.draw)
        func wobble(_ i: Int) -> Double { sin(Double(i) * 1.3) * 1.5 }
        func poly(_ pts: [(Double, Double)]) -> [Point] {
            var out: [Point] = []
            for (a, b) in zip(pts, pts.dropFirst()) {
                let n = max(Int(hypot(b.0 - a.0, b.1 - a.1) / 5), 1)
                for k in 0..<n { let t = Double(k) / Double(n); out.append(Point(x: a.0 + (b.0 - a.0) * t + wobble(out.count), y: a.1 + (b.1 - a.1) * t + wobble(out.count + 2))) }
            }
            return out + [Point(x: pts.last!.0, y: pts.last!.1)]
        }
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [Point] {
            (0...60).map { i in let t = Double(i) / 60 * 2 * .pi; return Point(x: cx + rx * cos(t) + wobble(i), y: cy + ry * sin(t) + wobble(i + 3)) }
        }
        // (pause before, stroke)
        let script: [(Double, [Point])] = [
            (0.5, poly([(100, 100), (260, 100), (260, 170), (100, 170), (102, 103)])),            // box → Class
            (3.0, poly([(400, 60), (560, 50), (555, 170), (420, 175), (395, 120), (402, 62)])),   // irregular quad
            (2.0, ellipse(200, 340, 140, 70)),                                                   // ellipse…
            (0.3, poly([(150, 330), (160, 345)])),                                               // …with a tick
            (0.3, [Point(x: 200, y: 350)]),                                                      // …and a dot
            (2.0, ellipse(330, 520, 300, 120)),                                                  // big blob
        ]
        var t = 0.0
        for (pause, stroke) in script {
            t += pause
            let start = t
            DispatchQueue.main.asyncAfter(deadline: .now() + start) { canvas.debugStroke(stroke) }
            t += Double(stroke.count) * 0.012 + 0.1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 5) {
            let parsed = doc.parsed
            let report: [String: Any] = [
                "spec": doc.state.spec,
                "nodes": parsed.nodes.map { "\($0.kind.rawValue):\($0.title)" },
                "decorations": doc.state.decorations.map(\.kind.rawValue),
                "pendingInk": canvas.ink.pending.count,
            ]
            try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: URL(fileURLWithPath: output))
            exit(0)
        }
    }
}

extension CanvasNSView {
    /// Feeds one stroke through mouseDown / mouseDragged / mouseUp, spaced like real input.
    func debugStroke(_ points: [Point]) {
        guard let window, let first = points.first else { return }
        func event(_ type: NSEvent.EventType, _ p: Point) -> NSEvent {
            let v = CGPoint(x: p.x * zoom + panOffset.x, y: p.y * zoom + panOffset.y)
            return NSEvent.mouseEvent(with: type, location: convert(v, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        mouseDown(with: event(.leftMouseDown, first))
        for (i, p) in points.dropFirst().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1) * 0.012) { self.mouseDragged(with: event(.leftMouseDragged, p)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(points.count) * 0.012 + 0.02) { self.mouseUp(with: event(.leftMouseUp, points.last!)) }
    }
}
#endif
