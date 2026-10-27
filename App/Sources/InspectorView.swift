import SwiftUI
import DrawerCore

/// Properties of the selected element. Semantic fields write to the spec; style fields only touch the drawing.
struct InspectorView: View {
    @Bindable var document: DrawerDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if document.selection.count == 1, let ref = document.selection.first {
                    switch ref {
                    case let .node(id):
                        if let node = document.parsed.node(id) { NodeInspector(document: document, node: node).id(id + "\(document.revision)") }
                    case let .edge(id):
                        if let edge = document.parsed.edge(id) { EdgeInspector(document: document, edge: edge).id(id + "\(document.revision)") }
                    case let .decoration(id):
                        if let d = document.state.decorations.first(where: { $0.id == id }) { DecorationInspector(document: document, decoration: d) }
                    }
                } else if document.selection.count > 1 {
                    Text("\(document.selection.count) items selected").font(.headline)
                    Text("Drag to move them together, or press ⌫ to delete.").font(.caption).foregroundStyle(.secondary)
                } else {
                    DiagramInfo(document: document)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary) }
}

private struct DiagramInfo: View {
    let document: DrawerDocument
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(document.parsed.title ?? "Diagram").font(.headline)
            LabeledContent("Type", value: document.parsed.family.displayName)
            LabeledContent("Spec", value: document.state.language.displayName)
            LabeledContent("Elements", value: "\(document.parsed.nodes.count)")
            LabeledContent("Relationships", value: "\(document.parsed.edges.count)")
            LabeledContent("Annotations", value: "\(document.state.decorations.count)")
            Divider()
            SectionTitle("Tips")
            VStack(alignment: .leading, spacing: 6) {
                tip("Edit the spec on the left or the drawing — both stay in sync.")
                tip("Double-click an element or connection to rename it.")
                tip("⌥-drag from one element to another to connect them.")
                tip("Drag a connection's line to bend it; double-click a bend to remove it.")
                tip("Sequence: drag a lifeline sideways, drag a message up or down to space it, ⌥-drag between lifelines to insert a message there.")
                tip("Space-drag or two-finger scroll to pan, pinch or ⌘-scroll to zoom.")
                tip("Positions, colours and annotations live in the drawing, not the spec.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
    private func tip(_ s: String) -> some View { Label(s, systemImage: "lightbulb").labelStyle(.titleAndIcon) }
}

private struct NodeInspector: View {
    let document: DrawerDocument
    let node: DiagramNode
    @State private var title = ""
    @State private var stereotype = ""
    @State private var technology = ""
    @State private var descriptionText = ""
    @State private var fields = ""
    @State private var methods = ""

    private var family: DiagramFamily { document.parsed.family }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(node.kind.displayName).font(.headline)
                Spacer()
                Text(node.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            SectionTitle("Spec")
            TextField("Title", text: $title).onSubmit(commitTitle)

            let kinds = NodeKind.alternatives(to: node.kind, family: family, language: document.state.language)
            if kinds.count > 1 {
                Picker(node.kind.isC4 || node.kind.isClassifier ? "Kind" : "Shape",
                       selection: Binding(get: { node.kind }, set: { document.updateNode(node.id, NodeEdit(kind: $0)) })) {
                    ForEach(kinds, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            if node.kind.isC4 {
                if ![.person, .personExt, .system, .systemExt, .systemDb, .systemDbExt, .systemQueue].contains(node.kind) {
                    TextField("Technology", text: $technology).onSubmit { document.updateNode(node.id, NodeEdit(technology: .some(nilIfEmpty(technology)))) }
                }
                TextField("Description", text: $descriptionText, axis: .vertical)
                    .lineLimit(2...6)
                    .onSubmit { document.updateNode(node.id, NodeEdit(description: .some(nilIfEmpty(descriptionText)))) }
            } else if !node.kind.isGroup && document.state.language == .plantUML && family != .c4 {
                TextField("Stereotype", text: $stereotype).onSubmit { document.updateNode(node.id, NodeEdit(stereotype: .some(nilIfEmpty(stereotype)))) }
            }

            if node.kind.isClassifier || node.kind == .entity {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.kind == .entity ? "Attributes (one per line)" : "Fields (one per line)").font(.caption)
                    TextEditor(text: $fields).font(.system(.caption, design: .monospaced)).frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    if node.kind != .entity {
                        Text("Methods (one per line)").font(.caption)
                        TextEditor(text: $methods).font(.system(.caption, design: .monospaced)).frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                    Button("Apply Members") {
                        document.updateNode(node.id, NodeEdit(fields: lines(fields), methods: node.kind == .entity ? nil : lines(methods)))
                    }
                    .disabled(lines(fields) == node.fields && (node.kind == .entity || lines(methods) == node.methods))
                }
            }
            Text("Press Return to apply text changes to the spec.").font(.caption2).foregroundStyle(.tertiary)

            Divider()
            SectionTitle("Appearance (drawing only)")
            StyleEditor(document: document, key: node.id, showFill: true)
            if !node.kind.isGroup, document.state.layout[node.id]?.size != nil {
                Button("Reset Size") { document.change("Reset Size") { s, _ in s.layout[node.id]?.size = nil } }
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            title = node.title
            stereotype = node.stereotype ?? ""
            technology = node.technology ?? ""
            descriptionText = node.description ?? ""
            fields = node.fields.joined(separator: "\n")
            methods = node.methods.joined(separator: "\n")
        }
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && t != node.title { document.updateNode(node.id, NodeEdit(title: t)) }
    }

    private func lines(_ s: String) -> [String] {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

func nilIfEmpty(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

private struct EdgeInspector: View {
    let document: DrawerDocument
    let edge: DiagramEdge
    @State private var label = ""
    @State private var technology = ""
    @State private var fromLabel = ""
    @State private var toLabel = ""

    private var family: DiagramFamily { document.parsed.family }
    private var markers: [EdgeMarker] {
        switch family {
        case .erDiagram: [.none, .exactlyOne, .zeroOrOne, .oneOrMany, .zeroOrMany]
        case .classDiagram: [.none, .arrow, .triangle, .diamond, .filledDiamond]
        case .flowchart: document.state.language == .mermaid ? [.none, .filledArrow, .circle, .cross] : [.none, .arrow, .triangle, .diamond, .filledDiamond, .circle, .cross]
        case .c4: [.none, .filledArrow]
        case .sequence: document.state.language == .mermaid ? [.none, .filledArrow, .arrow, .cross] : [.none, .filledArrow, .arrow, .cross, .circle]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection").font(.headline)
            Text("\(edge.from) → \(edge.to)").font(.caption.monospaced()).foregroundStyle(.secondary)
            SectionTitle("Spec")
            TextField("Label", text: $label).onSubmit { document.updateEdge(edge.id, EdgeEdit(label: .some(nilIfEmpty(label)))) }
            if family == .sequence {
                Picker("Arrow", selection: Binding(get: { edge.endMarker }, set: { document.updateEdge(edge.id, EdgeEdit(endMarker: $0)) })) {
                    Text("Synchronous").tag(EdgeMarker.filledArrow)
                    Text("Asynchronous").tag(EdgeMarker.arrow)
                    Text("Lost (✕)").tag(EdgeMarker.cross)
                    if document.state.language == .plantUML { Text("Circle").tag(EdgeMarker.circle) }
                    Text("No head").tag(EdgeMarker.none)
                }
                Picker("Line", selection: Binding(get: { edge.line == .dotted ? .dashed : edge.line }, set: { document.updateEdge(edge.id, EdgeEdit(line: $0)) })) {
                    Text("Call (solid)").tag(EdgeLineStyle.solid)
                    Text("Reply (dashed)").tag(EdgeLineStyle.dashed)
                }
                HStack {
                    Text("Space above")
                    Slider(value: Binding(get: { document.state.edgeLayout[edge.id]?.extraSpacing ?? 0 }, set: { v in
                        document.change("Change Spacing") { s, _ in var l = s.edgeLayout[edge.id] ?? EdgeLayout(); l.extraSpacing = v == 0 ? nil : v.rounded(); s.edgeLayout[edge.id] = l }
                    }), in: -20...200)
                }
            } else if family == .c4 {
                TextField("Technology", text: $technology).onSubmit { document.updateEdge(edge.id, EdgeEdit(technology: .some(nilIfEmpty(technology)))) }
            } else {
                Picker("Start", selection: Binding(get: { edge.startMarker }, set: { document.updateEdge(edge.id, EdgeEdit(startMarker: $0)) })) {
                    ForEach(markers + (markers.contains(edge.startMarker) ? [] : [edge.startMarker]), id: \.self) { Text(markerName($0)).tag($0) }
                }
                Picker("End", selection: Binding(get: { edge.endMarker }, set: { document.updateEdge(edge.id, EdgeEdit(endMarker: $0)) })) {
                    ForEach(markers + (markers.contains(edge.endMarker) ? [] : [edge.endMarker]), id: \.self) { Text(markerName($0)).tag($0) }
                }
                Picker("Line", selection: Binding(get: { edge.line == .dotted ? .dashed : edge.line }, set: { document.updateEdge(edge.id, EdgeEdit(line: $0)) })) {
                    Text("Solid").tag(EdgeLineStyle.solid)
                    Text("Dashed").tag(EdgeLineStyle.dashed)
                    Text("Thick").tag(EdgeLineStyle.thick)
                }
                if family == .classDiagram || (family == .flowchart && document.state.language == .plantUML) {
                    HStack {
                        TextField("From card.", text: $fromLabel).onSubmit { document.updateEdge(edge.id, EdgeEdit(fromLabel: .some(nilIfEmpty(fromLabel)))) }
                        TextField("To card.", text: $toLabel).onSubmit { document.updateEdge(edge.id, EdgeEdit(toLabel: .some(nilIfEmpty(toLabel)))) }
                    }
                }
            }
            Button("Reverse Direction") { document.updateEdge(edge.id, EdgeEdit(reverse: true)) }

            Divider()
            SectionTitle("Appearance (drawing only)")
            if family != .sequence {
            Picker("Routing", selection: Binding(get: { document.state.edgeLayout[edge.id]?.routing ?? .straight }, set: { r in
                document.change("Change Routing") { s, _ in var l = s.edgeLayout[edge.id] ?? EdgeLayout(); l.routing = r; s.edgeLayout[edge.id] = l }
            })) {
                ForEach(EdgeRouting.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            if !(document.state.edgeLayout[edge.id]?.waypoints.isEmpty ?? true) {
                Button("Remove Bends") { document.change("Remove Bends") { s, _ in s.edgeLayout[edge.id]?.waypoints = [] } }
            }
            }
            StyleEditor(document: document, key: "edge:" + edge.id, showFill: false)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            label = edge.label ?? ""
            technology = edge.technology ?? ""
            fromLabel = edge.fromLabel ?? ""
            toLabel = edge.toLabel ?? ""
        }
    }

    private func markerName(_ m: EdgeMarker) -> String {
        switch m {
        case .none: "None"
        case .arrow: "Arrow"
        case .filledArrow: "Filled Arrow"
        case .triangle: "Inheritance ▷"
        case .diamond: "Aggregation ◇"
        case .filledDiamond: "Composition ◆"
        case .circle: "Circle"
        case .cross: "Cross"
        case .exactlyOne: "Exactly one ||"
        case .zeroOrOne: "Zero or one o|"
        case .oneOrMany: "One or many |{"
        case .zeroOrMany: "Zero or many o{"
        }
    }
}

private struct DecorationInspector: View {
    let document: DrawerDocument
    let decoration: Decoration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(decoration.kind.rawValue.capitalized).font(.headline)
            Text("Annotation — exists only in the drawing.").font(.caption).foregroundStyle(.secondary)
            TextField("Text", text: Binding(get: { decoration.text }, set: { v in update { $0.text = v } }), axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            Stepper("Font size: \(Int(decoration.fontSize))", value: Binding(get: { decoration.fontSize }, set: { v in update { $0.fontSize = v } }), in: 8...72)
            ColorRow(title: "Fill", hex: decoration.style.fill) { h in update { $0.style.fill = h } }
            ColorRow(title: "Stroke", hex: decoration.style.stroke) { h in update { $0.style.stroke = h } }
            ColorRow(title: "Text", hex: decoration.style.text) { h in update { $0.style.text = h } }
            Toggle("Dashed", isOn: Binding(get: { decoration.style.dashed == true }, set: { v in update { $0.style.dashed = v ? true : nil } }))
        }
    }

    private func update(_ body: @escaping (inout Decoration) -> Void) {
        let id = decoration.id
        document.change("Edit Annotation") { s, _ in
            if let i = s.decorations.firstIndex(where: { $0.id == id }) { body(&s.decorations[i]) }
        }
    }
}

private struct StyleEditor: View {
    let document: DrawerDocument
    let key: String
    let showFill: Bool

    private var style: ElementStyle { document.state.styles[key] ?? ElementStyle() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showFill { ColorRow(title: "Fill", hex: style.fill) { h in document.setStyle(key) { $0.fill = h } } }
            ColorRow(title: showFill ? "Border" : "Colour", hex: style.stroke) { h in document.setStyle(key) { $0.stroke = h } }
            if showFill { ColorRow(title: "Text", hex: style.text) { h in document.setStyle(key) { $0.text = h } } }
            Toggle("Dashed", isOn: Binding(get: { style.dashed == true }, set: { v in document.setStyle(key) { $0.dashed = v ? true : nil } }))
            HStack {
                Text("Line width")
                Slider(value: Binding(get: { style.lineWidth ?? (showFill ? 1.2 : 1.3) }, set: { v in document.setStyle(key) { $0.lineWidth = (v * 2).rounded() / 2 } }), in: 0.5...6)
            }
            if !style.isEmpty {
                Button("Reset Appearance") { document.change("Reset Style") { s, _ in s.styles[key] = nil } }
            }
        }
    }
}

private struct ColorRow: View {
    let title: String
    let hex: String?
    let onChange: (String?) -> Void

    private static let swatches = ["#FFFFFF", "#FFF6B3", "#FFD8D8", "#D8F5D8", "#D8E8FF", "#EBDFFF", "#1168BD", "#438DD5", "#E8590C", "#2F9E44", "#495057", "#000000"]

    var body: some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 52, alignment: .leading)
            ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: hex) ?? .clear) }, set: { onChange(NSColor($0).hexString) }))
                .labelsHidden()
            Menu {
                ForEach(Self.swatches, id: \.self) { s in
                    Button { onChange(s) } label: { Label(s, systemImage: "circle.fill") }
                }
                Divider()
                Button("Default") { onChange(nil) }
            } label: { Image(systemName: "swatchpalette") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            if hex != nil {
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }
}
