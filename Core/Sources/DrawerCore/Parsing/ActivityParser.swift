import Foundation

/// Parses PlantUML activity diagrams (the current `start` / `:action;` / `if … endif` syntax) into a graph.
///
/// Activities have no identifiers in PlantUML, so ids come from their text ("Check stock" → `CheckStock`,
/// a second one `CheckStock2`). The flow between statements becomes edges; `if`, `switch`, `while` and
/// `repeat` become decisions, `fork` the bars, swimlanes and partitions groups, notes note elements
/// joined to their activity by a dotted line, and `(1)` connector circles jumps to the matching circle.
struct ActivityParser {
    let lines: [SourceLine]
    let builder = DiagramBuilder()

    /// A dangling end of the flow: the next activity is connected from it.
    private struct End {
        var from: String
        var label: String?
        var labelSpan: SourceSpan?
        var line: EdgeLineStyle = .solid
    }

    private enum Frame {
        case branch(decision: String, ends: [End], hasElse: Bool)
        case choice(decision: String, ends: [End], sawCase: Bool)
        case loop(decision: String, breaks: [End])
        case repeatLoop(first: String?, backward: String?, breaks: [End])
        case fork(bar: String, ends: [End], empty: Bool)
        case split(origin: [End], ends: [End])
    }

    // MARK: Detection

    private static let activityLine = NSRegularExpression(
        #"^\s*(start|stop|end|detach|kill|endif|end\s*if|endwhile|fork|end\s*fork|split|repeat|(if|while|switch)\s*\(.*\)|#[\w#;.]+\s*:.*|\|[^|]+\|(\s*[^|]+\|)?\s*)\s*$"#)
    private static let actionStart = NSRegularExpression(#"^\s*:(?![^:]*:\s*(as\b|[-.<=]|$))"#)

    static func looksLikeActivity(_ lines: [SourceLine]) -> Bool {
        lines.contains { activityLine.firstMatch(in: $0.ns) != nil || actionStart.firstMatch(in: $0.ns) != nil }
    }

    /// Lines before the first activity statement: header, title, skinparams and comments.
    static func bodyRange(of spec: String) -> NSRange {
        let lines = SourceLine.split(spec)
        let ns = spec as NSString
        let end = lines.first { $0.trimmed.hasPrefix("@enduml") }?.offset ?? ns.length
        var start = 0
        var skipping: String?
        var braces = 0
        for line in lines where line.offset < end {
            let t = line.trimmed
            if let s = skipping { if t.lowercased().hasPrefix(s) { skipping = nil }; start = line.offset + line.length; continue }
            if braces > 0 { if t.hasSuffix("{") { braces += 1 }; if t.hasPrefix("}") { braces -= 1 }; start = line.offset + line.length; continue }
            if t.hasPrefix("skinparam") && t.hasSuffix("{") { braces = 1; start = line.offset + line.length; continue }
            if t.hasPrefix("legend") && !t.contains("endlegend") { skipping = "endlegend"; start = line.offset + line.length; continue }
            if t.hasPrefix("/'") && !t.contains("'/") { skipping = "'/"; start = line.offset + line.length; continue }
            let preamble = t.isEmpty || t.hasPrefix("'") || t.hasPrefix("@startuml") || t.hasPrefix("!") || t.hasPrefix("/'")
                || ["title ", "skinparam", "scale ", "header", "footer", "caption ", "hide ", "left to right", "top to bottom", "<style>"]
                    .contains { t.hasPrefix($0) }
            guard preamble else { break }
            start = line.offset + line.length
        }
        // Start after the newline that ends the preamble.
        if start < end, start < ns.length, ns.character(at: start) == 10 { start += 1 }
        return NSRange(location: min(start, end), length: max(end - start, 0))
    }

    // MARK: Parsing

    private static let ifLine = NSRegularExpression(#"^if\s*\((.*)\)\s*(?:is\s*\((.*?)\)\s*)?then(?:\s*\((.*)\))?\s*$"#)
    private static let elseIfLine = NSRegularExpression(#"^(?:\((.*?)\)\s*)?else\s*if\s*\((.*)\)\s*(?:is\s*\((.*?)\)\s*)?then(?:\s*\((.*)\))?\s*$"#)
    private static let elseLine = NSRegularExpression(#"^else(?:\s*\((.*)\))?\s*$"#)
    private static let whileLine = NSRegularExpression(#"^while\s*\((.*?)\)(?:\s*is\s*\((.*)\))?\s*$"#)
    private static let endWhileLine = NSRegularExpression(#"^end\s*while(?:\s*\((.*)\))?\s*$"#)
    private static let repeatWhileLine = NSRegularExpression(#"^repeat\s*while\s*\((.*?)\)(?:\s*is\s*\((.*?)\))?(?:\s*not\s*\((.*?)\))?\s*$"#)
    private static let switchLine = NSRegularExpression(#"^switch\s*\((.*)\)\s*$"#)
    private static let caseLine = NSRegularExpression(#"^case\s*\((.*)\)\s*$"#)
    private static let arrowLine = NSRegularExpression(#"^-(?:\[([^\]]*)\]-)?>\s*(.*?)\s*;?\s*$"#)
    private static let laneLine = NSRegularExpression(#"^\|(?:(#[\w#]+)\|)?([^|]+)\|\s*$"#)
    private static let partitionLine = NSRegularExpression(#"^(?:partition|group)\s+(?:"([^"]+)"|(.+?))\s*(?:#[\w#]+)?\s*\{?\s*$"#)
    private static let noteLine = NSRegularExpression(#"^(floating\s+)?note\s*(left|right|top|bottom)?\s*(?::\s*(.*))?$"#)
    private static let connectorLine = NSRegularExpression(#"^\((\w+)\)$"#)
    private static let terminators: Set<Character> = [";", "|", "<", ">", "/", "]", "}"]

    mutating func parse(insertionOffset: Int, title: String?) -> ParsedDiagram {
        var open: [End] = []
        var frames: [Frame] = []
        var lane: String?
        var partitions: [String] = []
        var lastNode: String?
        var connectorEnds: [String: [End]] = [:]
        var connectorTargets: [String: String] = [:]
        var pendingConnectors: [String] = []
        var titleOverride = title
        let builder = self.builder

        func newID(_ title: String) -> String {
            let base = SpecEmitter.baseID(title)
            var id = base
            var n = 2
            while builder.contains(id) { id = "\(base)\(n)"; n += 1 }
            return id
        }
        func connect(_ ends: [End], to id: String) {
            for e in ends {
                var edge = DiagramEdge(from: e.from, to: id, line: e.line, startMarker: .none, endMarker: .filledArrow)
                if let l = e.label, !l.isEmpty { edge.label = normalizeLabel(l) }
                edge.labelSpan = e.labelSpan
                builder.edges.append(edge)
            }
        }
        @discardableResult
        func add(_ kind: NodeKind, title: String, titleSpan: SourceSpan? = nil, span: SourceSpan, connected: Bool = true) -> String {
            let id = newID(title)
            builder.declare(id, kind: kind, title: title, titleSpan: titleSpan, declaration: span, standalone: true,
                            parent: partitions.last ?? lane)
            if titleSpan == nil { builder.update(id) { $0.titleIsIdentifier = false } }
            if connected { connect(open, to: id) }
            open = [End(from: id)]
            lastNode = id
            for i in frames.indices {
                if case let .repeatLoop(nil, backward, breaks) = frames[i] { frames[i] = .repeatLoop(first: id, backward: backward, breaks: breaks) }
                if case let .fork(bar, ends, true) = frames[i], bar != id { frames[i] = .fork(bar: bar, ends: ends, empty: false) }
            }
            for c in pendingConnectors where connectorTargets[c] == nil { connectorTargets[c] = id }
            pendingConnectors = []
            return id
        }
        func labelled(_ ends: [End], _ label: String?, _ span: SourceSpan?) -> [End] {
            ends.map { var e = $0; if let label { e.label = label; e.labelSpan = span }; return e }
        }
        func group(_ kind: NodeKind, _ name: String, span: SourceSpan, parent: String?) -> String {
            if let existing = builder.nodes.first(where: { $0.kind == kind && $0.title == name }) { return existing.id }
            let id = newID(name)
            builder.declare(id, kind: kind, title: name, declaration: span, standalone: false, parent: parent)
            builder.update(id) { $0.titleIsIdentifier = false }
            return id
        }

        var i = 0
        var skipping: String?
        var braces = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let t = line.trimmed
            if let s = skipping { if t.lowercased().hasPrefix(s) { skipping = nil }; continue }
            if braces > 0 { if t.hasSuffix("{") { braces += 1 }; if t.hasPrefix("}") { braces -= 1 }; continue }
            if t.isEmpty || t.hasPrefix("'") || t.hasPrefix("@startuml") || t.hasPrefix("!") { continue }
            if t.hasPrefix("/'") { if !t.contains("'/") { skipping = "'/" }; continue }
            if t.hasPrefix("skinparam") && t.hasSuffix("{") { braces = 1; continue }
            if t.hasPrefix("legend") && !t.contains("endlegend") { skipping = "endlegend"; continue }
            if t.hasPrefix("title ") { titleOverride = String(t.dropFirst(6)); continue }
            if ["skinparam", "scale ", "header", "footer", "caption ", "hide ", "left to right", "top to bottom", "<style>", "</style>"]
                .contains(where: { t.hasPrefix($0) }) { continue }
            func r(_ m: NSTextCheckingResult, _ g: Int) -> (String?, SourceSpan?) {
                guard m.has(g) else { return (nil, nil) }
                let range = m.range(at: g)
                let lead = line.ns.range(of: t).location
                return (line.string(NSRange(location: lead + range.location, length: range.length)).trimmingCharacters(in: .whitespaces),
                        line.span(NSRange(location: lead + range.location, length: range.length)))
            }
            let tns = t as NSString
            let lower = t.lowercased()

            // Activities: ":text;" possibly over several lines, optionally coloured "#pink:text;".
            if let colon = Self.actionColon(t) {
                var text = String(t.dropFirst(colon + 1))
                let lead = line.ns.range(of: t).location
                let startOffset = line.offset + lead + colon + 1
                var endLine = line
                while !(text.last.map { Self.terminators.contains($0) } ?? false), i < lines.count {
                    endLine = lines[i]
                    i += 1
                    text += "\n" + endLine.text
                    text = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                }
                let terminator = text.last.flatMap { Self.terminators.contains($0) ? $0 : nil }
                if terminator != nil { text.removeLast() }
                let trailing = endLine.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                let endOffset = endLine.offset + (trailing as NSString).length - (terminator == nil ? 0 : 1)
                let span = SourceSpan(location: line.offset, length: endLine.offset + endLine.length - line.offset)
                let titleSpan = SourceSpan(location: startOffset, length: max(endOffset - startOffset, 0))
                let id = add(.action, title: text.trimmingCharacters(in: .whitespaces), titleSpan: titleSpan, span: span)
                if let terminator, terminator != ";" { builder.update(id) { $0.technology = String(terminator) } }
                continue
            }
            if lower == "start" {
                open = []
                add(.activityStart, title: "Start", span: line.span)
                continue
            }
            if lower == "stop" || lower == "end" {
                add(lower == "stop" ? .activityStop : .activityEnd, title: lower == "stop" ? "Stop" : "Flow End", span: line.span)
                open = []
                continue
            }
            if lower == "detach" || lower == "kill" { open = []; continue }
            if let m = Self.connectorLine.firstMatch(in: tns) {
                let name = tns.substring(with: m.range(at: 1))
                connectorEnds[name, default: []] += open
                open = []
                pendingConnectors.append(name)
                continue
            }
            if let m = Self.arrowLine.firstMatch(in: tns) {
                let style = (m.string(1, in: tns) ?? "").lowercased()
                let (label, span) = r(m, 2)
                let lineStyle: EdgeLineStyle = style.contains("dashed") ? .dashed : style.contains("dotted") ? .dotted
                    : style.contains("bold") ? .thick : style.contains("hidden") ? .invisible : .solid
                open = open.map { var e = $0; e.line = lineStyle; if let label, !label.isEmpty { e.label = label; e.labelSpan = span }; return e }
                continue
            }
            if let m = Self.ifLine.firstMatch(in: tns) {
                let (cond, condSpan) = r(m, 1)
                let d = add(.diamond, title: cond ?? "", titleSpan: condSpan, span: line.span)
                let (label, labelSpan) = m.has(3) ? r(m, 3) : r(m, 2)
                frames.append(.branch(decision: d, ends: [], hasElse: false))
                open = [End(from: d, label: label, labelSpan: labelSpan)]
                continue
            }
            if let m = Self.elseIfLine.firstMatch(in: tns), case let .branch(d, ends, _)? = frames.last {
                let (before, beforeSpan) = r(m, 1)
                let (cond, condSpan) = r(m, 2)
                let (label, labelSpan) = m.has(4) ? r(m, 4) : r(m, 3)
                let collected = ends + open
                open = [End(from: d, label: before, labelSpan: beforeSpan)]
                let d2 = add(.diamond, title: cond ?? "", titleSpan: condSpan, span: line.span)
                frames[frames.count - 1] = .branch(decision: d2, ends: collected, hasElse: false)
                open = [End(from: d2, label: label, labelSpan: labelSpan)]
                continue
            }
            if let m = Self.elseLine.firstMatch(in: tns), case let .branch(d, ends, _)? = frames.last {
                let (label, span) = r(m, 1)
                frames[frames.count - 1] = .branch(decision: d, ends: ends + open, hasElse: true)
                open = [End(from: d, label: label, labelSpan: span)]
                continue
            }
            if lower.range(of: #"^end\s*if$"#, options: .regularExpression) != nil, case let .branch(d, ends, hasElse)? = frames.last {
                frames.removeLast()
                open = ends + open + (hasElse ? [] : [End(from: d)])
                continue
            }
            if let m = Self.switchLine.firstMatch(in: tns) {
                let (cond, condSpan) = r(m, 1)
                let d = add(.diamond, title: cond ?? "", titleSpan: condSpan, span: line.span)
                frames.append(.choice(decision: d, ends: [], sawCase: false))
                open = []
                continue
            }
            if let m = Self.caseLine.firstMatch(in: tns), case let .choice(d, ends, sawCase)? = frames.last {
                let (label, span) = r(m, 1)
                frames[frames.count - 1] = .choice(decision: d, ends: sawCase ? ends + open : ends, sawCase: true)
                open = [End(from: d, label: label, labelSpan: span)]
                continue
            }
            if lower.range(of: #"^end\s*switch$"#, options: .regularExpression) != nil, case let .choice(_, ends, _)? = frames.last {
                frames.removeLast()
                open = ends + open
                continue
            }
            if let m = Self.whileLine.firstMatch(in: tns) {
                let (cond, condSpan) = r(m, 1)
                let d = add(.diamond, title: cond ?? "", titleSpan: condSpan, span: line.span)
                let (label, span) = r(m, 2)
                frames.append(.loop(decision: d, breaks: []))
                open = [End(from: d, label: label, labelSpan: span)]
                continue
            }
            if let m = Self.endWhileLine.firstMatch(in: tns), case let .loop(d, breaks)? = frames.last {
                frames.removeLast()
                connect(open, to: d)
                let (label, span) = r(m, 1)
                open = [End(from: d, label: label, labelSpan: span)] + breaks
                continue
            }
            if let m = Self.repeatWhileLine.firstMatch(in: tns), case let .repeatLoop(first, backward, breaks)? = frames.last {
                frames.removeLast()
                let (cond, condSpan) = r(m, 1)
                let d = add(.diamond, title: cond ?? "", titleSpan: condSpan, span: line.span)
                let (yes, yesSpan) = r(m, 2)
                let (no, noSpan) = r(m, 3)
                if let first {
                    let back = [End(from: d, label: yes, labelSpan: yesSpan)]
                    if let backward { connect(back, to: backward); connect([End(from: backward)], to: first) } else { connect(back, to: first) }
                }
                open = [End(from: d, label: no, labelSpan: noSpan)] + breaks
                continue
            }
            if lower == "repeat" || lower.hasPrefix("repeat ") || lower.hasPrefix("repeat:") {
                frames.append(.repeatLoop(first: nil, backward: nil, breaks: []))
                let rest = t.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":"), rest.count > 1 {
                    var text = String(rest.dropFirst())
                    if let last = text.last, Self.terminators.contains(last) { text.removeLast() }
                    let lead = (line.text as NSString).range(of: rest).location
                    add(.action, title: text, titleSpan: line.span(NSRange(location: lead + 1, length: (text as NSString).length)), span: line.span)
                }
                continue
            }
            if lower.hasPrefix("backward"), let colon = t.firstIndex(of: ":"), let index = frames.lastIndex(where: { if case .repeatLoop = $0 { true } else { false } }),
               case let .repeatLoop(first, _, breaks) = frames[index] {
                var text = String(t[t.index(after: colon)...])
                if let last = text.last, Self.terminators.contains(last) { text.removeLast() }
                let saved = open
                let id = add(.action, title: text, span: line.span, connected: false)
                open = saved
                frames[index] = .repeatLoop(first: first, backward: id, breaks: breaks)
                continue
            }
            if lower == "break", let index = frames.lastIndex(where: {
                switch $0 { case .loop, .repeatLoop: true; default: false }
            }) {
                switch frames[index] {
                case let .loop(d, breaks): frames[index] = .loop(decision: d, breaks: breaks + open)
                case let .repeatLoop(f, b, breaks): frames[index] = .repeatLoop(first: f, backward: b, breaks: breaks + open)
                default: break
                }
                open = []
                continue
            }
            if lower == "fork" {
                let bar = add(.forkBar, title: "Fork", span: line.span)
                frames.append(.fork(bar: bar, ends: [], empty: true))
                continue
            }
            if lower == "fork again", case let .fork(bar, ends, empty)? = frames.last {
                frames[frames.count - 1] = .fork(bar: bar, ends: ends + open, empty: empty)
                open = [End(from: bar)]
                continue
            }
            if lower.hasPrefix("end fork") || lower.hasPrefix("endfork") || lower == "end merge", case let .fork(bar, ends, empty)? = frames.last {
                frames.removeLast()
                // "fork / end fork" with nothing in between is a lone bar.
                if empty && ends.isEmpty { open = [End(from: bar)]; continue }
                open = ends + open
                if lower != "end merge" { add(.forkBar, title: "Join", span: line.span) }
                continue
            }
            if lower == "split" {
                frames.append(.split(origin: open, ends: []))
                continue
            }
            if lower == "split again", case let .split(origin, ends)? = frames.last {
                frames[frames.count - 1] = .split(origin: origin, ends: ends + open)
                open = origin
                continue
            }
            if lower == "end split", case let .split(_, ends)? = frames.last {
                frames.removeLast()
                open = ends + open
                continue
            }
            if let m = Self.laneLine.firstMatch(in: tns) {
                let name = tns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                lane = group(.lane, name, span: line.span, parent: nil)
                continue
            }
            if let m = Self.partitionLine.firstMatch(in: tns), lower.hasPrefix("partition") || lower.hasPrefix("group") {
                let name = (m.string(1, in: tns) ?? m.string(2, in: tns) ?? "Partition").trimmingCharacters(in: .whitespaces)
                partitions.append(group(.group, name, span: line.span, parent: partitions.last ?? lane))
                continue
            }
            if t == "}" || lower == "end group" || lower == "endgroup" {
                if !partitions.isEmpty { partitions.removeLast() }
                continue
            }
            if let m = Self.noteLine.firstMatch(in: tns) {
                let floating = m.has(1)
                let side = m.string(2, in: tns) ?? "right"
                var text: String
                var span = line.span
                var titleSpan: SourceSpan?
                if m.has(3) {
                    (text, titleSpan) = { let (a, b) = r(m, 3); return (a ?? "", b) }()
                } else {
                    var body: [String] = []
                    while i < lines.count {
                        let l = lines[i]
                        i += 1
                        span = span.union(l.span)
                        if l.trimmed.lowercased().range(of: #"^end\s*note$"#, options: .regularExpression) != nil { break }
                        body.append(l.trimmed)
                    }
                    text = body.joined(separator: "\n")
                }
                let target = floating ? nil : lastNode
                let saved = open
                let id = add(.note, title: text, titleSpan: titleSpan, span: span, connected: false)
                open = saved
                lastNode = target
                builder.update(id) { $0.technology = (floating ? "floating " : "") + side }
                if let target {
                    builder.edges.append(DiagramEdge(from: id, to: target, line: .dotted, startMarker: .none, endMarker: .none))
                }
                continue
            }
            builder.diagnostics.append(Diagnostic(line: line.number, message: "Unrecognised activity statement"))
        }
        for (name, target) in connectorTargets { connect(connectorEnds[name] ?? [], to: target) }
        return builder.finish(family: .activity, direction: .topDown, title: titleOverride, insertionOffset: insertionOffset)
    }

    /// Index of the ":" that opens an activity (after an optional colour), or nil.
    private static func actionColon(_ t: String) -> Int? {
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let head = t[..<colon]
        guard head.isEmpty || head.range(of: #"^#[\w#;.]+$"#, options: .regularExpression) != nil else { return nil }
        // Not a use-case actor (":User:").
        if head.isEmpty, actionStart.firstMatch(in: t as NSString) == nil { return nil }
        return t.distance(from: t.startIndex, to: colon)
    }
}
