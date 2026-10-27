import Foundation

/// Sequence diagrams for both PlantUML and Mermaid.
struct SequenceParser {
    enum Dialect { case plantUML, mermaid }

    let dialect: Dialect
    let lines: [SourceLine]
    let builder = DiagramBuilder()
    private var info = SequenceInfo()

    init(dialect: Dialect, lines: [SourceLine]) {
        self.dialect = dialect
        self.lines = lines
    }

    // MARK: Statement patterns

    private static let pumlParticipant = NSRegularExpression(
        #"^\s*(participant|actor|boundary|control|entity|database|collections|queue)\s+(?:"([^"]+)"\s+as\s+([\w.]+)|([\w.]+)\s+as\s+"([^"]+)"|([\w.]+)\s+as\s+([\w.]+)|"([^"]+)"|([\w.]+))\s*(?:<<.*>>)?\s*(?:order\s+\d+)?\s*(?:#\w+)?\s*$"#)
    private static let mermaidParticipant = NSRegularExpression(
        #"^\s*(?:create\s+)?(participant|actor)\s+([^\s]+?)(?:\s+as\s+(.+?))?\s*$"#)

    /// PlantUML: `A -> B : text`, `A <-- B`, `A ->> B ++ : text`, `A ->x B`.
    private static let pumlMessage = NSRegularExpression(
        #"^\s*("[^"]+"|[\w.]+)\s*([ox]?<{1,2}|[ox]?[\\/]{1,2})?(-{1,2})(?:\[[^\]]*\])?(-?)(>{1,2}|[\\/]{1,2})?([ox])?\s*("[^"]+"|[\w.]+)\s*(\+\+|--|\*\*|!!)?\s*(?::\s*(.*?))?\s*$"#)
    /// Mermaid: `A->>B: text`, `A-->>-B: text`, `A-)B: text`, `A<<->>B: text`.
    private static let mermaidMessage = NSRegularExpression(
        #"^\s*([^\s\-<>+:)]+?)\s*(<<)?(-{1,2})(>>|>|x|\))([+-])?\s*([^\s:+-][^:]*?)\s*(?::\s*(.*?))?\s*$"#)

    private static let note = NSRegularExpression(
        #"^\s*(?:[hr]?note|Note|ref)\s+(left of|right of|over|left|right)\s*([^:]*?)\s*(?::\s*(.*?))?\s*$"#, options: [.caseInsensitive])

    private static let fragmentKeywords = ["alt", "opt", "loop", "par", "critical", "break", "group", "rect", "box", "region"]
    private static let elseKeywords = ["else", "and", "option"]

    // MARK: Parse

    mutating func parse(insertionOffset: Int) -> ParsedDiagram {
        var title: String?
        var noteBuffer: (participants: [String], position: SequenceEvent.NotePosition, text: [String], start: SourceLine)?
        // Calls opened with `++` / activate, for PlantUML `return`.
        var callStack: [(caller: String, callee: String)] = []
        var lastMessage: (from: String, to: String)?

        for line in lines {
            let t = line.trimmed
            if let buffer = noteBuffer {
                if t.lowercased().hasPrefix("end note") || t.lowercased().hasPrefix("endrnote") || t.lowercased().hasPrefix("endhnote") || t.lowercased() == "end ref" {
                    info.events.append(SequenceEvent(.note(buffer.text.joined(separator: "\n"), participants: buffer.participants, position: buffer.position),
                                                     span: buffer.start.span.union(line.span)))
                    noteBuffer = nil
                } else {
                    noteBuffer?.text.append(t)
                }
                continue
            }
            if t.isEmpty || t.hasPrefix("'") || t.hasPrefix("%%") || t.hasPrefix("@startuml") || t.hasPrefix("@enduml") { continue }
            if t == "sequenceDiagram" || t.hasPrefix("skinparam") || t.hasPrefix("hide ") || t.hasPrefix("show ") || t.hasPrefix("!")
                || t.hasPrefix("scale ") || t.hasPrefix("newpage") || t.hasPrefix("destroy ") || t.hasPrefix("create ") && !t.contains("participant") && !t.contains("actor") { continue }
            if t.hasPrefix("title ") || t.hasPrefix("title:") { title = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if t.hasPrefix("autonumber") { info.autonumber = !t.contains("off") && !t.contains("stop"); continue }

            // Participants
            if dialect == .plantUML, let m = Self.pumlParticipant.firstMatch(in: line.ns) {
                declarePUML(m, line: line)
                continue
            }
            if dialect == .mermaid, let m = Self.mermaidParticipant.firstMatch(in: line.ns) {
                let id = m.string(2, in: line.ns)!
                let alias = m.string(3, in: line.ns)
                let kind: NodeKind = m.string(1, in: line.ns) == "actor" ? .actor : .participant
                builder.declare(id, kind: kind, title: alias, titleSpan: alias != nil ? line.span(m.range(at: 3)) : line.span(m.range(at: 2)),
                                declaration: line.span, standalone: true, parent: nil)
                if alias == nil { builder.update(id) { $0.titleIsIdentifier = true; $0.title = id } }
                continue
            }

            // Notes
            if let m = Self.note.firstMatch(in: line.ns) {
                let where_ = m.string(1, in: line.ns)!.lowercased()
                let position: SequenceEvent.NotePosition = where_.hasPrefix("left") ? .left : where_.hasPrefix("right") ? .right : .over
                let participants = (m.string(2, in: line.ns) ?? "").split(separator: ",").map { stripQuotes(String($0)) }.filter { !$0.isEmpty }
                for p in participants { builder.ensure(p, kind: .participant, reference: line.span) }
                if let text = m.string(3, in: line.ns) {
                    info.events.append(SequenceEvent(.note(normalizeLabel(text), participants: participants, position: position), span: line.span))
                } else {
                    noteBuffer = (participants, position, [], line)
                }
                continue
            }

            // Fragments
            let firstWord = String(t.split(separator: " ", maxSplits: 1).first ?? "")
            let rest = t.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)
            if Self.fragmentKeywords.contains(firstWord) {
                info.events.append(SequenceEvent(.fragmentStart(kind: firstWord, label: rest), span: line.span))
                continue
            }
            if Self.elseKeywords.contains(firstWord) {
                info.events.append(SequenceEvent(.fragmentElse(label: rest), span: line.span))
                continue
            }
            if t == "end" || t.hasPrefix("end ") && !t.hasPrefix("end note") {
                info.events.append(SequenceEvent(.fragmentEnd, span: line.span))
                continue
            }
            if t.hasPrefix("==") && t.hasSuffix("==") {
                info.events.append(SequenceEvent(.divider(t.trimmingCharacters(in: CharacterSet(charactersIn: "= "))), span: line.span))
                continue
            }
            if t.hasPrefix("...") {
                let text = t.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                info.events.append(SequenceEvent(.delay(text.isEmpty ? nil : text), span: line.span))
                continue
            }
            if t.hasPrefix("|||") || t.hasPrefix("||") { info.events.append(SequenceEvent(.spacer, span: line.span)); continue }
            if firstWord == "activate" {
                let id = stripQuotes(rest.components(separatedBy: " ").first ?? "")
                builder.ensure(id, kind: .participant, reference: line.span)
                info.events.append(SequenceEvent(.activate(id), span: line.span))
                if let last = lastMessage, last.to == id { callStack.append((last.from, id)) }
                continue
            }
            if firstWord == "deactivate" {
                let id = stripQuotes(rest)
                builder.ensure(id, kind: .participant, reference: line.span)
                info.events.append(SequenceEvent(.deactivate(id), span: line.span))
                if let i = callStack.lastIndex(where: { $0.callee == id }) { callStack.remove(at: i) }
                continue
            }
            if dialect == .plantUML, firstWord == "return" {
                if let call = callStack.popLast() {
                    var edge = DiagramEdge(from: call.callee, to: call.caller, line: .dashed, startMarker: .none, endMarker: .arrow)
                    edge.label = rest.isEmpty ? nil : normalizeLabel(rest)
                    edge.span = line.span
                    builder.edges.append(edge)
                    info.events.append(SequenceEvent(.message(builder.edges.count - 1, activateTarget: false, deactivateSource: true), span: line.span))
                } else {
                    builder.diagnostics.append(Diagnostic(line: line.number, message: "'return' without an activated call"))
                }
                continue
            }

            // Messages
            if let msg = dialect == .plantUML ? parsePUMLMessage(line) : parseMermaidMessage(line) {
                builder.ensure(msg.edge.from, kind: .participant, reference: line.span(msg.fromRange))
                builder.ensure(msg.edge.to, kind: .participant, reference: line.span(msg.toRange))
                builder.edges.append(msg.edge)
                info.events.append(SequenceEvent(.message(builder.edges.count - 1, activateTarget: msg.activate, deactivateSource: msg.deactivate), span: line.span))
                if msg.activate { callStack.append((msg.edge.from, msg.edge.to)) }
                if msg.deactivate, let i = callStack.lastIndex(where: { $0.callee == msg.edge.from }) { callStack.remove(at: i) }
                lastMessage = (msg.edge.from, msg.edge.to)
                continue
            }
            builder.diagnostics.append(Diagnostic(line: line.number, message: "Unrecognised sequence statement"))
        }
        builder.setImplicitKind(.participant)
        var result = builder.finish(family: .sequence, direction: .leftRight, title: title, insertionOffset: insertionOffset)
        result.sequence = info
        return result
    }

    private func declarePUML(_ m: NSTextCheckingResult, line: SourceLine) {
        let ns = line.ns
        let kind: NodeKind = switch m.string(1, in: ns)! {
        case "actor": .actor
        case "boundary": .seqBoundary
        case "control": .seqControl
        case "entity": .seqEntity
        case "database": .database
        case "collections": .collections
        case "queue": .queue
        default: .participant
        }
        var id: String, title: String?, titleRange: NSRange
        if m.has(2) { title = m.string(2, in: ns); titleRange = m.range(at: 2); id = m.string(3, in: ns)! }
        else if m.has(4) { id = m.string(4, in: ns)!; title = m.string(5, in: ns); titleRange = m.range(at: 5) }
        else if m.has(6) { title = m.string(6, in: ns); titleRange = m.range(at: 6); id = m.string(7, in: ns)! }
        else if m.has(8) { id = m.string(8, in: ns)!; titleRange = m.range(at: 8) }
        else { id = m.string(9, in: ns)!; titleRange = m.range(at: 9) }
        builder.declare(id, kind: kind, title: title, titleSpan: line.span(titleRange), declaration: line.span, standalone: true, parent: nil)
        if title == nil { builder.update(id) { $0.titleIsIdentifier = true; $0.title = id } }
    }

    private struct Message {
        var edge: DiagramEdge
        var fromRange: NSRange
        var toRange: NSRange
        var activate: Bool
        var deactivate: Bool
    }

    private func parsePUMLMessage(_ line: SourceLine) -> Message? {
        guard let m = Self.pumlMessage.firstMatch(in: line.ns) else { return nil }
        let ns = line.ns
        let left = m.string(2, in: ns) ?? ""
        let body = (m.string(3, in: ns) ?? "") + (m.string(4, in: ns) ?? "")
        let right = m.string(5, in: ns) ?? ""
        let rightEnd = m.string(6, in: ns) ?? ""
        guard !left.isEmpty || !right.isEmpty || !rightEnd.isEmpty else { return nil } // plain "A - B" isn't a message
        var from = stripQuotes(m.string(1, in: ns)!), to = stripQuotes(m.string(7, in: ns)!)
        var fromRange = m.range(at: 1), toRange = m.range(at: 7)
        func head(_ s: String) -> EdgeMarker {
            if s.contains("x") { return .cross }
            if s.contains("o") { return .circle }
            if s.count >= 2 || s.contains("\\") || s.contains("/") { return .arrow }
            return s.isEmpty ? .none : .filledArrow
        }
        var end = head(right + rightEnd)
        var start = head(left)
        if !left.isEmpty && right.isEmpty && rightEnd.isEmpty {
            // Reverse arrow: B <- A
            swap(&from, &to)
            swap(&fromRange, &toRange)
            end = start
            start = .none
        }
        var edge = DiagramEdge(from: from, to: to, line: body.count >= 2 ? .dashed : .solid, startMarker: start, endMarker: end)
        if let label = m.string(9, in: ns), !label.isEmpty {
            edge.label = normalizeLabel(label)
            edge.labelSpan = line.span(m.range(at: 9))
        }
        edge.span = line.span
        edge.spanIsStandalone = true
        let modifier = m.string(8, in: ns)
        return Message(edge: edge, fromRange: fromRange, toRange: toRange, activate: modifier == "++", deactivate: modifier == "--")
    }

    private func parseMermaidMessage(_ line: SourceLine) -> Message? {
        guard let m = Self.mermaidMessage.firstMatch(in: line.ns) else { return nil }
        let ns = line.ns
        let dashes = m.string(3, in: ns)!
        let headText = m.string(4, in: ns)!
        let end: EdgeMarker = switch headText {
        case ">>": .filledArrow
        case "x": .cross
        case ")": .arrow
        default: .none
        }
        var edge = DiagramEdge(from: m.string(1, in: ns)!, to: m.string(6, in: ns)!, line: dashes.count == 2 ? .dashed : .solid,
                               startMarker: m.has(2) ? .filledArrow : .none, endMarker: end)
        if let label = m.string(7, in: ns), !label.isEmpty {
            edge.label = normalizeLabel(label)
            edge.labelSpan = line.span(m.range(at: 7))
        }
        edge.span = line.span
        edge.spanIsStandalone = true
        let modifier = m.string(5, in: ns)
        return Message(edge: edge, fromRange: m.range(at: 1), toRange: m.range(at: 6), activate: modifier == "+", deactivate: modifier == "-")
    }

    // MARK: Detection

    /// PlantUML is treated as a sequence diagram when it uses sequence-only syntax, or when it only
    /// has `A -> B` style messages and no structural declarations (PlantUML's own default).
    static func looksLikePlantUMLSequence(_ lines: [SourceLine]) -> Bool {
        let structural = NSRegularExpression(#"^\s*(class|interface|enum|abstract|entity\s+\w+\s*\{|component|usecase|package|namespace|node|rectangle|folder|frame|cloud|artifact|object|map|state|start|:.*;|\[.*\]|\(.*\)|Person|System|Container|Component|Rel)\b"#)
        let sequenceOnly = NSRegularExpression(#"^\s*(participant\b|activate\b|deactivate\b|autonumber\b|return\b|alt\b|loop\b|opt\b|par\b|critical\b|break\b|group\b|else\b|ref\s+over|[hr]?note\s+over|==.*==|\.\.\.|\|\|\|)"#)
        let message = NSRegularExpression(#"^\s*("[^"]+"|[\w.]+)\s*<?-{1,2}(?:\[[^\]]*\])?>{1,2}[ox]?\s*("[^"]+"|[\w.]+)"#)
        var messages = 0
        for line in lines {
            if structural.firstMatch(in: line.ns) != nil { return false }
            if sequenceOnly.firstMatch(in: line.ns) != nil { return true }
            if message.firstMatch(in: line.ns) != nil { messages += 1 }
        }
        return messages > 0
    }
}
