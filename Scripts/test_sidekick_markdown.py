#!/usr/bin/env python3
"""Compile actual Markdown parser/view sources; exercise source quotes and native text layout.

No Sentient app launch, windows, providers, credentials, network, or production preferences.
"""
from pathlib import Path
import subprocess
from swift_fixture import platform_plugin_flags
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sentient OS macOS/Views/Sidekick"
FIXTURE = r'''
import AppKit
import Foundation

@main enum MarkdownTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }
        checks += 1
    }
    static func fragments(_ document: SidekickMarkdownDocument) -> [SidekickMarkdownDocument.Fragment] {
        document.blocks.flatMap { block in
            switch block {
            case .text(let text, _), .code(let text, _, _): return [text]
            case .table(let table, _): return table.rows.flatMap { $0.cells.map(\.fragment) }
            case .rule: return []
            }
        }
    }
    static func first(_ source: String) -> SidekickMarkdownDocument.Fragment {
        fragments(SidekickMarkdownDocument(markdown: source))[0]
    }
    static func quote(_ fragment: SidekickMarkdownDocument.Fragment, _ text: String, source: String) -> String? {
        fragment.sourceQuote(for: (fragment.text as NSString).range(of: text), in: source)
    }
    static func main() async {
        let nested = SidekickMarkdownDocument(markdown: """
        # A **heading**

        3. First
           - Child

             Second paragraph in child.
        4. Next

        > A quote
        >
        > > Nested quote

        ---
        """)
        let decorations = nested.blocks.compactMap { block -> SidekickMarkdownDocument.Decoration? in
            if case .text(_, let decoration) = block { decoration } else { nil }
        }
        check(decorations[0].heading == 1, "heading intent")
        check(decorations.contains { $0.marker == "3." }, "ordered start preserved")
        check(decorations.contains { $0.marker == "4." }, "ordered next item preserved")
        check(decorations.contains { $0.listDepth == 2 && $0.marker == "•" }, "nested unordered list")
        check(decorations.contains { $0.listDepth == 2 && $0.marker == nil }, "continuation does not repeat bullet")
        check(decorations.contains { $0.quoteDepth == 2 }, "nested blockquote")
        check(nested.blocks.contains { if case .rule = $0 { true } else { false } }, "thematic break")

        let tableDocument = SidekickMarkdownDocument(markdown: "| Name | Count |\n|:---|---:|\n| A | **2** |\n| pipe \\| inside | 3 |")
        guard case .table(let table, _) = tableDocument.blocks[0] else { fatalError("table missing") }
        check(table.rows.count == 3 && table.rows[0].header, "table header and rows")
        check(table.columns.map(\.alignment) == [.left, .right], "table alignment")
        check(table.rows[1].cells[1].fragment.text == "2", "table inline formatting")
        check(table.rows[2].cells[0].fragment.text == "pipe | inside", "escaped table pipe")

        let codeSource = "```swift\nlet greeting = \"hello\"\nprint(greeting)\n```"
        let codeDocument = SidekickMarkdownDocument(markdown: codeSource)
        guard case .code(let code, let language, _) = codeDocument.blocks[0] else { fatalError("code missing") }
        check(language == "swift", "code language")
        check(code.text == "let greeting = \"hello\"\nprint(greeting)\n", "code copy body excludes fences")
        check(quote(code, "greeting", source: codeSource) == "greeting", "code selection maps inside fences")
        check(quote(code, "print(greeting)", source: codeSource) == "print(greeting)", "code later line exact")
        let tilde = SidekickMarkdownDocument(markdown: "~~~python\nprint(1)\n~~~")
        check(tilde.blocks.contains { if case .code(_, let language, _) = $0 { language == "python" } else { false } }, "tilde fence")
        let unfinished = SidekickMarkdownDocument(markdown: "```txt\nunfinished")
        check(fragments(unfinished).first?.text.hasPrefix("unfinished") == true, "unfinished fence visible")

        let formatted = "hello **bold** then [linked text](https://example.com) and `code`"
        let paragraph = first(formatted)
        check(quote(paragraph, "bold", source: formatted) == "bold", "bold maps to exact source text")
        check(quote(paragraph, "hello bold then", source: formatted) == "hello **bold** then", "cross-format selection includes exact syntax")
        check(quote(paragraph, "linked text", source: formatted) == "linked text", "link label selection")
        check(quote(paragraph, "bold then linked text", source: formatted) == "bold** then [linked text", "cross-link source remains exact")
        check(paragraph.sourceQuote(for: NSRange(location: NSNotFound, length: 1), in: formatted) == nil, "invalid range rejected")
        check(paragraph.sourceQuote(for: NSRange(location: 0, length: Int.max), in: formatted) == nil, "overflow range rejected")
        check(paragraph.sourceQuote(for: NSRange(location: 0, length: 0), in: formatted) == nil, "empty selection rejected")

        let entity = "&amp;"
        check(quote(first(entity), "&", source: entity) == entity, "entity selection expands to original spelling")
        let unicodeEntity = "&#x1F600;"
        check(quote(first(unicodeEntity), "😀", source: unicodeEntity) == unicodeEntity, "Unicode entity expands safely")
        let unicode = "Hi 👩🏽‍💻 café e\u{301} **नमस्ते**."
        let unicodeFragment = first(unicode)
        check(quote(unicodeFragment, "👩🏽‍💻", source: unicode) == "👩🏽‍💻", "emoji grapheme mapping")
        check(quote(unicodeFragment, "e\u{301}", source: unicode) == "e\u{301}", "decomposed accent mapping")
        check(quote(unicodeFragment, "नमस्ते", source: unicode) == "नमस्ते", "non-Latin selection")
        let repeatedSource = "same **same** same"
        let repeated = first(repeatedSource)
        check(repeated.mappings[1].source.location == 7, "repeated phrase maps to selected occurrence")
        let lineSource = "first line\nsecond line"
        check(quote(first(lineSource), "line second", source: lineSource) == "line\nsecond", "soft break maps original newline")
        let crlfSource = "before\r\nafter **bold**"
        let crlf = first(crlfSource)
        check(quote(crlf, "bold", source: crlfSource) == "bold", "CRLF source offsets")

        // Every selectable scalar-sized range must return source text, never synthesized
        // rendered Markdown or a string that the durable reply validator would reject.
        for source in [formatted, unicode, "escaped \\* and &amp; with **bold**", "[x](https://example.com) &lt;tag&gt;"] {
            for fragment in fragments(SidekickMarkdownDocument(markdown: source)) {
                for location in 0..<fragment.text.utf16.count {
                    if let selected = fragment.sourceQuote(for: NSRange(location: location, length: 1), in: source) {
                        check(source.contains(selected), "exact raw substring invariant")
                    }
                }
            }
        }
        let large = String(repeating: "🙂 exact text\n", count: 8_000)
        let largeDocument = SidekickMarkdownDocument(markdown: large)
        check(largeDocument.remainder != nil, "large source parse is bounded")
        let tail = largeDocument.remainder!
        check(!tail.text.contains("�"), "large prefix split respects graphemes")
        check(tail.sourceQuote(for: NSRange(location: 0, length: tail.text.utf16.count), in: large) == tail.text, "large remainder is exact and selectable")
        let manyBlocks = String(repeating: "tiny\n\n", count: 500)
        let bounded = SidekickMarkdownDocument(markdown: manyBlocks)
        check(bounded.blocks.count == 1 && fragments(bounded)[0].text == manyBlocks, "complex block count falls back without loss")

        let normal = SidekickSelectableMarkdown.Style(compact: false, heading: nil, code: false, bold: false, alignment: .left)
        let styled = SidekickSelectableMarkdown.styled(paragraph.attributed, style: normal)
        let boldRange = (styled.string as NSString).range(of: "bold")
        let boldFont = styled.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "native bold font")
        let linkRange = (styled.string as NSString).range(of: "linked text")
        check(styled.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"), "native link attribute")
        for url in ["javascript:alert(1)", "file:///tmp/test", "data:text/html,test", "sentient:delete"] {
            check(!SidekickMarkdownTextView.permitted(URL(string: url)!), "non-web URL is not activated")
        }
        check(SidekickMarkdownTextView.permitted(URL(string: "mailto:hello@example.com")!), "email link supported")
        let dangerous = first("[local](file:///tmp/example)")
        check(SidekickSelectableMarkdown.styled(dangerous.attributed, style: normal).attribute(.link, at: 0, effectiveRange: nil) == nil, "unpermitted link remains inert text")

        let textView = SidekickMarkdownTextView()
        textView.drawsBackground = false; textView.isEditable = false; textView.isSelectable = true
        textView.textContainerInset = .zero; textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        let longParagraph = first(String(repeating: "Native text sizing wraps correctly. ", count: 20))
        textView.textStorage?.setAttributedString(SidekickSelectableMarkdown.styled(longParagraph.attributed, style: normal))
        let narrow = SidekickSelectableMarkdown.measuredSize(textView, proposedWidth: 180, style: normal, wrapping: true)!
        let wide = SidekickSelectableMarkdown.measuredSize(textView, proposedWidth: 600, style: normal, wrapping: true)!
        check(narrow.height > wide.height && narrow.width == 180 && wide.width == 600, "native layout responds to transcript width")
        let natural = SidekickSelectableMarkdown.measuredSize(textView, proposedWidth: nil, style: normal, wrapping: false)!
        check(natural.width > 600 && natural.height < wide.height, "horizontal code layout reports natural width")
        let empty = SidekickSelectableMarkdown.measuredSize(textView, proposedWidth: 0, style: normal, wrapping: true)!
        check(empty.width == 1 && empty.height.isFinite, "zero proposal stays finite")

        textView.fragment = paragraph; textView.source = formatted
        textView.textStorage?.setAttributedString(styled)
        var actualReply: String?
        textView.onReply = { actualReply = $0 }
        textView.setSelectedRange((paragraph.text as NSString).range(of: "hello bold then"))
        textView.setFrameSize(NSSize(width: 600, height: 100))
        _ = SidekickSelectableMarkdown.measuredSize(textView, proposedWidth: 600, style: normal, wrapping: true)
        let glyphAnchor = textView.selectedGlyphRect()
        check(glyphAnchor != nil && glyphAnchor!.width > 0 && glyphAnchor!.height > 0,
              "floating reply anchors to native selected glyphs")
        textView.perform(NSSelectorFromString("replyToSelection"))
        check(actualReply == "hello **bold** then", "actual AppKit reply target delivers raw source")
        check(textView.selectedRange().length == 0, "reply clears native selection")
        check(textView.selectedGlyphRect() == nil, "empty selection has no floating reply anchor")
        let owner = NSRect(x: 100, y: 100, width: 800, height: 600)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let middle = NSRect(x: 300, y: 300, width: 120, height: 20)
        let popup = SidekickSelectionReplyPlacement.frame(anchor: middle, owner: owner, screen: screen)!
        check(popup.minY > middle.maxY && popup.midX == middle.midX, "floating reply appears above selection")
        for anchor in [NSRect(x: 101, y: 110, width: 10, height: 15),
                       NSRect(x: 880, y: 680, width: 10, height: 15)] {
            let placed = SidekickSelectionReplyPlacement.frame(anchor: anchor, owner: owner, screen: screen)!
            check(owner.insetBy(dx: 6, dy: 6).contains(placed), "reply clamps at owner-window edges")
        }
        let leftDisplay = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftOwner = NSRect(x: -1750, y: 200, width: 800, height: 600)
        let leftAnchor = NSRect(x: -1600, y: 450, width: 80, height: 16)
        let leftPopup = SidekickSelectionReplyPlacement.frame(anchor: leftAnchor, owner: leftOwner, screen: leftDisplay)!
        check(leftPopup.minY > leftAnchor.maxY && leftOwner.contains(leftPopup), "negative-origin monitor placement")
        check(SidekickSelectionReplyPlacement.frame(anchor: .zero, owner: owner, screen: screen) == nil,
              "empty anchor cannot open a popup")
        check(SidekickSelectionReplyPlacement.frame(anchor: NSRect(x: 2000, y: 2000, width: 20, height: 20), owner: owner, screen: screen) == nil,
              "offscreen selection cannot create detached popup")
        var observations: [Bool] = []
        textView.onSelectionChange = { observations.append($0) }
        textView.reportSelection(true); textView.reportSelection(true); textView.reportSelection(false)
        for _ in 0..<5 { await Task.yield() }
        check(observations == [true, false], "selection observations are content-free and deduplicated")

        check(SidekickMarkdown(markdown: "x").onReplyToMessage == nil, "Markdown whole-reply callback defaults to nil")
        check(SidekickPlainText(text: "x").onReplyToMessage == nil, "plain whole-reply callback defaults to nil")
        let messageSource = "# Draft **café**\r\n\r\n- Keep 👩🏽‍💻 and e\u{301} as typed.\n`raw *code*`\n"
        let messageFragment = first(messageSource)
        textView.source = messageSource; textView.fragment = messageFragment
        textView.textStorage?.setAttributedString(SidekickSelectableMarkdown.styled(messageFragment.attributed, style: normal))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        var messageReplies = 0
        textView.onReplyToMessage = { messageReplies += 1 }
        let systemMenu = NSMenu()
        let selectionCopy = NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        selectionCopy.target = textView; systemMenu.addItem(selectionCopy)
        let messageMenu = textView.messageContextMenu(addingTo: systemMenu)
        let wholeCopy = messageMenu.items.first { $0.identifier?.rawValue == "sidekick.copyMessage" }!
        let wholeReply = messageMenu.items.first { $0.identifier?.rawValue == "sidekick.replyMessage" }!
        check(wholeCopy.title == "Copy message" && wholeReply.title == "Reply to message", "whole actions available with zero selection")
        check(!messageMenu.items.contains { $0.title == "Reply to selection" }, "zero selection does not offer selected reply")
        check(messageMenu.items.contains { $0 === selectionCopy } && selectionCopy.action == NSSelectorFromString("copy:"),
              "native Copy selection action remains untouched")
        check(textView.validateUserInterfaceItem(wholeCopy) && textView.validateUserInterfaceItem(wholeReply),
              "whole-message actions validate without a selected range")
        _ = textView.messageContextMenu(addingTo: messageMenu)
        check(messageMenu.items.filter { $0.title == "Copy message" }.count == 1
              && messageMenu.items.filter { $0.title == "Reply to message" }.count == 1,
              "reused native menu does not duplicate message actions")
        textView.perform(wholeReply.action!, with: wholeReply)
        check(messageReplies == 1, "native whole-message Reply target invokes callback")
        let privatePasteboard = NSPasteboard.withUniqueName()
        defer { privatePasteboard.releaseGlobally() }
        check(textView.copyMessage(to: privatePasteboard), "whole-copy handler writes to supplied pasteboard")
        check(privatePasteboard.string(forType: .string)?.utf8.elementsEqual(messageSource.utf8) == true,
              "whole-copy preserves exact Unicode Markdown CRLF and whitespace bytes")

        textView.setSelectedRange((messageFragment.text as NSString).range(of: "café"))
        _ = textView.messageContextMenu(addingTo: messageMenu)
        check(messageMenu.items.contains { $0.title == "Reply to selection" }
              && messageMenu.items.contains { $0 === selectionCopy }, "selection offers both reply modes and native selection Copy")
        check(selectionCopy.target === textView && selectionCopy.action == NSSelectorFromString("copy:")
              && (textView.string as NSString).substring(with: textView.selectedRange()) == "café",
              "native Copy selection keeps its original target and selected rendered range")
        textView.perform(NSSelectorFromString("replyToSelection"))
        check(actualReply == "café" && messageReplies == 1, "selected exact-source Reply remains separate from whole reply")

        textView.source = largeDocument.source; textView.fragment = fragments(largeDocument)[0]
        check(textView.copyMessage(to: privatePasteboard)
              && privatePasteboard.string(forType: .string)?.utf8.elementsEqual(large.utf8) == true,
              "whole-copy includes original content beyond bounded parsed prefix")
        textView.onReplyToMessage = nil
        _ = textView.messageContextMenu(addingTo: messageMenu)
        check(!messageMenu.items.contains { $0.title == "Reply to message" }
              && messageMenu.items.contains { $0.title == "Copy message" }, "optional whole callback controls reply only")
        final class ReplyLifetime { var calls = 0 }
        weak var retainedReplyOwner: ReplyLifetime?
        do {
            let owner = ReplyLifetime(); retainedReplyOwner = owner
            textView.onReplyToMessage = { owner.calls += 1 }
        }
        check(retainedReplyOwner != nil, "whole callback retains its action owner before dismantle")
        SidekickSelectableMarkdown.dismantleNSView(textView, coordinator: ())
        check(textView.onReplyToMessage == nil && textView.onReply == nil && textView.onSelectionChange == nil,
              "dismantle releases all message and selection callbacks")
        check(retainedReplyOwner == nil, "whole-reply action owner released on dismantle")

        // A mounted transcript can be visually hidden behind the overview/Settings. Exercise
        // the real native view and selectors so queued actions cannot bypass that disablement.
        let inertView = SidekickMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        inertView.isEditable = false; inertView.isSelectable = true; inertView.delegate = inertView
        inertView.source = messageSource; inertView.fragment = messageFragment
        inertView.textStorage?.setAttributedString(SidekickSelectableMarkdown.styled(messageFragment.attributed, style: normal))
        let preservedSelection = (messageFragment.text as NSString).range(of: "café")
        inertView.setSelectedRange(preservedSelection)
        let preservedText = inertView.string
        var inertWholeReplies = 0
        var inertSelectedReplies: [String] = []
        inertView.onReplyToMessage = { inertWholeReplies += 1 }
        inertView.onReply = { inertSelectedReplies.append($0) }
        let queuedMenu = inertView.messageContextMenu(addingTo: NSMenu())
        let queuedWhole = queuedMenu.items.first { $0.title == "Reply to message" }!
        let queuedSelected = queuedMenu.items.first { $0.title == "Reply to selection" }!
        let queuedActions = Task { @MainActor in
            _ = inertView.perform(queuedWhole.action!, with: queuedWhole)
            _ = inertView.perform(queuedSelected.action!)
        }
        inertView.interactionEnabled = false
        check(inertView.hitTest(NSPoint(x: 20, y: 20)) == nil, "disabled native text ignores hit testing")
        check(inertView.isAccessibilityHidden(), "disabled native text is hidden from accessibility")
        check(!inertView.acceptsFirstResponder, "disabled native text refuses first-responder eligibility")
        check(!inertView.becomeFirstResponder(), "disabled native text refuses direct first-responder attempt")
        let inertClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        check(inertView.menu(for: inertClick) == nil, "disabled native text does not open context menu")
        await queuedActions.value
        check(inertWholeReplies == 0 && inertSelectedReplies.isEmpty, "queued whole and selected replies cannot run while disabled")
        check(inertView.string == preservedText && inertView.source.utf8.elementsEqual(messageSource.utf8)
              && inertView.selectedRange() == preservedSelection, "disablement preserves rendered text exact source and selection")
        inertView.interactionEnabled = true
        check(!inertView.isAccessibilityHidden(), "reenabled native text returns to accessibility")
        check(inertView.acceptsFirstResponder, "reenabled native text restores responder eligibility")
        check(inertView.hitTest(NSPoint(x: 20, y: 20)) != nil, "reenabled native text restores hit testing")
        check(inertView.string == preservedText && inertView.source.utf8.elementsEqual(messageSource.utf8)
              && inertView.selectedRange() == preservedSelection, "reenabling preserves text source and original selection")
        inertView.perform(queuedSelected.action!)
        check(inertSelectedReplies == ["café"] && inertWholeReplies == 0, "reenabled selected Reply restores exact-source callback")
        check(inertView.selectedRange().length == 0, "restored selected Reply clears the consumed selection")
        inertView.setSelectedRange(preservedSelection)
        inertView.perform(queuedWhole.action!, with: queuedWhole)
        check(inertWholeReplies == 1 && inertSelectedReplies == ["café"], "reenabled whole Reply restores only its own callback")
        check(inertView.selectedRange().length == 0, "restored whole Reply clears the consumed selection")
        SidekickSelectableMarkdown.dismantleNSView(inertView, coordinator: ())
        print("Sidekick Markdown: \(checks) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-markdown-tests-") as temporary:
    directory = Path(temporary)
    fixture = directory / "Fixture.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "markdown-tests"
    subprocess.run([
        "xcrun", "swiftc", *platform_plugin_flags(), "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        str(SOURCES / "SidekickMarkdownDocument.swift"), str(SOURCES / "SidekickMarkdown.swift"),
        str(fixture), "-o", str(binary),
    ], check=True, cwd=ROOT, timeout=90)
    subprocess.run([str(binary)], check=True, cwd=directory, timeout=30)
