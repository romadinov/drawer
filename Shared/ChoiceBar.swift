import SwiftUI
import DrawerCore

/// Asks what a just-recognised shape is when it could be several kinds of element. Shown in a popover
/// pointing at the element; the best guess is already applied, so carrying on drawing keeps it.
struct ChoicePrompt: View {
    @Bindable var document: DrawerDocument

    var body: some View {
        if let choice = document.currentChoice, let node = document.parsed.node(choice.id) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What is “\(node.title)”?").font(.headline).padding(.bottom, 4)
                ForEach(choice.options, id: \.self) { kind in
                    Button { document.resolveChoice(kind) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbol).frame(width: 22)
                            Text(kind.displayName)
                            Spacer()
                            if kind == node.kind { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background(kind == node.kind ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Carry on drawing to keep \(node.kind.displayName).")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(14)
            .frame(width: 270)
        }
    }
}

/// "Change Type" for an element, offering the kinds that are valid in its diagram.
struct KindMenu: View {
    @Bindable var document: DrawerDocument
    let id: String

    var body: some View {
        if let node = document.parsed.node(id) {
            let options = NodeKind.alternatives(to: node.kind, family: document.parsed.family, language: document.state.language)
            if options.count > 1 {
                Menu {
                    ForEach(options, id: \.self) { kind in
                        Button { document.updateNode(id, NodeEdit(kind: kind)) } label: {
                            if kind == node.kind { Label(kind.displayName, systemImage: "checkmark") } else { Text(kind.displayName) }
                        }
                    }
                } label: {
                    Label(node.kind.displayName, systemImage: "square.on.circle")
                }
            }
        }
    }
}
