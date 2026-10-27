import CoreGraphics
import DrawerCore
import Vision

/// Reads handwritten text items with Vision. Strokes are rendered black-on-white at a size the recogniser likes.
enum HandwritingReader {
    static func read(_ items: [InkItem], hints: [String] = []) async -> [InkItem] {
        var result = items
        for (i, item) in items.enumerated() {
            guard case let .text(nil, bounds, strokes) = item, !strokes.isEmpty else { continue }
            result[i] = .text(await read(strokes, hints: hints), bounds: bounds, strokes: strokes)
        }
        return result
    }

    static func read(_ strokes: [InkStroke], hints: [String] = []) async -> String? {
        guard let image = image(of: strokes) else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = hints
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.3 }.map(\.string)
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func image(of strokes: [InkStroke]) -> CGImage? {
        let points = strokes.flatMap(\.points)
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        // Scale so a line of writing is roughly 80 px tall.
        let scale = min(max(80 / max(maxY - minY, 1), 1), 6)
        let pad = 24.0
        let width = Int((maxX - minX) * scale + 2 * pad), height = Int((maxY - minY) * scale + 2 * pad)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(max(3, 2.2 * scale))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Bitmap contexts are y-up; flip so the writing isn't upside down.
        func map(_ p: Point) -> CGPoint { CGPoint(x: (p.x - minX) * scale + pad, y: Double(height) - ((p.y - minY) * scale + pad)) }
        for s in strokes where !s.points.isEmpty {
            ctx.move(to: map(s.points[0]))
            if s.points.count == 1 { ctx.addLine(to: map(s.points[0]).applying(.init(translationX: 0.5, y: 0))) }
            for p in s.points.dropFirst() { ctx.addLine(to: map(p)) }
        }
        ctx.strokePath()
        return ctx.makeImage()
    }
}

/// Debug-only trace of ink handling (set DRAWER_INK_TRACE to a file path).
func inkTrace(_ s: @autoclosure () -> String) {
    #if DEBUG
    guard let path = ProcessInfo.processInfo.environment["DRAWER_INK_TRACE"] else { return }
    let line = Data((String(format: "%.3f ", Date().timeIntervalSince1970) + s() + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { FileManager.default.createFile(atPath: path, contents: line) }
    #endif
}

/// Collects freehand strokes and, after a short pause, turns them into diagram elements.
/// Each pause hands the strokes drawn so far to recognition as one batch; a slow batch never holds up
/// the next, and handwriting recognition gives up after a few seconds rather than leaving ink stuck.
@MainActor
final class InkSession {
    /// Finished strokes waiting for the pause.
    private(set) var strokes: [InkStroke] = []
    /// Batches being recognised (still drawn until their elements appear).
    private var recognising: [[InkStroke]] = []
    private var current: [Point]?
    private var lastInput = Date()
    private var timer: Timer?
    weak var document: DrawerDocument?
    /// Called whenever the pending ink changes so the canvas can redraw.
    var onChange: () -> Void = {}
    /// Seconds of no drawing before the ink is recognised.
    var delay: TimeInterval = 0.9
    /// Longest wait for handwriting recognition before the writing is kept as ink instead.
    var readTimeout: Double = 4

    /// Pending ink, including the stroke being drawn.
    var pending: [[Point]] { recognising.flatMap { $0.map(\.points) } + strokes.map(\.points) + (current.map { [$0] } ?? []) }
    var isEmpty: Bool { strokes.isEmpty && current == nil && recognising.isEmpty }
    var isDrawing: Bool { current != nil }

    func begin(at p: Point) {
        inkTrace("begin current=\(current != nil) strokes=\(strokes.count)")
        timer?.invalidate()
        // A stroke whose pen-up never arrived is kept, not thrown away.
        if let c = current, c.count > 1 { strokes.append(InkStroke(c)) }
        current = [p]
        lastInput = Date()
        onChange()
        scheduleCommit()   // re-arms while drawing; also recovers a stroke whose pen-up never arrives
    }

    func add(_ p: Point) {
        guard var c = current else { return }
        if let last = c.last, hypot(last.x - p.x, last.y - p.y) < 1.2 { return }
        c.append(p)
        current = c
        lastInput = Date()
        onChange()
    }

    func end() {
        inkTrace("end current=\(current != nil) strokes=\(strokes.count)")
        if let c = current { strokes.append(InkStroke(c)) }
        current = nil
        onChange()
        scheduleCommit()
    }

    private func scheduleCommit() {
        timer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        // Common modes: also fire while a menu, popover or text field is tracking the mouse.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Removes pending strokes that pass within `radius` of `p` (eraser over not-yet-recognised ink).
    func erase(near p: Point, radius: Double) {
        let before = strokes.count
        strokes.removeAll { s in s.points.contains { hypot($0.x - p.x, $0.y - p.y) <= radius } }
        if strokes.count != before { onChange() }
    }

    /// Drops the stroke in progress (e.g. it turned out to be the start of a two-finger pan).
    func abandonStroke() {
        current = nil
        onChange()
        if !strokes.isEmpty { scheduleCommit() }
    }

    func cancel() {
        timer?.invalidate()
        strokes = []
        current = nil
        onChange()
    }

    /// Recognises everything drawn so far.
    func commit() {
        inkTrace("commit current=\(current != nil) strokes=\(strokes.count) doc=\(document != nil)")
        timer?.invalidate()
        guard let document else { return }
        // Still drawing: wait for this stroke to finish too — unless its pen-up was lost (no input for a while).
        if let c = current {
            guard Date().timeIntervalSince(lastInput) > 1.5 else { scheduleCommit(); return }
            if c.count > 1 { strokes.append(InkStroke(c)) }
            current = nil
        }
        guard !strokes.isEmpty else { return }
        let batch = strokes
        strokes = []
        recognising.append(batch)
        let hints = document.parsed.nodes.map(\.title) + document.parsed.edges.compactMap(\.label)
        let timeout = readTimeout
        Task { @MainActor in
            inkTrace("recognising \(batch.count)")
            let shapes = InkRecognizer.recognize(batch)
            let items = await Self.read(shapes, hints: hints, timeout: timeout)
            document.applyInk(items)
            if let i = recognising.firstIndex(of: batch) { recognising.remove(at: i) }
            inkTrace("recognised; pending now \(self.pending.count)")
            onChange()
        }
    }

    /// Handwriting recognition, or the unread items if it takes longer than `timeout` seconds.
    private static func read(_ items: [InkItem], hints: [String], timeout: Double) async -> [InkItem] {
        guard items.contains(where: { if case .text(nil, _, _) = $0 { true } else { false } }) else { return items }
        return await withTaskGroup(of: [InkItem]?.self) { group in
            group.addTask { await HandwritingReader.read(items, hints: hints) }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { inkTrace("handwriting recognition timed out") }
            return first ?? items
        }
    }
}
