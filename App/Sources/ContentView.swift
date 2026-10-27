import SwiftUI
import UniformTypeIdentifiers
import DrawerCore

struct ContentView: View {
    @Bindable var document: DrawerDocument
    @Environment(\.undoManager) private var undoManager
    @State private var tool: Tool = .select
    @State private var zoom: CGFloat = 1
    @State private var fitRequest = 0
    @State private var showTemplates = false
    @State private var showInspector = true
    @State private var showSpec = true

    var body: some View {
        HSplitView {
            if showSpec {
                specPane
                    .frame(minWidth: 260, idealWidth: 380, maxWidth: 700)
            }
            CanvasView(document: document, revision: document.revision, selection: document.selection,
                       tool: $tool, zoom: $zoom, undoManager: undoManager, fitRequest: fitRequest)
                .frame(minWidth: 400)
                .overlay(alignment: .bottomTrailing) { zoomControls.padding(10) }
            if showInspector {
                InspectorView(document: document)
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 360)
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { template in
                document.applyTemplate(template)
                showTemplates = false
                fitSoon()
            } onCancel: { showTemplates = false }
        }
        .onAppear {
            document.undoManager = undoManager
            if document.isEmpty { showTemplates = true }
        }
        .focusedSceneValue(\.drawerDocument, document)
    }

    private func fitSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fitRequest += 1 }
    }

    // MARK: Spec pane

    private var specPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Language", selection: Binding(get: { document.state.language }, set: { document.setLanguage($0) })) {
                    ForEach(SpecLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
                .help("Language the spec is written in")
                Text(document.parsed.family.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(SpecLanguage.allCases.filter { $0 != document.state.language }) { lang in
                        Button("Convert to \(lang.displayName)") { document.convert(to: lang) }
                    }
                    Divider()
                    Button("Import Spec…") { importSpec() }
                    Button("Export Spec…") { exportSpec() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            SpecEditorView(document: document, revision: document.revision, selection: document.selection)
            Divider()
            diagnosticsBar
        }
    }

    private var diagnosticsBar: some View {
        let diags = document.parsed.diagnostics
        return Group {
            if diags.isEmpty {
                Label("\(document.parsed.nodes.filter { !$0.kind.isGroup }.count) elements · \(document.parsed.edges.count) relationships",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(diags.enumerated()), id: \.offset) { _, d in
                            Label("Line \(d.line): \(d.message)", systemImage: d.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .foregroundStyle(d.severity == .error ? .red : .orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { zoom = max(0.1, zoom / 1.25) } label: { Image(systemName: "minus") }
            Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 44)
            Button { zoom = min(5, zoom * 1.25) } label: { Image(systemName: "plus") }
            Button { fitRequest += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to fit")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showSpec.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Show or hide the spec editor")
        }
        ToolbarItemGroup(placement: .principal) {
            Picker("Tool", selection: $tool) {
                Image(systemName: "cursorarrow").tag(Tool.select).help("Select & move (V)")
                Image(systemName: "arrow.up.right").tag(Tool.connect).help("Connect elements (C) — or ⌥-drag from an element")
            }
            .pickerStyle(.segmented)

            Menu {
                let family = document.parsed.family
                let lang = document.state.language
                Section(family.displayName) {
                    ForEach(NodeKind.palette(for: family, language: lang), id: \.self) { kind in
                        Button(kind.displayName) { tool = .node(kind) }
                    }
                }
                if lang == .plantUML && family != .sequence {
                    ForEach(DiagramFamily.allCases.filter { $0 != family && $0 != .sequence }, id: \.self) { other in
                        Menu(other.displayName) {
                            ForEach(NodeKind.palette(for: other, language: lang), id: \.self) { kind in
                                Button(kind.displayName) { tool = .node(kind) }
                            }
                        }
                    }
                }
                if family != .sequence {
                    Divider()
                    Button(family == .c4 ? "Boundary" : "Group") { tool = .node(family == .c4 ? .boundary : .group) }
                }
            } label: {
                Label(addLabel, systemImage: "plus.square.on.square")
            }
            .help("Add an element to the spec, then click on the canvas")

            Menu {
                Button { tool = .decoration(.text) } label: { Label("Text", systemImage: "textformat") }
                Button { tool = .decoration(.note) } label: { Label("Sticky Note", systemImage: "note.text") }
                Button { tool = .decoration(.rectangle) } label: { Label("Rectangle", systemImage: "rectangle") }
                Button { tool = .decoration(.roundedRectangle) } label: { Label("Rounded Rectangle", systemImage: "app") }
                Button { tool = .decoration(.ellipse) } label: { Label("Ellipse", systemImage: "circle") }
                Button { tool = .decoration(.line) } label: { Label("Line", systemImage: "line.diagonal") }
                Button { tool = .decoration(.arrow) } label: { Label("Arrow", systemImage: "arrow.up.right") }
            } label: {
                Label("Annotate", systemImage: "pencil.and.scribble")
            }
            .help("Drawing-only embellishments (not part of the spec)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { document.autoLayout(); fitSoon() } label: { Label("Auto Layout", systemImage: "wand.and.stars") }
                .help("Re-arrange all elements automatically")
            Button { showTemplates = true } label: { Label("Templates", systemImage: "square.grid.2x2") }
                .help("Start from a template")
            Menu {
                Button("Export PNG…") { Exporter.exportImage(document, format: .png) }
                Button("Export PDF…") { Exporter.exportImage(document, format: .pdf) }
                Divider()
                Button("Copy as PNG") { Exporter.copyPNG(document) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }

    private var addLabel: String {
        if case let .node(kind) = tool { return kind.displayName }
        return "Add"
    }

    // MARK: Spec import / export

    private func importSpec() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plantUMLSource, .mermaidSource, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let language: SpecLanguage = url.pathExtension == "mmd" ? .mermaid : (url.pathExtension == "puml" ? .plantUML : SpecParser.detectLanguage(text))
        document.replaceSpec(text, language: language)
        fitSoon()
    }

    private func exportSpec() {
        let panel = NSSavePanel()
        let lang = document.state.language
        panel.allowedContentTypes = [lang == .plantUML ? .plantUMLSource : .mermaidSource]
        panel.nameFieldStringValue = "diagram.\(lang.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? document.state.spec.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Focused value for menu commands

struct DrawerDocumentKey: FocusedValueKey { typealias Value = DrawerDocument }
extension FocusedValues {
    var drawerDocument: DrawerDocument? {
        get { self[DrawerDocumentKey.self] }
        set { self[DrawerDocumentKey.self] = newValue }
    }
}

// MARK: - Templates

struct TemplatePicker: View {
    var onPick: (DiagramTemplate) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start a Diagram").font(.title2.bold())
            Text("Pick a starting point. You can edit the spec and the drawing side by side at any time.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(DiagramTemplate.all) { t in
                    Button { onPick(t) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: t.symbol).font(.title2).foregroundStyle(.tint)
                            Text(t.name).font(.headline)
                            Text(t.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                            Text(t.language.displayName).font(.caption2.bold()).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}
