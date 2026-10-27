import Foundation

/// Spoken commands for building a diagram, e.g.
/// "add a database called Orders", "connect web app to orders labelled reads",
/// "API calls payments", "rename shop to storefront", "delete orders", "make shop an external system",
/// "undo", "auto layout". Several can be chained with "then" / "and then".
public enum VoiceCommand: Equatable, Sendable {
    case add(kind: String?, name: String)
    case connect(from: String, to: String, label: String?)
    case rename(String, to: String)
    case delete(String)
    case changeKind(String, kind: String)
    case note(String)
    case undo, redo, autoLayout, zoomToFit

    // MARK: Parsing

    public static func parse(_ utterance: String, knownNames: [String] = []) -> [VoiceCommand] {
        let cleaned = utterance.replacingOccurrences(of: #"[.,!?;:"“”]"#, with: " ", options: .regularExpression)
        let parts = cleaned.components(separatedBy: " then ").flatMap { $0.components(separatedBy: " and then ") }
        return parts.compactMap { parseOne($0.trimmingCharacters(in: .whitespaces), knownNames: knownNames) }
    }

    static func parseOne(_ text: String, knownNames: [String]) -> VoiceCommand? {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return nil }
        let rest = Array(words.dropFirst())
        let lower = text.lowercased()

        switch lower {
        case "undo", "undo that", "go back": return .undo
        case "redo": return .redo
        case "auto layout", "autolayout", "layout", "tidy up", "arrange", "rearrange", "clean up": return .autoLayout
        case "zoom to fit", "fit", "show all", "show everything": return .zoomToFit
        default: break
        }

        func dropArticles(_ w: [String]) -> [String] {
            var w = w
            while let f = w.first?.lowercased(), ["a", "an", "the", "new", "another"].contains(f) { w.removeFirst() }
            return w
        }
        func split(_ w: [String], at separators: [String]) -> ([String], [String], String)? {
            for (i, word) in w.enumerated() where separators.contains(word.lowercased()) && i > 0 && i < w.count - 1 {
                return (Array(w[..<i]), Array(w[(i + 1)...]), word.lowercased())
            }
            return nil
        }
        func phrase(_ w: [String]) -> String { w.joined(separator: " ") }

        switch first {
        case "add", "create", "insert", "new", "draw", "put":
            let body = dropArticles(rest)
            guard !body.isEmpty else { return nil }
            if body.first?.lowercased() == "note", body.count > 1 { return .note(phrase(Array(Array(body.dropFirst()).drop { ["saying", "that"].contains($0.lowercased()) }))) }
            if let (kind, name, _) = split(body, at: ["called", "named", "titled", "labelled", "labeled"]) {
                return .add(kind: phrase(kind), name: phrase(name))
            }
            return .add(kind: nil, name: phrase(body))
        case "connect", "link", "join", "wire":
            let body = dropArticles(rest)
            guard let (a, tail, _) = split(body, at: ["to", "with", "and"]) else { return nil }
            if let (b, label, _) = split(tail, at: ["labelled", "labeled", "saying", "as", "label", "with"]) {
                return .connect(from: phrase(dropArticles(a)), to: phrase(dropArticles(b)), label: phrase(label).trimmingPrefix("label "))
            }
            return .connect(from: phrase(dropArticles(a)), to: phrase(dropArticles(tail)), label: nil)
        case "rename", "call":
            let body = dropArticles(rest)
            guard let (a, b, _) = split(body, at: ["to", "as"]) else { return nil }
            return .rename(phrase(dropArticles(a)), to: phrase(b))
        case "delete", "remove", "erase":
            let body = dropArticles(rest)
            return body.isEmpty ? nil : .delete(phrase(body))
        case "make", "change", "turn", "convert":
            let body = dropArticles(rest)
            if let (a, kind, _) = split(body, at: ["into", "to", "a", "an"]) {
                return .changeKind(phrase(dropArticles(a)), kind: phrase(dropArticles(kind)))
            }
            return nil
        case "note":
            return rest.isEmpty ? nil : .note(phrase(rest))
        default:
            // "<A> calls <B>": a relationship named by its verb, between two known elements.
            let verbs = ["calls", "uses", "sends to", "sends", "reads from", "writes to", "talks to", "depends on", "queries", "owns",
                         "has", "contains", "notifies", "publishes to", "subscribes to", "extends", "implements"]
            for verb in verbs {
                guard let r = lower.range(of: " \(verb) ") else { continue }
                let a = String(text[..<r.lowerBound]), b = String(text[r.upperBound...])
                let aWords = dropArticles(a.split(separator: " ").map(String.init)), bWords = dropArticles(b.split(separator: " ").map(String.init))
                guard !aWords.isEmpty, !bWords.isEmpty else { continue }
                let from = phrase(aWords), to = phrase(bWords)
                if knownNames.isEmpty || NameMatcher.best(from, in: knownNames) != nil || NameMatcher.best(to, in: knownNames) != nil {
                    return .connect(from: from, to: to, label: verb)
                }
            }
            return nil
        }
    }

    // MARK: Applying

    public struct Outcome: Equatable, Sendable {
        /// What happened, for showing back to the user ("Added Container “Orders”").
        public var messages: [String] = []
        /// Elements touched, to select.
        public var touched: [ElementRef] = []
        /// Commands only the app can carry out (undo, redo, layout, zoom).
        public var appActions: [VoiceCommand] = []
        public init() {}
    }

    public static func apply(_ commands: [VoiceCommand], to state: inout DrawingState, measure: @escaping TextMeasurer = approximateMeasurer) -> Outcome {
        var out = Outcome()
        if state.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.spec = state.language == .plantUML ? "@startuml\n\n@enduml\n" : "flowchart TD\n"
        }
        for command in commands {
            let parsed = Engine.reconcile(&state, measure: measure)
            let names = parsed.nodes.map { $0.title }
            func find(_ name: String) -> DiagramNode? {
                NameMatcher.best(name, in: names).flatMap { t in parsed.nodes.first { $0.title == t } }
                    ?? NameMatcher.best(name, in: parsed.nodes.map(\.id)).flatMap { parsed.node($0) }
            }
            func addNode(kind: NodeKind?, name: String) -> String {
                let kind = kind ?? InkCommit.choices(for: .rectangle, rect: Rect(x: 0, y: 0, width: 100, height: 60), family: parsed.family, language: state.language).first ?? .box
                var editor = SpecEditor(spec: state.spec, language: state.language)
                let id = editor.addNode(kind: kind, title: name.capitalizedTitle)
                state.spec = editor.spec
                out.messages.append("Added \(kind.displayName) “\(name.capitalizedTitle)”")
                out.touched.append(.node(id))
                return id
            }
            switch command {
            case let .add(kindName, name):
                let kind = kindName.flatMap { resolveKind($0, family: parsed.family, language: state.language) }
                if kindName != nil && kind == nil {
                    // "add payment service": not a kind after all, it's part of the name.
                    _ = addNode(kind: nil, name: [kindName!, name].joined(separator: " "))
                } else {
                    _ = addNode(kind: kind, name: name)
                }
            case let .connect(a, b, label):
                let from = find(a)?.id ?? addNode(kind: nil, name: a)
                Engine.reconcile(&state, measure: measure)
                let to = find(b)?.id ?? SpecParser.parse(state.spec, language: state.language).nodes.first { $0.title.lowercased() == b.lowercased() }?.id
                    ?? addNode(kind: nil, name: b)
                var editor = SpecEditor(spec: state.spec, language: state.language)
                let before = Set(editor.parsed.edges.map(\.id))
                editor.addEdge(from: from, to: to, label: label)
                state.spec = editor.spec
                if let e = editor.parsed.edges.first(where: { !before.contains($0.id) }) { out.touched.append(.edge(e.id)) }
                out.messages.append("Connected \(editor.parsed.node(from)?.title ?? from) → \(editor.parsed.node(to)?.title ?? to)" + (label.map { ": \($0)" } ?? ""))
            case let .rename(a, b):
                guard let n = find(a) else { out.messages.append("Couldn’t find “\(a)”"); continue }
                let id = Engine.updateNode(&state, id: n.id, NodeEdit(title: b.capitalizedTitle), measure: measure)
                out.touched.append(.node(id))
                out.messages.append("Renamed “\(n.title)” to “\(b.capitalizedTitle)”")
            case let .delete(a):
                guard let n = find(a) else { out.messages.append("Couldn’t find “\(a)”"); continue }
                Engine.delete(&state, [.node(n.id)], measure: measure)
                out.messages.append("Deleted “\(n.title)”")
            case let .changeKind(a, kindName):
                guard let n = find(a) else { out.messages.append("Couldn’t find “\(a)”"); continue }
                guard let kind = resolveKind(kindName, family: parsed.family, language: state.language, current: n.kind) else {
                    out.messages.append("“\(kindName)” isn’t an element type here"); continue
                }
                Engine.updateNode(&state, id: n.id, NodeEdit(kind: kind), measure: measure)
                out.touched.append(.node(n.id))
                out.messages.append("“\(n.title)” is now a \(kind.displayName)")
            case let .note(text):
                let bounds = DiagramGeometry(parsed: parsed, state: state, measure: measure).bounds
                let d = Decoration(kind: .note, frame: Rect(x: (bounds?.maxX ?? 0) + 40, y: bounds?.minY ?? 40, width: 180, height: 90), text: text)
                state.decorations.append(d)
                out.touched.append(.decoration(d.id))
                out.messages.append("Added a note")
            case .undo, .redo, .autoLayout, .zoomToFit:
                out.appActions.append(command)
            }
        }
        Engine.reconcile(&state, measure: measure)
        return out
    }

    /// Maps spoken words ("database", "external system", "user") to an element kind valid in this diagram.
    public static func resolveKind(_ words: String, family: DiagramFamily, language: SpecLanguage, current: NodeKind? = nil) -> NodeKind? {
        let w = words.lowercased().trimmingCharacters(in: .whitespaces)
        var candidates = NodeKind.palette(for: family, language: language)
        if let current { candidates += NodeKind.alternatives(to: current, family: family, language: language) }
        if family == .c4 { candidates += NodeKind.allCases.filter(\.isC4) }
        if let exact = candidates.first(where: { $0.displayName.lowercased() == w }) { return exact }
        let synonyms: [String: [NodeKind]] = [
            "database": [.containerDb, .systemDb, .database, .component4Db], "db": [.containerDb, .database], "table": [.entity],
            "queue": [.containerQueue, .queue, .systemQueue], "user": [.person, .actor], "person": [.person, .actor], "actor": [.actor, .person],
            "people": [.person], "customer": [.person, .actor], "system": [.system, .box], "service": [.container, .component, .box, .participant],
            "app": [.container, .box], "application": [.container, .box], "external system": [.systemExt], "external": [.systemExt, .containerExt],
            "external person": [.personExt], "box": [.box, .container, .participant], "rectangle": [.box], "decision": [.diamond],
            "diamond": [.diamond], "circle": [.circle, .usecase], "class": [.classType], "interface": [.interfaceType],
            "enum": [.enumType], "abstract class": [.abstractClass], "entity": [.entity, .seqEntity], "participant": [.participant],
            "component": [.component4, .component], "container": [.container], "group": [.group, .boundary], "boundary": [.boundary, .seqBoundary],
            "cloud": [.cloud], "use case": [.usecase], "node": [.node], "folder": [.folder],
        ]
        if let options = synonyms[w], let k = options.first(where: candidates.contains) { return k }
        return candidates.first { $0.displayName.lowercased().contains(w) || w.contains($0.displayName.lowercased()) }
    }
}

/// Forgiving matching of spoken names against element titles ("web app" ≈ "Web Application", "orders" ≈ "Order").
public enum NameMatcher {
    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    public static func best(_ spoken: String, in names: [String]) -> String? {
        let s = normalize(spoken)
        guard !s.isEmpty else { return nil }
        if let exact = names.first(where: { normalize($0) == s }) { return exact }
        let stem = { (x: String) in x.hasSuffix("s") ? String(x.dropLast()) : x }
        if let plural = names.first(where: { stem(normalize($0)) == stem(s) }) { return plural }
        if let prefix = names.filter({ normalize($0).hasPrefix(s) || s.hasPrefix(normalize($0)) }).min(by: { $0.count < $1.count }) { return prefix }
        if s.count >= 3, let part = names.filter({ normalize($0).contains(s) }).min(by: { $0.count < $1.count }) { return part }
        let scored = names.map { ($0, distance(normalize($0), s)) }.filter { $0.1 <= max(1, s.count / 4) }
        return scored.min { $0.1 < $1.1 }?.0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let tmp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return row[b.count]
    }
}

extension String {
    /// "orders service" → "Orders Service"; keeps words that already have capitals ("API", "iOS").
    var capitalizedTitle: String {
        split(separator: " ").map { w in w.contains(where: \.isUppercase) ? String(w) : w.prefix(1).uppercased() + w.dropFirst() }.joined(separator: " ")
    }

    func trimmingPrefix(_ p: String) -> String { hasPrefix(p) ? String(dropFirst(p.count)) : self }
}
