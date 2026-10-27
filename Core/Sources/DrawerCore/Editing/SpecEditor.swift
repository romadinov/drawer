import Foundation

/// Changes requested from the drawing side for one node.
public struct NodeEdit: Equatable, Sendable {
    public var title: String?
    public var kind: NodeKind?
    public var stereotype: String??
    public var technology: String??
    public var description: String??
    public var fields: [String]?
    public var methods: [String]?
    public init(title: String? = nil, kind: NodeKind? = nil, stereotype: String?? = nil, technology: String?? = nil,
                description: String?? = nil, fields: [String]? = nil, methods: [String]? = nil) {
        self.title = title
        self.kind = kind
        self.stereotype = stereotype
        self.technology = technology
        self.description = description
        self.fields = fields
        self.methods = methods
    }
}

public struct EdgeEdit: Equatable, Sendable {
    public var label: String??
    public var technology: String??
    public var fromLabel: String??
    public var toLabel: String??
    public var line: EdgeLineStyle?
    public var startMarker: EdgeMarker?
    public var endMarker: EdgeMarker?
    public var reverse: Bool
    public init(label: String?? = nil, technology: String?? = nil, fromLabel: String?? = nil, toLabel: String?? = nil,
                line: EdgeLineStyle? = nil, startMarker: EdgeMarker? = nil, endMarker: EdgeMarker? = nil, reverse: Bool = false) {
        self.label = label
        self.technology = technology
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.line = line
        self.startMarker = startMarker
        self.endMarker = endMarker
        self.reverse = reverse
    }
}

/// Applies drawing-side changes to the spec text with minimal, local edits so that
/// the user's formatting and comments survive.
public struct SpecEditor {
    public let language: SpecLanguage
    public private(set) var spec: String
    public private(set) var parsed: ParsedDiagram

    public init(spec: String, language: SpecLanguage) {
        self.language = language
        self.spec = spec
        parsed = SpecParser.parse(spec, language: language)
    }

    var emitter: SpecEmitter { SpecEmitter(language: language, family: parsed.family) }

    // MARK: Text plumbing

    private struct Replacement {
        var range: NSRange
        var text: String
    }

    private mutating func apply(_ replacements: [Replacement]) {
        let ns = NSMutableString(string: spec)
        // Apply back to front; drop overlaps.
        var lastStart = Int.max
        for r in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            if r.range.location + r.range.length > lastStart { continue }
            ns.replaceCharacters(in: r.range, with: r.text)
            lastStart = r.range.location
        }
        spec = ns as String
        parsed = SpecParser.parse(spec, language: language)
    }

    /// Full line range(s) for a span, including the trailing newline.
    private func lineRange(_ span: SourceSpan) -> NSRange {
        (spec as NSString).lineRange(for: span.nsRange)
    }

    private func indentation(at span: SourceSpan) -> String {
        let line = (spec as NSString).substring(with: lineRange(span))
        return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Inserts statement lines, either inside a group block or at the diagram's insertion point.
    private mutating func insert(_ text: String, inside parent: String?) {
        let ns = spec as NSString
        var location = parsed.insertionOffset
        var indent = defaultIndent
        if let parent, let group = parsed.node(parent), let span = group.declarationSpan {
            // Insert before the group's closing line.
            let closing = ns.lineRange(for: NSRange(location: max(span.end - 1, span.location), length: 0))
            if closing.location > span.location {
                location = closing.location
                indent = indentation(at: span) + "  "
            }
        }
        var block = text.split(separator: "\n", omittingEmptySubsequences: false).map { indent + $0 }.joined(separator: "\n") + "\n"
        if location > 0 && location <= ns.length && ns.character(at: location - 1) != 10 {
            block = "\n" + block
        }
        apply([Replacement(range: NSRange(location: location, length: 0), text: block)])
    }

    private var defaultIndent: String {
        // Mirror the indentation used by existing statements.
        for line in spec.split(separator: "\n").dropFirst() {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if !lead.isEmpty { return String(lead) }
        }
        return language == .mermaid ? "  " : ""
    }

    // MARK: Identifiers

    public func uniqueID(for title: String) -> String {
        var base = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .enumerated()
            .map { $0.offset == 0 ? $0.element : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }
            .joined()
        if base.isEmpty { base = "node" }
        if let f = base.first, f.isNumber { base = "n" + base }
        if parsed.family == .erDiagram && language == .mermaid { base = base.uppercased() }
        var id = base
        var n = 2
        while parsed.node(id) != nil { id = "\(base)\(n)"; n += 1 }
        return id
    }

    // MARK: Operations

    /// Adds a node; returns its id.
    @discardableResult
    public mutating func addNode(kind: NodeKind, title: String, parent: String? = nil) -> String {
        let id = uniqueID(for: title)
        var node = DiagramNode(id: id, kind: kind, title: title)
        node.titleIsIdentifier = title == id
        if let point = participantInsertionPoint() {
            var text = point.indent + emitter.declaration(for: node) + "\n"
            let ns = spec as NSString
            if point.location > 0 && point.location <= ns.length && ns.character(at: point.location - 1) != 10 { text = "\n" + text }
            apply([Replacement(range: NSRange(location: point.location, length: 0), text: text)])
        } else if kind.isGroup {
            let opening = emitter.groupOpening(node, indent: "")
            let closing = emitter.groupClosing(indent: "")
            insert(opening + "\n" + closing, inside: parent)
        } else {
            insert(emitter.declaration(for: node), inside: parent)
        }
        return id
    }

    public mutating func addEdge(from: String, to: String, label: String? = nil, before: String? = nil) {
        var edge = emitter.defaultEdge(from: from, to: to)
        edge.label = label ?? (parsed.family == .sequence ? "message" : nil)
        addEdge(edge, before: before)
    }

    /// - Parameter before: id of an existing edge whose line the new one is inserted above (sequence diagrams).
    public mutating func addEdge(_ edge: DiagramEdge, before: String? = nil) {
        let line = emitter.edge(edge, fromKind: parsed.node(edge.from)?.kind, toKind: parsed.node(edge.to)?.kind)
        if let before, let span = parsed.edge(before)?.span {
            let location = lineRange(span).location
            apply([Replacement(range: NSRange(location: location, length: 0), text: indentation(at: span) + line + "\n")])
            return
        }
        // C4 relationships may live anywhere; keep them at the top level.
        insert(line, inside: nil)
    }

    /// Where a new sequence participant goes: after the last participant declaration, else after the header.
    private func participantInsertionPoint() -> (location: Int, indent: String)? {
        guard parsed.family == .sequence else { return nil }
        let ns = spec as NSString
        if let last = parsed.nodes.compactMap({ $0.declarationIsStandalone ? $0.declarationSpan : nil }).max(by: { $0.location < $1.location }) {
            let r = lineRange(last)
            return (r.location + r.length, indentation(at: last))
        }
        let lines = SourceLine.split(spec)
        if let header = lines.first(where: { $0.trimmed.hasPrefix("@startuml") || $0.trimmed == "sequenceDiagram" }) {
            let r = ns.lineRange(for: NSRange(location: header.offset, length: 0))
            return (r.location + r.length, language == .mermaid ? "  " : "")
        }
        return nil
    }

    /// Deletes nodes (with their descendants and connected edges) and edges.
    public mutating func delete(nodes nodeIDs: Set<String>, edges edgeIDs: Set<String>) {
        let before = parsed
        var doomedNodes = nodeIDs
        for id in nodeIDs { doomedNodes.formUnion(before.descendants(of: id).map(\.id)) }
        let doomedEdges = Set(before.edges.filter { edgeIDs.contains($0.id) || doomedNodes.contains($0.from) || doomedNodes.contains($0.to) }.map(\.id))

        var ranges: [NSRange] = []
        for node in before.nodes where doomedNodes.contains(node.id) {
            if let d = node.declarationSpan { ranges.append(lineRange(d)) }
            for r in node.referenceSpans { ranges.append(lineRange(r)) }
        }
        for edge in before.edges where doomedEdges.contains(edge.id) {
            if let s = edge.span { ranges.append(lineRange(s)) }
        }
        apply(Self.merge(ranges).map { Replacement(range: $0, text: "") })
        restoreCollateral(expectedNodes: before.nodes.filter { !doomedNodes.contains($0.id) },
                          expectedEdges: before.edges.filter { !doomedEdges.contains($0.id) })
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, r.location <= last.location + last.length {
                let end = max(last.location + last.length, r.location + r.length)
                result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                result.append(r)
            }
        }
        return result
    }

    /// Removing whole lines may take unrelated statements with them (chained edges,
    /// inline node labels). Re-add anything that should have survived.
    private mutating func restoreCollateral(expectedNodes: [DiagramNode], expectedEdges: [DiagramEdge]) {
        var additions: [String] = []
        for node in expectedNodes where !node.kind.isGroup {
            let now = parsed.node(node.id)
            let lostNode = now == nil
            let lostLabel = !node.titleIsIdentifier && now?.titleIsIdentifier == true
            if lostNode || lostLabel { additions.append(emitter.declaration(for: node)) }
        }
        var remaining = parsed.edges.map { "\($0.from)->\($0.to)" }
        for edge in expectedEdges {
            let key = "\(edge.from)->\(edge.to)"
            if let i = remaining.firstIndex(of: key) {
                remaining.remove(at: i)
            } else {
                additions.append(emitter.edge(edge, fromKind: parsed.node(edge.from)?.kind ?? expectedNodes.first { $0.id == edge.from }?.kind,
                                              toKind: parsed.node(edge.to)?.kind ?? expectedNodes.first { $0.id == edge.to }?.kind))
            }
        }
        if !additions.isEmpty { insert(additions.joined(separator: "\n"), inside: nil) }
    }

    /// Updates a node. Returns the node's id afterwards (it changes when an identifier is renamed).
    @discardableResult
    public mutating func update(node id: String, _ edit: NodeEdit) -> String {
        guard var node = parsed.node(id) else { return id }
        let onlyTitle = edit.kind == nil && edit.stereotype == nil && edit.technology == nil
            && edit.description == nil && edit.fields == nil && edit.methods == nil
        var currentID = id

        if let title = edit.title, title != node.title {
            let identifierNamed = node.titleIsIdentifier && !node.kind.isC4 && node.kind != .boundary
            if identifierNamed, SpecEmitter.isIdentifier(title, allowHyphen: emitter.allowsHyphenInIDs), parsed.node(title) == nil,
               !(language == .mermaid && parsed.family == .flowchart) {
                renameIdentifier(id, to: title)
                currentID = title
                node.id = title
                node.title = title
                if onlyTitle { return currentID }
            } else if let span = node.titleSpan, !node.titleIsIdentifier {
                apply([Replacement(range: span.nsRange, text: emitter.inlineTitle(title))])
                node.title = title
                if onlyTitle { return currentID }
            } else {
                node.title = title
                node.titleIsIdentifier = false
            }
        }
        guard let fresh = parsed.node(currentID) else { return currentID }
        if fresh.kind.isGroup {
            // Group blocks are never re-emitted (that would drop their children);
            // titles are handled above via the title span.
            return currentID
        }
        if let k = edit.kind { node.kind = k }
        if let s = edit.stereotype { node.stereotype = s }
        if let t = edit.technology { node.technology = t }
        if let d = edit.description { node.description = d }
        if let f = edit.fields { node.fields = f }
        if let m = edit.methods { node.methods = m }
        node.parent = fresh.parent

        if let span = fresh.declarationSpan, fresh.declarationIsStandalone {
            let range = lineRange(span)
            let indent = indentation(at: span)
            let text = emitter.declaration(for: node, indent: indent) + "\n"
            apply([Replacement(range: range, text: text)])
        } else {
            insert(emitter.declaration(for: node), inside: node.parent)
        }
        return currentID
    }

    public mutating func update(edge id: String, _ edit: EdgeEdit) {
        guard var edge = parsed.edge(id) else { return }
        let labelOnly = edit.technology == nil && edit.fromLabel == nil && edit.toLabel == nil && edit.line == nil
            && edit.startMarker == nil && edit.endMarker == nil && !edit.reverse
        if labelOnly, let newLabel = edit.label, let new = newLabel, !new.isEmpty, let span = edge.labelSpan {
            apply([Replacement(range: span.nsRange, text: emitter.inlineTitle(new))])
            return
        }
        if let l = edit.label { edge.label = l }
        if let t = edit.technology { edge.technology = t }
        if let f = edit.fromLabel { edge.fromLabel = f }
        if let t = edit.toLabel { edge.toLabel = t }
        if let l = edit.line { edge.line = l }
        if let s = edit.startMarker { edge.startMarker = s }
        if let e = edit.endMarker { edge.endMarker = e }
        if edit.reverse {
            swap(&edge.from, &edge.to)
            swap(&edge.fromLabel, &edge.toLabel)
            swap(&edge.startMarker, &edge.endMarker)
        }
        if let span = edge.span, edge.spanIsStandalone {
            let indent = indentation(at: span)
            let text = emitter.edge(edge, fromKind: parsed.node(edge.from)?.kind, toKind: parsed.node(edge.to)?.kind, indent: indent) + "\n"
            apply([Replacement(range: lineRange(span), text: text)])
        } else {
            delete(nodes: [], edges: [id])
            addEdge(edge)
        }
    }

    /// Renames an identifier everywhere it appears as a whole word.
    public mutating func renameIdentifier(_ old: String, to new: String) {
        let escaped = NSRegularExpression.escapedPattern(for: old)
        let pattern = #"(?<![\w])(?<!\w-)"# + escaped + #"(?![\w])(?!-\w)"#
        let regex = NSRegularExpression(pattern)
        let ns = spec as NSString
        let matches = regex.matches(in: spec, range: NSRange(location: 0, length: ns.length))
        apply(matches.map { Replacement(range: $0.range, text: new) })
    }
}
