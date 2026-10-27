import SwiftUI
import UniformTypeIdentifiers
import DrawerCore

extension UTType {
    static let drawerDiagram = UTType(exportedAs: "com.romadinov.drawer.diagram")
    static let plantUMLSource = UTType(filenameExtension: "puml") ?? .plainText
    static let mermaidSource = UTType(filenameExtension: "mmd") ?? .plainText
}

enum SelectionOrigin { case canvas, editor }

@Observable
final class DrawerDocument: Document {
    static let readableContentTypes: [UTType] = [.drawerDiagram]

    private(set) var state: DrawingState
    private(set) var parsed: ParsedDiagram = .empty
    /// Bumped on every change so AppKit views know to redraw.
    private(set) var revision = 0

    var selection: Set<ElementRef> = []
    var selectionOrigin: SelectionOrigin = .canvas
    /// Set when a node should immediately get an inline title editor (after creation from the palette).
    var pendingInlineEdit: ElementRef?

    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private var typingBase: DrawingState?
    @ObservationIgnored private var typingTimer: Timer?

    init(state: DrawingState = DrawingState(language: .plantUML, spec: "")) {
        self.state = state
        parsed = Engine.reconcile(&self.state, measure: appMeasurer)
    }

    var isEmpty: Bool { state.spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.decorations.isEmpty }

    // MARK: Document

    func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<DrawingState> {
        FileWrapperDocumentReader(configuration) { fileWrapper in
            guard let data = fileWrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(DrawingState.self, from: data)
        }
    }

    @MainActor
    func apply(snapshot: sending DrawingState, previous: sending DrawingState?) async throws {
        var s = snapshot
        parsed = Engine.reconcile(&s, measure: appMeasurer)
        state = s
        revision += 1
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<DrawingState> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending DrawingState {
        state
    }

    // MARK: Changes (all undoable)

    /// Applies a change to the state as one undoable step.
    @MainActor
    func change(_ actionName: String, _ body: (inout DrawingState, ParsedDiagram) -> Void) {
        endTyping()
        var new = state
        body(&new, parsed)
        let newParsed = Engine.reconcile(&new, measure: appMeasurer)
        guard new != state else { return }
        let old = state
        commit(new, parsed: newParsed)
        registerUndo(restoring: old, name: actionName)
    }

    @MainActor
    private func commit(_ new: DrawingState, parsed newParsed: ParsedDiagram) {
        state = new
        parsed = newParsed
        let valid = Set(newParsed.nodes.map(\.id))
        let validEdges = Set(newParsed.edges.map(\.id))
        let validDecorations = Set(new.decorations.map(\.id))
        let filtered = selection.filter {
            switch $0 {
            case let .node(id): valid.contains(id)
            case let .edge(id): validEdges.contains(id)
            case let .decoration(id): validDecorations.contains(id)
            }
        }
        if filtered != selection { selection = filtered }
        revision += 1
    }

    @MainActor
    private func registerUndo(restoring old: DrawingState, name: String) {
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.restore(old, name: name) }
        }
        undoManager?.setActionName(name)
    }

    @MainActor
    private func restore(_ s: DrawingState, name: String) {
        endTyping()
        let current = state
        var copy = s
        let p = Engine.reconcile(&copy, measure: appMeasurer)
        commit(copy, parsed: p)
        registerUndo(restoring: current, name: name)
    }

    /// Text typed in the spec editor. Keystrokes are coalesced into one undo step per pause.
    @MainActor
    func specTextChanged(_ text: String) {
        guard text != state.spec else { return }
        if typingBase == nil {
            typingBase = state
            registerUndo(restoring: state, name: "Typing")
        }
        var new = state
        new.spec = text
        let p = Engine.reconcile(&new, measure: appMeasurer)
        commit(new, parsed: p)
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTyping() }
        }
    }

    @MainActor
    private func endTyping() {
        typingTimer?.invalidate()
        typingTimer = nil
        typingBase = nil
    }

    // MARK: Convenience operations

    @MainActor
    func addNode(kind: NodeKind, at point: Point, parent: String?) {
        var newID = ""
        change("Add \(kind.displayName)") { state, _ in
            newID = Engine.addNode(&state, kind: kind, title: kind.isGroup ? "Group" : "New \(kind.displayName)", at: point, parent: parent, measure: appMeasurer)
        }
        if !newID.isEmpty {
            selection = [.node(newID)]
            selectionOrigin = .canvas
            pendingInlineEdit = .node(newID)
        }
    }

    @MainActor
    func connect(_ from: String, _ to: String, before: String? = nil) {
        let existing = Set(parsed.edges.map(\.id))
        change(parsed.family == .sequence ? "Add Message" : "Connect") { state, _ in
            Engine.addEdge(&state, from: from, to: to, before: before, measure: appMeasurer)
        }
        let id = parsed.edges.first(where: { $0.from == from && $0.to == to && !existing.contains($0.id) })?.id
            ?? parsed.edges.last(where: { $0.from == from && $0.to == to })?.id
        if let id { selection = [.edge(id)] }
    }

    @MainActor
    func deleteSelection() {
        let sel = selection
        guard !sel.isEmpty else { return }
        change("Delete") { state, _ in Engine.delete(&state, sel, measure: appMeasurer) }
        selection = []
    }

    @MainActor
    func updateNode(_ id: String, _ edit: NodeEdit) {
        var newID = id
        change("Edit \(parsed.node(id)?.kind.displayName ?? "Element")") { state, _ in
            newID = Engine.updateNode(&state, id: id, edit, measure: appMeasurer)
        }
        if newID != id, selection.contains(.node(id)) {
            selection.remove(.node(id))
            selection.insert(.node(newID))
        }
    }

    @MainActor
    func updateEdge(_ id: String, _ edit: EdgeEdit) {
        let before = parsed.edge(id)
        change("Edit Connection") { state, _ in Engine.updateEdge(&state, id: id, edit, measure: appMeasurer) }
        if parsed.edge(id) == nil, let before {
            // Reversing or re-emitting can change the id; keep the edge selected.
            let from = edit.reverse ? before.to : before.from
            let to = edit.reverse ? before.from : before.to
            if let e = parsed.edges.last(where: { $0.from == from && $0.to == to }) { selection = [.edge(e.id)] }
        }
    }

    @MainActor
    func setStyle(_ key: String, _ body: (inout ElementStyle) -> Void) {
        change("Change Style") { state, _ in
            var style = state.styles[key] ?? ElementStyle()
            body(&style)
            state.styles[key] = style.isEmpty ? nil : style
        }
    }

    @MainActor
    func autoLayout() {
        change("Auto Layout") { state, parsed in Engine.autoLayout(&state, parsed: parsed, measure: appMeasurer) }
    }

    @MainActor
    func applyTemplate(_ template: DiagramTemplate) {
        change("Use Template") { state, _ in
            state = DrawingState(language: template.language, spec: template.spec, decorations: state.decorations)
        }
        selection = []
    }

    @MainActor
    func replaceSpec(_ text: String, language: SpecLanguage) {
        change("Import Spec") { state, _ in
            state.language = language
            state.spec = text
        }
    }

    @MainActor
    func convert(to language: SpecLanguage) {
        change("Convert to \(language.displayName)") { state, parsed in
            Engine.convert(&state, to: language, parsed: parsed)
        }
    }

    @MainActor
    func setLanguage(_ language: SpecLanguage) {
        change("Change Language") { state, _ in state.language = language }
    }
}
