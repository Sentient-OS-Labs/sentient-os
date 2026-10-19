// Short replies fit their content. This same cached measurement drives rendering and
// pointer hit testing; long or structurally complex replies use the bounded scroll surface.
import AppKit

@MainActor struct SidekickNotchMessageLayout {
    static let minimumHeight: CGFloat = 190
    static let maximumHeight: CGFloat = 286
    static let labelHeight: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
    static let footerHeight: CGFloat = 30
    static let replyHeight: CGFloat = 40
    static let topPad: CGFloat = 4
    static let bottomPad: CGFloat = 10
    static let textVerticalPad: CGFloat = 3

    let size: CGSize

    init(markdown: String, maximumSize: CGSize, cameraHeight: CGFloat,
         outerTopPad: CGFloat, outerBottomPad: CGFloat, horizontalPad: CGFloat) {
        let chrome = cameraHeight + outerTopPad + outerBottomPad
            + Self.labelHeight + 3 * Self.sectionSpacing + Self.footerHeight + Self.replyHeight
            + Self.topPad + Self.bottomPad + 2 * Self.textVerticalPad
        let width = max(1, maximumSize.width - 2 * horizontalPad)
        let textHeight = Self.measuredHeight(markdown, width: width)
        let desired = textHeight.map { chrome + $0 } ?? maximumSize.height
        size = CGSize(width: maximumSize.width,
            height: min(maximumSize.height, max(Self.minimumHeight, ceil(desired))))
    }

    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 64
        cache.totalCostLimit = 256 * 1_024
        return cache
    }()

    private static func measuredHeight(_ markdown: String, width: CGFloat) -> CGFloat? {
        // Never parse a long response in the pointer polling path. UTF-16 is a conservative
        // character bound, including emoji; byte count also caps unusual combining sequences.
        guard markdown.utf8.count <= 4_096, markdown.utf16.count <= 1_000 else { return nil }
        let key = "\(width):\(markdown)" as NSString
        if let value = cache.object(forKey: key) { return value.doubleValue < 0 ? nil : CGFloat(value.doubleValue) }
        let document = SidekickMarkdownDocument(markdown: markdown)
        var height: CGFloat = 0
        for block in document.blocks {
            switch block {
            case .text(let fragment, let decoration):
                var textWidth = width
                if decoration.quoteDepth > 0 { textWidth -= 12 + CGFloat(min(decoration.quoteDepth - 1, 4)) * 8 }
                if decoration.listDepth > 0 { textWidth -= 32 + CGFloat(min(decoration.listDepth - 1, 12)) * 18 }
                let style = SidekickSelectableMarkdown.Style(compact: true, heading: decoration.heading,
                    code: false, bold: false, alignment: .left)
                let text = SidekickSelectableMarkdown.styled(fragment.attributed, style: style)
                let storage = NSTextStorage(attributedString: text)
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: CGSize(width: max(1, textWidth), height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(manager); manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                height += max(ceil(style.pointSize * 1.25), ceil(manager.usedRect(for: container).height) + 1)
                    + (decoration.heading == nil ? 0 : 4)
            case .rule:
                height += 5
            case .code, .table:
                // Their nested scroll/header/grid chrome is deliberately left to the full
                // renderer. The maximum reading surface is both bounded and predictable.
                cache.setObject(-1, forKey: key, cost: markdown.utf8.count)
                return nil
            }
        }
        height += CGFloat(max(0, document.blocks.count - 1)) * 9
        cache.setObject(NSNumber(value: Double(height)), forKey: key, cost: markdown.utf8.count)
        return height
    }
}
