import SwiftUI
import DrawerCore

@main
struct DrawerApp: App {
    init() {
        // Headless export: Drawer --export input.drawer output.png|pdf
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export"), args.count > i + 2 {
            MainActor.assumeIsolated { HeadlessExport.run(input: args[i + 1], output: args[i + 2]) }
        }
        if let i = args.firstIndex(of: "--ink"), args.count > i + 2 {
            MainActor.assumeIsolated { HeadlessExport.recognizeInk(input: args[i + 1], output: args[i + 2]) }
        }
    }

    var body: some Scene {
        DocumentGroup { document in
            ContentView(document: document)
                .frame(minWidth: 1000, minHeight: 600)
        } makeDocument: { _, _ in
            DrawerDocument()
        }
        .commands {
            DiagramCommands()
        }
    }
}

struct DiagramCommands: Commands {
    @FocusedValue(\.drawerDocument) private var document

    var body: some Commands {
        CommandMenu("Diagram") {
            Button("Auto Layout") { document?.autoLayout() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(document == nil)
            Divider()
            Button("Export PNG…") { if let d = document { Exporter.exportImage(d, format: .png) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(document == nil)
            Button("Export PDF…") { if let d = document { Exporter.exportImage(d, format: .pdf) } }
                .disabled(document == nil)
            Button("Copy as PNG") { if let d = document { Exporter.copyPNG(d) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(document == nil)
        }
    }
}
