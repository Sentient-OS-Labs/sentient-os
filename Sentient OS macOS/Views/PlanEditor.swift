//
//  PlanEditor.swift
//  Sentient OS macOS  ·  Views/
//
//  The computer-use plan's editor: an NSTextView bridge that renders each step's leading number
//  ("1.", "2." …) in quiet grey while the step text stays bright — SwiftUI's TextEditor can't
//  style ranges (its attributed flavour is macOS-26-only; target is 15). Same contract as
//  TextEditor(text:): edits flow through the binding, so autosave and the verbatim fire path are
//  untouched. Machine voice throughout: real system mono, airy leading, no scrollers, height that
//  hugs the content. Used by LetterView's draft block for computer-use plans.
//

import SwiftUI
import AppKit

struct PlanEditor: NSViewRepresentable {
    @Binding var text: String
    var accent: Color

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let ink = NSColor.white.withAlphaComponent(0.92)
    private static let numberInk = NSColor.white.withAlphaComponent(0.48)   // the quiet step number
    private static let leading: CGFloat = 9                                 // matches the old TextEditor's lineSpacing
    private static let stepNumber = try! NSRegularExpression(pattern: #"^\s*\d+[.)]"#)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false          // no scroller pill; the wheel still scrolls past 300pt
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        // Never "improve" the plan's text — smart substitutions would mangle steps codex must follow.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.insertionPointColor = NSColor(accent)
        tv.delegate = context.coordinator
        tv.string = text
        Self.restyle(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.insertionPointColor = NSColor(accent)
        if tv.string != text {                      // external change (card switch); typing no-ops here
            tv.string = text
            Self.restyle(tv)
        }
    }

    /// Height hugs the laid-out text (like TextEditor did), clamped to the draft block's 56–300.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView,
              let container = tv.textContainer, let layout = tv.layoutManager,
              let width = proposal.width, width.isFinite, width > 0 else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + tv.textContainerInset.height * 2 + 4
        return CGSize(width: width, height: min(max(height, 56), 300))
    }

    /// Base machine-voice attributes over everything, then the quiet grey on each line's leading
    /// "N." / "N)" token. Attribute-only edits — the caret and selection stay put, so this can run
    /// on every keystroke.
    static func restyle(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = leading
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: para]
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
        let ns = storage.string as NSString
        var i = 0
        while i < ns.length {
            let line = ns.lineRange(for: NSRange(location: i, length: 0))
            if let match = stepNumber.firstMatch(in: storage.string, range: line) {
                storage.addAttribute(.foregroundColor, value: numberInk, range: match.range)
            }
            i = NSMaxRange(line)
        }
        storage.endEditing()
        tv.typingAttributes = base
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlanEditor
        init(_ parent: PlanEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            PlanEditor.restyle(tv)
        }
    }
}

#if DEBUG
#Preview("Plan editor") {
    @Previewable @State var text = """
    1. Open the browser to canva.com/settings/billing-and-teams (already logged in).
    2. Under Canva Pro, click Cancel trial.
    3. If asked for a reason, pick 'I don't use it enough'.
    4. Decline any pause, discount, or free-month offers.
    5. Confirm the cancellation.
    6. Verify the page shows Pro ending July 15 with no renewal.
    """
    ZStack {
        Color.black.ignoresSafeArea()
        PlanEditor(text: $text, accent: Color(red: 0.30, green: 0.82, blue: 0.78))
            .frame(width: 560)
            .padding(30)
    }
}
#endif
