import SwiftUI
import DrawerCore

/// Asks what a just-recognised shape is when it could be several kinds of element.
/// The best guess is already applied, so it never blocks drawing; picking another option switches it.
struct ChoiceBar: View {
    @Bindable var document: DrawerDocument

    var body: some View {
        if let choice = document.currentChoice, let node = document.parsed.node(choice.id) {
            HStack(spacing: 8) {
                Text("What is “\(node.title)”?")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(choice.options, id: \.self) { kind in
                            Button(kind.displayName) { document.resolveChoice(kind) }
                                .buttonStyle(.bordered)
                                .tint(kind == node.kind ? .accentColor : nil)
                                .fontWeight(kind == node.kind ? .semibold : .regular)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                let remaining = document.pendingChoices.filter { document.parsed.node($0.id) != nil }.count
                if remaining > 1 {
                    Text("+\(remaining - 1)").font(.caption).foregroundStyle(.secondary)
                }
                Button { document.dismissChoices() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Keep the guesses")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .frame(maxWidth: 720)
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
