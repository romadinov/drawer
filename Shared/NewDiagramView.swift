import SwiftUI
import DrawerCore

/// Asks what kind of diagram a new document is, in which spec language, and whether to start from an example.
struct NewDiagramView: View {
    var onCreate: (_ spec: String, _ language: SpecLanguage) -> Void
    var onCancel: () -> Void
    @AppStorage("newDiagramLanguage") private var language: SpecLanguage = .plantUML
    @State private var withExample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Diagram").font(.title2.bold())
                Text("What would you like to draw? You can sketch it freehand or write the spec — they stay in sync.")
                    .foregroundStyle(.secondary)
            }
            Picker("Spec language", selection: $language) {
                ForEach(SpecLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(DiagramStarter.families, id: \.self) { family in
                    Button { create(family) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: DiagramStarter.symbol(family)).font(.title).foregroundStyle(.tint)
                            Text(family.displayName).font(.headline).foregroundStyle(.primary)
                            Text(DiagramStarter.summary(family)).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .padding(14)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("new-\(family.rawValue)")
                }
            }
            HStack {
                Toggle("Start with an example", isOn: $withExample)
                    .fixedSize()
                Spacer()
                Button("Not now", action: onCancel)
            }
        }
        .padding(24)
        .frame(minWidth: 380, idealWidth: 620)
    }

    private func create(_ family: DiagramFamily) {
        if withExample, let t = DiagramStarter.example(family, language: language) {
            onCreate(t.spec, t.language)
        } else {
            onCreate(DiagramStarter.blankSpec(family, language: language), language)
        }
    }
}

/// The New Diagram chooser shown on the canvas of a new, empty document. It's part of the view rather than
/// a sheet so it can't be lost while the document is still opening, and it goes away by itself if an
/// opened file's contents arrive after all.
struct NewDiagramCard: View {
    @Bindable var document: DrawerDocument
    var onCreate: () -> Void = {}
    @State private var settled = false
    @State private var dismissed = false

    var body: some View {
        ZStack {
            if settled && !dismissed && document.isNewAndEmpty {
                Color.black.opacity(0.08).ignoresSafeArea()
                ScrollView {
                    NewDiagramView { spec, language in
                        document.start(spec: spec, language: language)
                        onCreate()
                    } onCancel: { dismissed = true }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: 660, maxHeight: 640)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                .padding(24)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: settled && !dismissed && document.isNewAndEmpty)
        .task {
            // Give an opened file a moment to arrive so its document doesn't flash the chooser.
            try? await Task.sleep(for: .milliseconds(500))
            settled = true
        }
    }
}

extension DrawerDocument {
    /// Replaces the spec with a new starting point, keeping free-form annotations.
    @MainActor
    func start(spec: String, language: SpecLanguage) {
        change("New Diagram") { state, _ in
            state = DrawingState(language: language, spec: spec, decorations: state.decorations)
        }
        selection = []
    }
}

extension NodeKind {
    /// An SF Symbol for palettes.
    var symbol: String {
        switch self {
        case .person, .personExt, .actor: "person"
        case .database, .systemDb, .systemDbExt, .containerDb, .containerDbExt, .component4Db: "cylinder"
        case .queue, .systemQueue, .containerQueue, .component4Queue: "tray.2"
        case .classType, .abstractClass, .interfaceType, .enumType: "rectangle.split.3x1"
        case .entity: "tablecells"
        case .diamond: "diamond"
        case .circle, .seqEntity, .seqControl, .seqBoundary: "circle"
        case .usecase, .stadium: "capsule"
        case .cloud: "cloud"
        case .folder: "folder"
        case .note: "note.text"
        case .component, .component4, .component4Ext: "shippingbox"
        case .node: "server.rack"
        case .artifact: "doc"
        case .hexagon: "hexagon"
        case .parallelogram: "rectangle.portrait"
        case .collections: "rectangle.stack"
        case .system, .systemExt: "square.stack.3d.up"
        case .container, .containerExt: "macwindow"
        case .group, .boundary: "rectangle.dashed"
        case .rounded: "app"
        default: "rectangle"
        }
    }
}
