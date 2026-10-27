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

/// Collects freehand strokes and, after a short pause, turns them into diagram elements.
@MainActor
final class InkSession {
    private(set) var strokes: [InkStroke] = []
    private var current: [Point]?
    private var timer: Timer?
    weak var document: DrawerDocument?
    /// Called whenever the pending ink changes so the canvas can redraw.
    var onChange: () -> Void = {}
    /// Seconds of no drawing before the ink is recognised.
    var delay: TimeInterval = 0.9

    /// Pending ink, including the stroke being drawn.
    var pending: [[Point]] { strokes.map(\.points) + (current.map { [$0] } ?? []) }
    var isEmpty: Bool { strokes.isEmpty && current == nil }

    func begin(at p: Point) {
        timer?.invalidate()
        current = [p]
        onChange()
    }

    func add(_ p: Point) {
        guard var c = current else { return }
        if let last = c.last, hypot(last.x - p.x, last.y - p.y) < 1.2 { return }
        c.append(p)
        current = c
        onChange()
    }

    func end() {
        if let c = current { strokes.append(InkStroke(c)) }
        current = nil
        onChange()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
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
        if !strokes.isEmpty { end() }
    }

    func cancel() {
        timer?.invalidate()
        strokes = []
        current = nil
        onChange()
    }

    /// Recognises everything drawn so far.
    func commit() {
        timer?.invalidate()
        guard current == nil, !strokes.isEmpty, let document else { return }
        let batch = strokes
        let hints = document.parsed.nodes.map(\.title) + document.parsed.edges.compactMap(\.label)
        Task { @MainActor in
            let items = await HandwritingReader.read(InkRecognizer.recognize(batch), hints: hints)
            document.applyInk(items)
            // Only drop the strokes that were recognised; more may have been drawn meanwhile.
            if strokes.starts(with: batch) { strokes.removeFirst(batch.count) }
            onChange()
        }
    }
}
