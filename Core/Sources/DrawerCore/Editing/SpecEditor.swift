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
    /// Elements whose id changed (old → new). PlantUML activities have no identifiers, so ids follow their text
    /// and their order; the layout has to follow too.
    public private(set) var renames: [String: String] = [:]

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
        var base = SpecEmitter.baseID(title)
        if parsed.family == .erDiagram && language == .mermaid { base = base.uppercased() }
        var id = base
        var n = 2
        while parsed.node(id) != nil { id = "\(base)\(n)"; n += 1 }
        return id
    }

    // MARK: Activity diagrams

    /// PlantUML activity diagrams are a flow of statements, not declarations and relationships, so structural
    /// changes rewrite the flow from the changed graph.
    private var rewritesActivity: Bool { language == .plantUML && parsed.family == .activity }

    @discardableResult
    private mutating func rewriteActivity(nodes: [DiagramNode], edges: [DiagramEdge]) -> [String: String] {
        let (text, order) = ActivityWriter(nodes: nodes, edges: edges).write()
        apply([Replacement(range: ActivityParser.bodyRange(of: spec), text: text.isEmpty ? "" : text + "\n")])
        let map = Self.matchActivityIDs(order: order + nodes.map(\.id).filter { !order.contains($0) }, old: nodes, new: parsed)
        record(map)
        return map
    }

    /// Pairs elements with the ones read back from rewritten text: same kind and text, in the order written.
    static func matchActivityIDs(order: [String], old: [DiagramNode], new: ParsedDiagram) -> [String: String] {
        func key(_ n: DiagramNode) -> String {
            n.kind.rawValue + "|" + (n.kind == .forkBar || n.kind.isActivitySymbol ? "" : n.title.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        var queues: [String: [String]] = [:]
        for n in new.nodes { queues[key(n), default: []].append(n.id) }
        let byID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var map: [String: String] = [:]
        for id in order {
            guard let n = byID[id], let next = queues[key(n)]?.first else { continue }
            queues[key(n)]?.removeFirst()
            map[id] = next
        }
        return map
    }

    private mutating func record(_ map: [String: String]) {
        for (old, new) in map where old != new && !old.hasPrefix("__") {
            if let first = renames.first(where: { $0.value == old })?.key { renames[first] = new } else { renames[old] = new }
        }
    }

    // MARK: Operations

    /// Adds a node; returns its id.
    @discardableResult
    public mutating func addNode(kind: NodeKind, title: String, parent: String? = nil) -> String {
        if rewritesActivity {
            var node = DiagramNode(id: "__new", kind: kind, title: title)
            node.titleIsIdentifier = false
            node.parent = parent
            return rewriteActivity(nodes: parsed.nodes + [node], edges: parsed.edges)["__new"] ?? uniqueID(for: title)
        }
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

    /// Moves elements into a group block: their declarations are cut and pasted inside it
    /// (or a declaration is added there for elements that were only mentioned in relationships).
    public mutating func move(nodes ids: [String], into parent: String) {
        if rewritesActivity {
            let moving = Set(ids).subtracting([parent])
            rewriteActivity(nodes: parsed.nodes.map { n in var n = n; if moving.contains(n.id) { n.parent = parent }; return n }, edges: parsed.edges)
            return
        }
        for id in ids where id != parent {
            guard let node = parsed.node(id), node.parent != parent, parsed.node(parent) != nil else { continue }
            var block: String
            if let span = node.declarationSpan, node.declarationIsStandalone {
                let range = lineRange(span)
                let lines = (spec as NSString).substring(with: range).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { String($0.prefix { $0 == " " || $0 == "\t" }) }.min { $0.count < $1.count } ?? ""
                block = lines.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }
                    .joined(separator: "\n").trimmingCharacters(in: .newlines)
                apply([Replacement(range: range, text: "")])
            } else {
                var n = node
                n.parent = parent
                block = emitter.declaration(for: n)
            }
            insert(block, inside: parent)
        }
    }

    public mutating func addEdge(from: String, to: String, label: String? = nil, before: String? = nil) {
        var edge = emitter.defaultEdge(from: from, to: to)
        edge.label = label ?? (parsed.family == .sequence ? "message" : nil)
        addEdge(edge, before: before)
    }

    /// - Parameter before: id of an existing edge whose line the new one is inserted above (sequence diagrams).
    public mutating func addEdge(_ edge: DiagramEdge, before: String? = nil) {
        if rewritesActivity {
            var edge = edge
            edge.id = "__edge"
            rewriteActivity(nodes: parsed.nodes, edges: parsed.edges + [edge])
            return
        }
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
        if rewritesActivity {
            var edges = before.edges.filter { !doomedEdges.contains($0.id) }
            // Taking a step out of a flow joins the steps around it.
            for id in doomedNodes {
                let ins = before.edges.filter { $0.to == id && $0.from != id && !edgeIDs.contains($0.id) }
                let outs = before.edges.filter { $0.from == id && $0.to != id && !edgeIDs.contains($0.id) }
                guard ins.count == 1, outs.count == 1, !doomedNodes.contains(ins[0].from), !doomedNodes.contains(outs[0].to),
                      before.node(id)?.kind != .note else { continue }
                var joined = ins[0]
                joined.to = outs[0].to
                joined.id = "__heal\(id)"
                edges.append(joined)
            }
            rewriteActivity(nodes: before.nodes.filter { !doomedNodes.contains($0.id) }, edges: edges)
            return
        }

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
        if rewritesActivity { return updateActivity(node, edit, onlyTitle: onlyTitle) }

        if let title = edit.title, title != node.title {
            let identifierNamed = node.titleIsIdentifier && !node.kind.isC4 && node.kind != .boundary
            if identifierNamed, SpecEmitter.isIdentifier(title, allowHyphen: emitter.allowsHyphenInIDs), parsed.node(title) == nil,
               !(language == .mermaid && parsed.family == .flowchart) {
                // Only where the spec uses it as this element — never inside other titles or keywords.
                if !renameReferences(id, to: title) { renameIdentifier(id, to: title) }
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

    private mutating func updateActivity(_ node: DiagramNode, _ edit: NodeEdit, onlyTitle: Bool) -> String {
        if onlyTitle, let title = edit.title, let span = node.titleSpan, node.kind != .lane {
            let before = parsed
            var text = title.replacingOccurrences(of: "\n", with: "\\n")
            if node.kind == .action { text = text.replacingOccurrences(of: ";", with: ",") }
            if node.kind == .diamond { text = text.replacingOccurrences(of: ")", with: "]") }
            apply([Replacement(range: span.nsRange, text: text)])
            // Same elements in the same order; only ids that follow the text change.
            var map: [String: String] = [:]
            if before.nodes.count == parsed.nodes.count {
                for (a, b) in zip(before.nodes, parsed.nodes) where a.kind == b.kind { map[a.id] = b.id }
            }
            record(map)
            return map[node.id] ?? node.id
        }
        var changed = node
        if let t = edit.title { changed.title = t }
        if let k = edit.kind { changed.kind = k }
        if let t = edit.technology { changed.technology = t }
        let nodes = parsed.nodes.map { $0.id == node.id ? changed : $0 }
        return rewriteActivity(nodes: nodes, edges: parsed.edges)[node.id] ?? node.id
    }

    public mutating func update(edge id: String, _ edit: EdgeEdit) {
        guard var edge = parsed.edge(id) else { return }
        let labelOnly = edit.technology == nil && edit.fromLabel == nil && edit.toLabel == nil && edit.line == nil
            && edit.startMarker == nil && edit.endMarker == nil && !edit.reverse
        if labelOnly, let newLabel = edit.label, let new = newLabel, !new.isEmpty, let span = edge.labelSpan {
            apply([Replacement(range: span.nsRange, text: rewritesActivity ? new.replacingOccurrences(of: ")", with: "]").replacingOccurrences(of: ";", with: ",")
                                                                                       : emitter.inlineTitle(new))])
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
        if rewritesActivity {
            rewriteActivity(nodes: parsed.nodes, edges: parsed.edges.map { $0.id == id ? edge : $0 })
            return
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
    /// Renames an element's id only where the parser saw it used as that element (declaration, relationships),
    /// never in other words that happen to match — `Container(Container, …)` keeps its macro name.
    /// Returns false if the spec doesn't record those places (then nothing is changed).
    @discardableResult
    public mutating func renameReferences(_ old: String, to new: String) -> Bool {
        guard !rewritesActivity, let node = parsed.node(old) else { return false }
        let ns = spec as NSString
        let macros: Set<String> = ["Person", "Person_Ext", "System", "System_Ext", "SystemDb", "SystemDb_Ext", "SystemQueue", "Container",
                                   "Container_Ext", "ContainerDb", "ContainerDb_Ext", "ContainerQueue", "Component", "Component_Ext",
                                   "ComponentDb", "ComponentQueue", "Boundary", "System_Boundary", "Container_Boundary", "Enterprise_Boundary"]
        let word = NSRegularExpression("(?<![\\w])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\w])")
        var ranges: [NSRange] = []
        for span in node.referenceSpans where span.end <= ns.length {
            if ns.substring(with: span.nsRange) == old { ranges.append(span.nsRange); continue }
            // A whole declaration line: the id is the first standalone occurrence outside quotes that isn't a macro name.
            for m in word.matches(in: spec, range: span.nsRange) {
                let before = ns.substring(with: NSRange(location: span.location, length: m.range.location - span.location))
                let inQuotes = before.filter { $0 == "\"" }.count % 2 == 1
                let callsMacro = macros.contains(old) && m.range.upperBound < ns.length && ns.character(at: m.range.upperBound) == 40 // "("
                if !inQuotes && !callsMacro { ranges.append(m.range); break }
            }
        }
        guard !ranges.isEmpty else { return false }
        var seen = Set<Int>()
        apply(ranges.filter { seen.insert($0.location).inserted }.map { Replacement(range: $0, text: new) })
        return parsed.node(new) != nil && parsed.node(old) == nil
    }

    public mutating func renameIdentifier(_ old: String, to new: String) {
        let escaped = NSRegularExpression.escapedPattern(for: old)
        let pattern = #"(?<![\w])(?<!\w-)"# + escaped + #"(?![\w])(?!-\w)"#
        let regex = NSRegularExpression(pattern)
        let ns = spec as NSString
        let matches = regex.matches(in: spec, range: NSRange(location: 0, length: ns.length))
        apply(matches.map { Replacement(range: $0.range, text: new) })
    }
}
