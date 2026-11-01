#if DEBUG
import AppKit
import DrawerCore
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    /// Demo recording: simulate a spoken command (object: the text).
    static let drawerDebugVoice = Notification.Name("DrawerDebugVoice")
}

/// Debug aid: `Drawer --record-demo DIR` plays a scripted tour of the Mac app and records it.
/// Frames are captured from the app's own windows (so no screen-recording permission and no real cursor),
/// with a drawn cursor and click ripples. Each scene lasts at least as long as its narration in
/// DIR/audio/durations.json; DIR/frames.txt and DIR/scenes.txt give frame times and scene starts.
@MainActor
final class MacDemo {
    static var shared: MacDemo?
    let dir: URL
    var durations: [String: Double] = [:]
    var window: NSWindow!
    var canvas: CanvasNSView!
    var doc: DrawerDocument { canvas.document! }

    // Recording
    var frame = 0
    var cursor = CGPoint(x: 800, y: 500)           // window coordinates (bottom-left origin)
    var cursorShape = NSCursor.arrow
    var ripples: [(CGPoint, Date)] = []
    var timer: Timer?
    let encodeQueue = DispatchQueue(label: "demo.encode")
    var frameLog = ""
    var sceneLog = ""
    var sceneStart = Date()
    var currentScene: String?
    var attempts = 0

    init(dir: String) { self.dir = URL(fileURLWithPath: dir) }

    static func start(dir: String) {
        let demo = MacDemo(dir: dir)
        shared = demo
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await demo.run() } }
    }

    // MARK: Capture

    func startRecording() {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let t = Timer(timeInterval: 1.0 / 12, repeats: true) { _ in MainActor.assumeIsolated { MacDemo.shared?.capture() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func capture() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        let size = window.frame.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        // The document window, then anything floating over it (popovers, completion lists, alerts), back to front.
        let windows = NSApp.orderedWindows.reversed().filter { $0 === window || ($0.isVisible && $0.frame.intersects(window.frame) && $0.level >= window.level) }
        for win in windows {
            guard let view = win.contentView?.superview ?? win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            let r = CGRect(x: win.frame.minX - window.frame.minX, y: win.frame.minY - window.frame.minY, width: win.frame.width, height: win.frame.height)
            ctx.draw(image, in: r)
        }
        // Click ripples and the cursor.
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.1) > 0.5 }
        for (p, t) in ripples {
            let k = now.timeIntervalSince(t) / 0.5
            let r = 8 + 18 * k
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.35 * (1 - k)).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        let img = cursorShape.image
        var rect = CGRect(origin: .zero, size: img.size)
        if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            let hot = cursorShape.hotSpot
            ctx.draw(cg, in: CGRect(x: cursor.x - hot.x, y: cursor.y - (img.size.height - hot.y), width: img.size.width, height: img.size.height))
        }
        guard let image = ctx.makeImage() else { return }
        let index = frame
        frame += 1
        frameLog += String(format: "%d %.4f\n", index, now.timeIntervalSince1970)
        let url = dir.appendingPathComponent(String(format: "frames/%05d.jpg", index))
        encodeQueue.async {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    // MARK: Scenes

    func scene(_ id: String?) async {
        if let prev = currentScene {
            let remaining = (durations[prev] ?? 3) + 0.8 - Date().timeIntervalSince(sceneStart)
            if remaining > 0 { await pause(remaining) }
        }
        currentScene = id
        sceneStart = Date()
        sceneLog += "\(id ?? "end") \(frame) \(sceneStart.timeIntervalSince1970)\n"
    }

    func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    // MARK: Pointer

    func move(to p: CGPoint, duration: Double = 0.5) async {
        let from = cursor
        let steps = max(Int(duration * 60), 1)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            cursor = CGPoint(x: from.x + (p.x - from.x) * e, y: from.y + (p.y - from.y) * e)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func ripple(_ p: CGPoint) { ripples.append((p, Date())) }

    /// Window point for a diagram point on the canvas.
    func windowPoint(_ p: Point) -> CGPoint {
        canvas.convert(CGPoint(x: p.x * canvas.zoom + canvas.panOffset.x, y: p.y * canvas.zoom + canvas.panOffset.y), to: nil)
    }

    func mouseEvent(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Clicks or drags on the canvas through its own mouse handlers, with the drawn cursor following.
    func canvasDrag(_ points: [Point], stepMs: Int = 14) async {
        guard let first = points.first else { return }
        await move(to: windowPoint(first), duration: 0.45)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, windowPoint(first)))
        for p in points.dropFirst() {
            cursor = windowPoint(p)
            canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, cursor))
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, windowPoint(points.last!)))
    }

    func canvasClick(_ p: Point) async {
        await move(to: windowPoint(p), duration: 0.5)
        ripple(cursor)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, cursor))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, cursor))
    }

    /// Real key events through the window, so completion and field editors behave as with a keyboard.
    /// Driven by a common-mode timer: while the completion list is open AppKit runs a nested event loop in
    /// which awaiting tasks don't resume, but timers in common modes still fire. "⏸" in `text` pauses briefly.
    func type(_ text: String, delayMs: Int = 75) async {
        var queue = Array(text)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var wait = 0
            let t = Timer(timeInterval: Double(delayMs) / 1000, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if wait > 0 { wait -= 1; return }
                    guard !queue.isEmpty else { timer.invalidate(); done.resume(); return }
                    let ch = queue.removeFirst()
                    if ch == "⏸" { wait = 6; return }
                    self.postKey(ch)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func postKey(_ ch: Character) {
        let s = String(ch)
        let code: UInt16 = s == "\n" ? 36 : 0
        let chars = s == "\n" ? "\r" : s
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.postEvent(e, atStart: false)
        }
    }

    func pressReturn() async { await type("\n") }

    // MARK: Finding things

    func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    func frameOf(_ id: String) -> Rect? {
        DiagramGeometry(parsed: doc.parsed, state: doc.state, measure: appMeasurer).frames[id]
    }

    func node(titled title: String) -> String? { doc.parsed.nodes.first { $0.title == title }?.id }

    /// Window rect of a range in the spec editor.
    func specRect(_ range: NSRange, in tv: NSTextView) -> CGRect {
        let screen = tv.firstRect(forCharacterRange: range, actualRange: nil)
        return window.convertFromScreen(screen)
    }

    // MARK: Script

    func run() async {
        guard let win = NSApp.windows.first(where: { find(CanvasNSView.self, in: $0.contentView) != nil }),
              let c = find(CanvasNSView.self, in: win.contentView) else {
            // Launch may show the Open panel instead of a new document; make one.
            attempts += 1
            if attempts == 2 {
                NSApp.windows.filter { $0 is NSOpenPanel }.forEach { $0.close() }
                NSDocumentController.shared.newDocument(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Task { await self.run() } }
            return
        }
        window = win
        canvas = c
        if let data = try? Data(contentsOf: dir.appendingPathComponent("audio/durations.json")),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Double] { durations = d }
        let screen = NSScreen.main!.visibleFrame
        window.setFrame(CGRect(x: screen.midX - 800, y: screen.midY - 500, width: 1600, height: 1000), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(1.5)
        startRecording()
        await pause(0.6)
        let canvasRect = canvas.convert(canvas.bounds, to: nil)
        cursor = CGPoint(x: canvasRect.midX, y: canvasRect.midY - 120)

        // 1. Tour: spec, drawing, inspector.
        await scene("m01_intro")
        await pause(0.8)
        if let tv = find(SpecTextView.self, in: window.contentView) {
            let r = tv.enclosingScrollView!.convert(tv.enclosingScrollView!.bounds, to: nil)
            await move(to: CGPoint(x: r.midX, y: r.midY + 120), duration: 0.8)
        }
        await pause(0.8)
        await move(to: CGPoint(x: canvasRect.midX, y: canvasRect.midY + 160), duration: 0.8)
        await pause(0.8)
        await move(to: CGPoint(x: canvasRect.maxX + 120, y: canvasRect.midY + 200), duration: 0.8)

        // 2. Start from the C4 example.
        await scene("m02_example")
        let card = CGRect(x: canvasRect.midX - 330, y: canvasRect.midY - 235, width: 660, height: 470)
        await move(to: CGPoint(x: card.minX + 70, y: card.minY + 36), duration: 0.6)     // "Start with an example"
        ripple(cursor)
        await pause(0.5)
        await move(to: CGPoint(x: card.minX + 110, y: card.maxY - 200), duration: 0.5)   // C4 tile
        ripple(cursor)
        let example = DiagramStarter.example(.c4, language: .plantUML)!
        doc.start(spec: example.spec, language: example.language)
        await pause(0.4)
        canvas.zoomToFit()
        await pause(0.6)
        canvas.zoomToFit()

        // 3. Select in the drawing → highlighted in the spec; drag → only the layout changes.
        await scene("m03_sync")
        await pause(0.5)
        if let id = node(titled: "Database"), let f = frameOf(id) {
            await canvasClick(f.center)
            await pause(1.8)
            let path = (0...30).map { i in Point(x: f.midX + Double(i) * 6, y: f.midY + Double(i) * 1.5) }
            await canvasDrag(path, stepMs: 25)
        }

        // 4. Type in the spec with completion.
        await scene("m04_type")
        if let tv = find(SpecTextView.self, in: window.contentView) {
            let ns = tv.string as NSString
            let line = ns.range(of: "ContainerDb(db")
            let end = ns.lineRange(for: line).upperBound - 1
            let r = specRect(NSRange(location: end, length: 0), in: tv)
            cursorShape = .iBeam
            await move(to: CGPoint(x: r.midX + 4, y: r.midY), duration: 0.6)
            ripple(cursor)
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: end, length: 0))
            await pause(0.3)
            // "ContainerQ" → the completion list offers ContainerQueue( → Return accepts it. Same for "events".
            await type("\n  ContainerQ⏸\nevents, \"Events\", \"Kafka\")⏸\nRel⏸\napi, ev⏸\n, \"Publishes\")")
            cursorShape = .arrow
            await pause(0.4)
            canvas.zoomToFit()
        }

        // 5. Sketch a box, choose its type, name it, connect it.
        await scene("m05_sketch")
        await move(to: CGPoint(x: window.frame.width / 2 + 40, y: window.frame.height - 26), duration: 0.6)  // Draw tool
        ripple(cursor)
        canvas.onToolChange(.draw)
        await pause(0.4)
        if let api = node(titled: "API Application"), let f = frameOf(api) {
            let b = Rect(x: f.maxX + 140, y: f.minY - 10, width: 200, height: 100)
            func w(_ i: Int) -> Double { sin(Double(i) * 1.3) * 1.4 }
            var pts: [Point] = []
            let corners = [Point(x: b.minX, y: b.minY), Point(x: b.maxX, y: b.minY + 2), Point(x: b.maxX - 2, y: b.maxY), Point(x: b.minX + 1, y: b.maxY - 1), Point(x: b.minX + 3, y: b.minY + 3)]
            for (a, z) in zip(corners, corners.dropFirst()) {
                for k in 0..<18 { let t = Double(k) / 18; pts.append(Point(x: a.x + (z.x - a.x) * t + w(pts.count), y: a.y + (z.y - a.y) * t + w(pts.count + 2))) }
            }
            await canvasDrag(pts, stepMs: 12)
            await pause(1.6)
            // The "What is this?" popover: pick Container.
            if let pop = NSApp.windows.first(where: { $0.isVisible && $0 !== window && String(describing: Swift.type(of: $0)).contains("Popover") }) {
                await move(to: CGPoint(x: pop.frame.minX - window.frame.minX + 90, y: pop.frame.maxY - window.frame.minY - 58), duration: 0.5)
                ripple(cursor)
            }
            await pause(0.3)
            doc.resolveChoice(.container)
            await pause(0.7)
            await type("Payments")
            await pressReturn()
            await pause(0.4)
            // A line from the API to the new box becomes a relationship.
            let f2 = frameOf(api) ?? f
            let target = frameOf(node(titled: "Payments") ?? "") ?? b
            let line = (0...24).map { i -> Point in
                let t = Double(i) / 24
                return Point(x: f2.maxX - 6 + (target.minX + 10 - (f2.maxX - 6)) * t, y: f2.midY + (target.midY - f2.midY) * t + sin(Double(i)) * 0.8)
            }
            await canvasDrag(line, stepMs: 16)
            await pause(1.3)
        }
        canvas.onToolChange(.select)

        // 6. Voice.
        await scene("m06_voice")
        await move(to: CGPoint(x: window.frame.width - 300, y: window.frame.height - 26), duration: 0.6)          // mic
        ripple(cursor)
        NotificationCenter.default.post(name: .drawerDebugVoice, object: "add a database called ledger then connect payments to ledger labelled writes")
        await pause(4.8)
        canvas.zoomToFit()

        // 7. Convert to Mermaid.
        await scene("m07_convert")
        if let tv = find(SpecTextView.self, in: window.contentView) {
            let r = tv.enclosingScrollView!.convert(tv.enclosingScrollView!.bounds, to: nil)
            await move(to: CGPoint(x: r.maxX - 30, y: r.maxY + 18), duration: 0.6)
            ripple(cursor)
            await pause(0.4)
            doc.convert(to: .mermaid)
            await pause(2.5)
            await move(to: CGPoint(x: window.frame.width - 140, y: window.frame.height - 26), duration: 0.7)       // Export
        }

        // 8. Auto layout and out.
        await scene("m08_outro")
        await move(to: CGPoint(x: window.frame.width - 245, y: window.frame.height - 26), duration: 0.5)            // Auto Layout
        ripple(cursor)
        doc.autoLayout()
        await pause(0.3)
        canvas.zoomToFit()
        await move(to: CGPoint(x: canvasRect.midX, y: canvasRect.minY + 60), duration: 1.0)
        await scene(nil)
        await pause(0.5)

        timer?.invalidate()
        try? frameLog.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        try? sceneLog.write(to: dir.appendingPathComponent("scenes.txt"), atomically: true, encoding: .utf8)
        encodeQueue.sync {}
        exit(0)
    }
}
#endif
