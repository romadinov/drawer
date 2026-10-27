import AppKit
import SwiftUI
import DrawerCore

/// Plain-text spec editor with light syntax highlighting and two-way selection sync.
struct SpecEditorView: NSViewRepresentable {
    let document: DrawerDocument
    let revision: Int
    let selection: Set<ElementRef>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.allowsUndo = false // the document owns undo
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.backgroundColor = .textBackgroundColor
        tv.delegate = context.coordinator
        tv.string = document.state.spec
        context.coordinator.textView = tv
        context.coordinator.document = document
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.document = document
        guard let tv = c.textView else { return }
        if tv.string != document.state.spec {
            c.applyExternalText(document.state.spec)
        }
        c.showSelection(selection, scroll: document.selectionOrigin == .canvas)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var document: DrawerDocument?
        private var applyingExternal = false
        private var lastShownSelection: Set<ElementRef> = []

        func textDidChange(_ notification: Notification) {
            guard !applyingExternal, let tv = textView else { return }
            highlight()
            document?.specTextChanged(tv.string)
        }

        /// Replace only the changed middle part so the caret and scroll position survive.
        func applyExternalText(_ new: String) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            applyingExternal = true
            defer { applyingExternal = false }
            let old = tv.string as NSString
            let n = new as NSString
            var prefix = 0
            let maxPrefix = min(old.length, n.length)
            while prefix < maxPrefix, old.character(at: prefix) == n.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < min(old.length, n.length) - prefix,
                  old.character(at: old.length - 1 - suffix) == n.character(at: n.length - 1 - suffix) { suffix += 1 }
            let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
            let replacement = n.substring(with: NSRange(location: prefix, length: n.length - prefix - suffix))
            let selected = tv.selectedRange()
            storage.beginEditing()
            storage.replaceCharacters(in: oldRange, with: replacement)
            storage.endEditing()
            let delta = (replacement as NSString).length - oldRange.length
            var sel = selected
            if sel.location >= oldRange.location + oldRange.length { sel.location += delta }
            sel.location = min(sel.location, n.length)
            sel.length = min(sel.length, n.length - sel.location)
            tv.setSelectedRange(sel)
            highlight()
            lastShownSelection = []
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingExternal, let tv = textView, let doc = document,
                  tv.window?.firstResponder === tv else { return }
            let caret = tv.selectedRange().location
            let parsed = doc.parsed
            var best: (ElementRef, Int)?
            func consider(_ ref: ElementRef, _ span: SourceSpan?) {
                guard let span, span.contains(caret) else { return }
                if best == nil || span.length < best!.1 { best = (ref, span.length) }
            }
            for n in parsed.nodes {
                for s in n.referenceSpans { consider(.node(n.id), s) }
                if let t = n.titleSpan { consider(.node(n.id), SourceSpan(location: t.location, length: t.length)) }
            }
            for e in parsed.edges {
                // Prefer a node reference over the whole edge line.
                if let s = e.span, s.contains(caret) {
                    if best == nil || best!.1 >= s.length { best = (.edge(e.id), s.length) }
                }
            }
            let newSelection: Set<ElementRef> = best.map { [$0.0] } ?? []
            if newSelection != doc.selection {
                doc.selectionOrigin = .editor
                doc.selection = newSelection
            }
        }

        func showSelection(_ selection: Set<ElementRef>, scroll: Bool) {
            guard let tv = textView, let lm = tv.layoutManager, let doc = document, selection != lastShownSelection else { return }
            lastShownSelection = selection
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            var first: NSRange?
            for ref in selection {
                var spans: [SourceSpan] = []
                switch ref {
                case let .node(id):
                    if let n = doc.parsed.node(id) { spans = n.declarationSpan.map { [$0] } ?? Array(n.referenceSpans.prefix(1)) }
                case let .edge(id):
                    if let s = doc.parsed.edge(id)?.span { spans = [s] }
                case .decoration:
                    break
                }
                for s in spans where s.end <= full.length {
                    lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.16), forCharacterRange: s.nsRange)
                    if first == nil || s.location < first!.location { first = s.nsRange }
                }
            }
            if scroll, let first { tv.scrollRangeToVisible(first) }
        }

        // MARK: Highlighting

        private static let rules: [(NSRegularExpression, NSColor)] = {
            func r(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
            return [
                (r(#"^\s*(@startuml|@enduml|flowchart|graph|classDiagram|erDiagram|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment|subgraph|end|direction|title|namespace|left to right direction|skinparam|!include\S*|!\w+)\b.*$"#, .anchorsMatchLines), .systemPurple),
                (r(#"\b(class|interface|enum|abstract|entity|component|node|database|actor|usecase|rectangle|package|folder|frame|cloud|queue|artifact|as)\b"#), .systemPink),
                (r(#"\b(Person|Person_Ext|System|System_Ext|SystemDb|SystemDb_Ext|SystemQueue|Container|Container_Ext|ContainerDb|ContainerDb_Ext|ContainerQueue|Component|Component_Ext|ComponentDb|ComponentQueue|Boundary|System_Boundary|Container_Boundary|Enterprise_Boundary|Deployment_Node|Rel\w*|BiRel\w*)\b(?=\s*\()"#), .systemPink),
                (r(#"(<\|--|<\|\.\.|--\|>|\.\.\|>|\*--|--\*|o--|--o|-->|<--|\.\.>|<\.\.|-\.->|==>|---|--|\.\.|\|\|--|--\|\{|--o\{|\}o--|\|o--|o\{|\|\{|-+>)"#), .systemOrange),
                (r(#""[^"\n]*""#), .systemGreen),
                (r(#"<<[^>\n]*>>"#), .systemTeal),
                (r(#"(^\s*'.*$|^\s*%%.*$)"#, .anchorsMatchLines), .secondaryLabelColor),
            ]
        }()

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor.textColor], range: full)
            for (regex, color) in Self.rules {
                regex.enumerateMatches(in: storage.string, range: full) { m, _, _ in
                    if let m { storage.addAttribute(.foregroundColor, value: color, range: m.range) }
                }
            }
            storage.endEditing()
        }
    }
}
