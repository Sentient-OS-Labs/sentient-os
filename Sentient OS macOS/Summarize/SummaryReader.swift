// One native TextKit document for stable wrapping, scrolling and cross-paragraph selection.
// Reuses Sidekick's Markdown parser/styling without retaining summary text in its shared cache.
// Doc: Documentation - Summarize.md
import AppKit
import SwiftUI

struct SummaryReader: NSViewRepresentable {
    let text: String
    let generation: UUID
    var plainText = false
    var accessibilityLabel = "Screen summary"

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        scroll.contentView.drawsBackground = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = SummaryTextView(frame: NSRect(x: 0, y: 0, width: 504, height: 200))
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.importsGraphics = false; view.allowsUndo = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 28, height: 22)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 448, height: CGFloat.greatestFiniteMagnitude)
        view.appearance = NSAppearance(named: .darkAqua)
        view.delegate = view
        view.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SummaryTextView else { return }
        view.plainText = plainText
        if view.generation != generation {
            view.stopFades(); view.generation = generation; view.pending = nil; view.rendered = nil
            view.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
        }
        guard view.rendered != text else { return }
        if view.selectedRange().length > 0 { view.pending = text }
        else { view.render(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 504,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 240)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: ()) {
        (view.documentView as? SummaryTextView)?.clear()
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let document = SidekickMarkdownDocument(markdown: text)
        let result = NSMutableAttributedString(string: "")
        for block in document.blocks {
            let fragment: SidekickMarkdownDocument.Fragment
            let decoration: SidekickMarkdownDocument.Decoration?
            let code: Bool
            switch block {
            case .text(let value, let format): fragment = value; decoration = format; code = false
            case .code(let value, _, let format): fragment = value; decoration = format; code = true
            case .table(let table, let format):
                fragment = .plain(table.rows.map { $0.cells.map { $0.fragment.text }.joined(separator: " · ") }.joined(separator: "\n"))
                decoration = format; code = false
            case .rule:
                let attachment = NSTextAttachment()
                attachment.attachmentCell = SummaryDividerCell(textCell: "")
                let divider = NSMutableAttributedString(attachment: attachment)
                divider.append(NSAttributedString(string: "\n"))
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacingBefore = 2
                paragraph.paragraphSpacing = 14
                divider.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: divider.length))
                result.append(divider)
                continue
            }
            let style = SidekickSelectableMarkdown.Style(compact: false, heading: decoration?.heading,
                code: code, bold: false, alignment: .left, bodyPointSize: 16)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 14
            paragraph.lineBreakMode = .byWordWrapping
            let indent = CGFloat(min(decoration?.listDepth ?? 0, 6)) * 20 + CGFloat(min(decoration?.quoteDepth ?? 0, 4)) * 14
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = max(0, indent - ((decoration?.marker) != nil ? 20 : 0))
            let part = NSMutableAttributedString(string: "")
            if let marker = decoration?.marker { part.append(NSAttributedString(string: marker + "  ", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor])) }
            part.append(SidekickSelectableMarkdown.styled(fragment.attributed, style: style))
            part.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 16)]))
            part.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: part.length))
            // A summary is a reading surface. Never make screenshot-derived links actionable.
            part.removeAttribute(.link, range: NSRange(location: 0, length: part.length))
            result.append(part)
        }
        if let remainder = document.remainder {
            result.append(NSAttributedString(string: remainder.text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]))
        }
        return result
    }
}

/// A real, resizing Markdown divider inside the same selectable TextKit document.
private final class SummaryDividerCell: NSTextAttachmentCell {
    override nonisolated func cellSize() -> NSSize { NSSize(width: 1, height: 10) }
    override nonisolated func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                       glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(1, lineFrag.width), height: 10)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSColor.white.withAlphaComponent(0.2).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 0.75
        line.move(to: NSPoint(x: cellFrame.minX, y: cellFrame.midY))
        line.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.midY))
        line.stroke()
    }
}

final class SummaryTextView: NSTextView, NSTextViewDelegate {
    var generation: UUID?
    var plainText = false
    var rendered: String?
    var pending: String?
    private var applying = false
    private struct Fade { var range: NSRange; let began: TimeInterval }
    private var fades: [Fade] = []
    private var fadeTask: Task<Void, Never>?

    func stopFades() {
        fadeTask?.cancel(); fadeTask = nil; fades.removeAll()
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    private func fadeNewText(from start: Int) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let storage = textStorage,
              start < storage.length, selectedRange().length == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Preserve in-progress fades when the next streamed chunk arrives. Completed text stays still.
        fades = fades.compactMap { fade in
            guard fade.range.location < start else { return nil }
            var kept = fade; kept.range.length = min(kept.range.length, start - kept.range.location); return kept
        }
        let string = storage.string as NSString
        var position = start, line = 0
        while position < storage.length {
            let paragraph = string.lineRange(for: NSRange(location: position, length: 0))
            let end = min(NSMaxRange(paragraph), storage.length)
            fades.append(Fade(range: NSRange(location: position, length: end - position), began: now + min(Double(line) * 0.035, 0.18)))
            position = end; line += 1
        }
        updateFades()
        guard fadeTask == nil else { return }
        fadeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard let self else { return }
                self.updateFades()
                if self.fades.isEmpty { self.fadeTask = nil; return }
            }
        }
    }

    private func updateFades() {
        guard let storage = textStorage, let manager = layoutManager else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for fade in fades {
            let range = NSIntersectionRange(fade.range, NSRange(location: 0, length: storage.length))
            guard range.length > 0 else { continue }
            let progress = max(0, min(1, (now - fade.began) / 0.4))
            if progress >= 1 { manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
            else {
                storage.enumerateAttribute(.foregroundColor, in: range) { value, part, _ in
                    let color = (value as? NSColor) ?? .labelColor
                    var resolved = NSColor.white
                    effectiveAppearance.performAsCurrentDrawingAppearance {
                        resolved = color.usingColorSpace(.deviceRGB) ?? .white
                    }
                    manager.addTemporaryAttribute(.foregroundColor, value: resolved.withAlphaComponent(resolved.alphaComponent * (0.12 + 0.88 * progress)), forCharacterRange: part)
                }
            }
        }
        fades.removeAll { now - $0.began >= 0.4 }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Enable keyboard selection/scrolling only while this requested popup still owns focus.
        if window?.isKeyWindow == true { window?.makeFirstResponder(self) }
    }

    func render(_ text: String) {
        let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        applying = true
        let old = Array((textStorage?.string ?? "").utf16)
        rendered = text; pending = nil
        textStorage?.setAttributedString(plainText
            ? SidekickSelectableMarkdown.styled(SidekickMarkdownDocument.Fragment.plain(text).attributed,
                style: .init(compact: false, heading: nil, code: false, bold: false, alignment: .left, bodyPointSize: 16))
            : SummaryReader.attributed(text))
        if let container = textContainer { layoutManager?.ensureLayout(for: container) }
        sizeToFit()
        enclosingScrollView?.contentView.scroll(to: origin)
        if let scroll = enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        applying = false
        let current = Array((textStorage?.string ?? "").utf16)
        let prefix = zip(old, current).prefix(while: { $0 == $1 }).count
        fadeNewText(from: prefix)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !applying, selectedRange().length > 0 { stopFades() }
        guard !applying, selectedRange().length == 0, let pending else { return }
        render(pending)
    }

    func clear() {
        stopFades()
        applying = true; pending = nil; rendered = nil; generation = nil
        textStorage?.setAttributedString(NSAttributedString(string: "")); delegate = nil
    }
}
