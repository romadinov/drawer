import SwiftUI
import UniformTypeIdentifiers
import DrawerCore

struct MobileContentView: View {
    @Bindable var document: DrawerDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tool: MobileTool = .select
    @State private var showSpec = false
    @State private var showTemplates = false
    @State private var handle = CanvasHandle()
    @State private var editing: ElementRef?
    @State private var editText = ""
    @State private var shareURL: ShareItem?
    @State private var showNewDiagram = false
    @State private var showAdd = false
    @State private var voice = VoiceControl()

    private var sideBySide: Bool { sizeClass == .regular }

    var body: some View {
        HStack(spacing: 0) {
            if sideBySide && showSpec {
                SpecPane(document: document)
                    .frame(width: 360)
                Divider()
            }
            MobileCanvas(document: document, revision: document.revision, selection: document.selection,
                         choice: document.currentChoice?.id, editing: editing, tool: tool, handle: handle, onEdit: { beginEdit($0) }, onToolChange: { tool = $0 })
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .leading) { palette.padding(.leading, 12) }
                .overlay(alignment: .top) { VoiceOverlay(voice: voice).allowsHitTesting(voice.isListening) }
        }
        .toolbar { toolbar }
        .toolbarRole(.editor)
        .safeAreaInset(edge: .bottom) { selectionBar }
        .sheet(isPresented: Binding(get: { showSpec && !sideBySide }, set: { showSpec = $0 })) {
            NavigationStack {
                SpecPane(document: document)
                    .navigationTitle("Spec")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showSpec = false } }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $showTemplates) {
            TemplateList { template in
                document.applyTemplate(template)
                showTemplates = false
                fitSoon()
            }
        }
        .sheet(item: $shareURL) { ActivityView(items: [$0.url]) }
        .sheet(isPresented: $showNewDiagram) {
            ScrollView {
                NewDiagramView { spec, language in
                    document.start(spec: spec, language: language)
                    showNewDiagram = false
                    tool = .draw
                    fitSoon()
                } onCancel: { showNewDiagram = false }
            }
        }
        .alert(editTitle, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("OK") { commitEdit() }
        }
        .onAppear {
            voice.document = document
            voice.onAppAction = { action in
                switch action {
                case .undo: undoManager?.undo()
                case .redo: undoManager?.redo()
                case .autoLayout: document.autoLayout(); fitSoon()
                case .zoomToFit: handle.zoomToFit()
                default: break
                }
            }
            document.undoManager = undoManager
            if document.isEmpty { showNewDiagram = true }
        }
        .onChange(of: undoManager) { document.undoManager = undoManager }
        .onChange(of: document.pendingInlineEdit) {
            if let r = document.pendingInlineEdit { document.pendingInlineEdit = nil; beginEdit(r) }
        }
    }

    private func fitSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handle.zoomToFit() }
    }

    // MARK: Toolbar

    // MARK: Tool palette

    /// Floating tools on the canvas edge (the title bar belongs to the document name on iPadOS).
    private var palette: some View {
        VStack(spacing: 2) {
            toolButton(.select, "hand.point.up.left", "Select and move")
            toolButton(.draw, "pencil", "Draw shapes, arrows and text")
            toolButton(.erase, "eraser", "Erase")
            Divider().frame(width: 30).padding(.vertical, 4)
            paletteButton("plus", "Add an element") { showAdd = true }
                .popover(isPresented: $showAdd) { addPalette }
            paletteButton("doc.plaintext", showSpec ? "Hide spec" : "Show spec", active: showSpec) { showSpec.toggle() }
            paletteButton(voice.isListening ? "mic.fill" : "mic", "Speak a command", active: voice.isListening) { voice.toggle() }
            Divider().frame(width: 30).padding(.vertical, 4)
            paletteButton("arrow.uturn.backward", "Undo") { undoManager?.undo() }
                .disabled(undoManager?.canUndo != true)
            paletteButton("arrow.uturn.forward", "Redo") { undoManager?.redo() }
                .disabled(undoManager?.canRedo != true)
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private func toolButton(_ t: MobileTool, _ symbol: String, _ help: String) -> some View {
        paletteButton(symbol, help, active: tool == t) { tool = t }
    }

    private func paletteButton(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 46, height: 46)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }

    /// Elements of the current diagram type, plus annotations.
    private var addPalette: some View {
        let family = document.parsed.family
        var kinds = NodeKind.palette(for: family, language: document.state.language)
        if family != .sequence { kinds.append(family == .c4 ? .boundary : .group) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add to \(family.displayName)").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(kinds, id: \.self) { kind in
                        addTile(kind.displayName, kind.symbol) {
                            document.addNode(kind: kind, at: handle.visibleCenter, parent: nil)
                            if let r = document.pendingInlineEdit { document.pendingInlineEdit = nil; beginEdit(r) }
                        }
                    }
                    addTile("Sticky Note", "note.text") { addDecoration(.note, text: "Note") }
                    addTile("Text", "textformat") { addDecoration(.text, text: "Text") }
                }
                Text("Tip: you can also just draw it — a box, circle, diamond, stick figure or arrow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 350, height: 520)
        .presentationCompactAdaptation(.popover)
    }

    private func addTile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            showAdd = false
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { document.autoLayout(); fitSoon() } label: { Label("Auto Layout", systemImage: "wand.and.stars") }
                Button { handle.zoomToFit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { showNewDiagram = true } label: { Label("Diagram Type…", systemImage: "square.grid.2x2") }
                Button { showTemplates = true } label: { Label("Examples", systemImage: "books.vertical") }
                Menu("Convert To") {
                    ForEach(SpecLanguage.allCases.filter { $0 != document.state.language }) { lang in
                        Button(lang.displayName) { document.convert(to: lang) }
                    }
                }
                Divider()
                Button { MobileExporter.copy(document) } label: { Label("Copy as Image", systemImage: "doc.on.doc") }
                Button { paste() } label: { Label("Paste Diagram", systemImage: "doc.on.clipboard") }
                Button {
                    document.selection = Set(document.parsed.nodes.map { .node($0.id) } + document.parsed.edges.map { .edge($0.id) }
                                             + document.state.decorations.map { .decoration($0.id) })
                } label: { Label("Select All", systemImage: "checkmark.circle") }
                Divider()
                Button { share(.png) } label: { Label("Share PNG (editable)", systemImage: "photo") }
                Button { share(.svg) } label: { Label("Share SVG (editable)", systemImage: "square.and.arrow.up") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func share(_ type: UTType) {
        if let url = MobileExporter.fileURL(document, type: type) { shareURL = ShareItem(url: url) }
    }

    private func paste() {
        guard let diagram = MobileExporter.pastedDiagram() else { return }
        document.paste(diagram)
        fitSoon()
    }

    private func addDecoration(_ kind: Decoration.Kind, text: String) {
        let c = handle.visibleCenter
        let size = kind == .note ? Size(width: 160, height: 90) : Size(width: 140, height: 26)
        let d = Decoration(kind: kind, frame: Rect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height), text: text)
        document.change("Add \(kind == .note ? "Note" : "Text")") { state, _ in state.decorations.append(d) }
        document.selection = [.decoration(d.id)]
        beginEdit(.decoration(d.id))
    }

    // MARK: Selection

    @ViewBuilder
    private var selectionBar: some View {
        plainSelectionBar
    }

    @ViewBuilder
    private var plainSelectionBar: some View {
        if !document.selection.isEmpty {
            HStack(spacing: 16) {
                Text(selectionTitle).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if document.selection.count == 1, let ref = document.selection.first {
                    if case let .node(id) = ref { KindMenu(document: document, id: id) }
                    Button("Rename") { beginEdit(ref) }
                }
                Button(role: .destructive) { document.deleteSelection() } label: { Image(systemName: "trash") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var selectionTitle: String {
        guard document.selection.count == 1, let ref = document.selection.first else { return "\(document.selection.count) selected" }
        switch ref {
        case let .node(id):
            let n = document.parsed.node(id)
            return "\(n?.kind.displayName ?? "Element"): \(n?.title ?? id)"
        case let .edge(id):
            let e = document.parsed.edge(id)
            return "\(e?.from ?? "") → \(e?.to ?? "")" + (e?.label.map { ": \($0)" } ?? "")
        case let .decoration(id):
            return document.state.decorations.first { $0.id == id }.map { $0.text.isEmpty ? "Drawing" : $0.text } ?? "Drawing"
        }
    }

    private var editTitle: String {
        switch editing {
        case .edge: "Label"
        case .decoration: "Text"
        default: "Name"
        }
    }

    private func beginEdit(_ ref: ElementRef) {
        switch ref {
        case let .node(id):
            // A placeholder name ("Software System") starts empty so you can just type.
            let n = document.parsed.node(id)
            editText = n.map { $0.title == $0.kind.displayName || $0.title == "Person" ? "" : $0.title } ?? ""
        case let .edge(id): editText = document.parsed.edge(id)?.label ?? ""
        case let .decoration(id):
            guard let d = document.state.decorations.first(where: { $0.id == id }), d.kind != .ink else { return }
            editText = d.text
        }
        editing = ref
    }

    private func commitEdit() {
        guard let ref = editing else { return }
        editing = nil
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ref {
        case let .node(id):
            if !text.isEmpty { document.updateNode(id, NodeEdit(title: text)) }
        case let .edge(id):
            document.updateEdge(id, EdgeEdit(label: .some(text.isEmpty ? nil : text)))
        case let .decoration(id):
            document.change("Edit Text") { state, _ in
                if let i = state.decorations.firstIndex(where: { $0.id == id }) { state.decorations[i].text = text }
            }
        }
    }
}

/// The spec text, editable in parallel with the drawing.
struct SpecPane: View {
    @Bindable var document: DrawerDocument
    @State private var selection: TextSelection?

    private var cursor: Int? {
        guard case let .selection(range)? = selection?.indices, range.isEmpty else { return nil }
        let spec = document.state.spec
        guard range.lowerBound <= spec.endIndex else { return nil }
        return spec.utf16.distance(from: spec.startIndex, to: range.lowerBound)
    }

    private var suggestions: SpecCompleter.Suggestions? {
        guard let cursor else { return nil }
        let s = SpecCompleter.suggestions(spec: document.state.spec, language: document.state.language, cursor: cursor)
        return s.items.isEmpty || s.range.length == 0 ? nil : s
    }

    private func accept(_ item: String, _ s: SpecCompleter.Suggestions) {
        let new = (document.state.spec as NSString).replacingCharacters(in: s.range, with: item)
        document.specTextChanged(new)
        let offset = s.range.location + (item as NSString).length
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: offset, in: new))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Language", selection: Binding(get: { document.state.language }, set: { document.setLanguage($0) })) {
                    ForEach(SpecLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text(document.parsed.family.displayName).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            TextEditor(text: Binding(get: { document.state.spec }, set: { document.specTextChanged($0) }), selection: $selection)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
            if let s = suggestions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(s.items.prefix(12), id: \.self) { item in
                            Button(item) { accept(item, s) }
                                .font(.system(.footnote, design: .monospaced))
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.vertical, 6)
                .background(.bar)
            }
            if let d = document.parsed.diagnostics.first {
                Label("Line \(d.line): \(d.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

struct TemplateList: View {
    var onPick: (DiagramTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(DiagramTemplate.all) { t in
                Button { onPick(t) } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(t.name)
                            Text(t.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: t.symbol) }
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

@MainActor
enum MobileExporter {
    /// A temporary PNG/SVG file with the editable diagram embedded, for the share sheet.
    static func fileURL(_ doc: DrawerDocument, type: UTType) -> URL? {
        guard let data = DiagramExport.fileContents(doc.state, as: type) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent((doc.parsed.title ?? "Diagram") + "." + (type.preferredFilenameExtension ?? "png"))
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// The selection (or whole diagram) as an image other apps can paste, plus the diagram itself for Drawer.
    static func copy(_ doc: DrawerDocument) {
        let part = DiagramClipboard.subset(doc.state, parsed: doc.parsed, selection: doc.selection)
        var item: [String: Any] = [UTType.drawerDiagram.identifier: EmbeddedDiagram.json(part)]
        if let png = DiagramExport.png(part) { item[UTType.png.identifier] = png }
        if let svg = DiagramExport.svg(part) { item[UTType.svg.identifier] = svg }
        UIPasteboard.general.setItems([item])
    }

    static func pastedDiagram() -> DrawingState? {
        let pb = UIPasteboard.general
        for type in [UTType.drawerDiagram, .png, .svg] {
            if let data = pb.data(forPasteboardType: type.identifier), let state = EmbeddedDiagram.decode(data) { return state }
        }
        return nil
    }
}
