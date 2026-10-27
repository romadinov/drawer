import SwiftUI
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

    private var sideBySide: Bool { sizeClass == .regular }

    var body: some View {
        HStack(spacing: 0) {
            if sideBySide && showSpec {
                SpecPane(document: document)
                    .frame(width: 360)
                Divider()
            }
            MobileCanvas(document: document, revision: document.revision, selection: document.selection,
                         tool: tool, handle: handle) { beginEdit($0) }
                .ignoresSafeArea(edges: .bottom)
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
        .alert(editTitle, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("OK") { commitEdit() }
        }
        .onAppear {
            document.undoManager = undoManager
            if document.isEmpty { tool = .draw }
        }
        .onChange(of: undoManager) { document.undoManager = undoManager }
    }

    private func fitSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handle.zoomToFit() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { showSpec.toggle() } label: { Label("Spec", systemImage: "doc.plaintext") }
            Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(undoManager?.canUndo != true)
            Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(undoManager?.canRedo != true)
        }
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $tool) {
                Label("Select", systemImage: "hand.point.up.left").tag(MobileTool.select)
                Label("Draw", systemImage: "pencil.and.outline").tag(MobileTool.draw)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .frame(width: 120)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                let family = document.parsed.family
                ForEach(NodeKind.palette(for: family, language: document.state.language), id: \.self) { kind in
                    Button(kind.displayName) { document.addNode(kind: kind, at: handle.visibleCenter, parent: nil) }
                }
                if family != .sequence {
                    Divider()
                    Button(family == .c4 ? "Boundary" : "Group") {
                        document.addNode(kind: family == .c4 ? .boundary : .group, at: handle.visibleCenter, parent: nil)
                    }
                }
                Divider()
                Button { addDecoration(.note, text: "Note") } label: { Label("Sticky Note", systemImage: "note.text") }
                Button { addDecoration(.text, text: "Text") } label: { Label("Text", systemImage: "textformat") }
            } label: {
                Label("Add", systemImage: "plus")
            }
            Menu {
                Button { document.autoLayout(); fitSoon() } label: { Label("Auto Layout", systemImage: "wand.and.stars") }
                Button { handle.zoomToFit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { showTemplates = true } label: { Label("Templates", systemImage: "square.grid.2x2") }
                Menu("Convert To") {
                    ForEach(SpecLanguage.allCases.filter { $0 != document.state.language }) { lang in
                        Button(lang.displayName) { document.convert(to: lang) }
                    }
                }
                Divider()
                Button { if let url = MobileExporter.pngURL(document) { shareURL = ShareItem(url: url) } } label: {
                    Label("Share as PNG", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
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
        if !document.selection.isEmpty {
            HStack(spacing: 16) {
                Text(selectionTitle).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if document.selection.count == 1, let ref = document.selection.first {
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
        case let .node(id): editText = document.parsed.node(id)?.title ?? ""
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
            TextEditor(text: Binding(get: { document.state.spec }, set: { document.specTextChanged($0) }))
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
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
    static func pngURL(_ doc: DrawerDocument) -> URL? {
        guard let b = DiagramGeometry(parsed: doc.parsed, state: doc.state, measure: appMeasurer).bounds else { return nil }
        let rect = CGRect(b).insetBy(dx: -30, dy: -30).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let data = UIGraphicsImageRenderer(size: rect.size, format: format).pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                DiagramRenderer(parsed: doc.parsed, state: doc.state).draw()
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((doc.parsed.title ?? "Diagram") + ".png")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
