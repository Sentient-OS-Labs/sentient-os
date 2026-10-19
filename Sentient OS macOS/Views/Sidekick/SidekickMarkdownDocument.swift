// Foundation's CommonMark parser supplies both structure and source positions. Never infer
// reply quotes by searching the entire message: repeated text must refer to the selected run.
import Foundation

nonisolated struct SidekickMarkdownDocument: Sendable {
    struct Mapping: Sendable {
        let displayed: NSRange
        let source: NSRange
        let exact: Bool
    }
    struct Fragment: Sendable {
        let attributed: AttributedString
        let mappings: [Mapping]
        var text: String { String(attributed.characters) }

        /// AppKit uses UTF-16 selection ranges. Expand transformed entities/escapes to their
        /// parser-provided source span; across inline formatting, include the intervening syntax.
        /// The result is always an exact contiguous substring of the original stored Markdown.
        func sourceQuote(for selection: NSRange, in source: String) -> String? {
            let rendered = text as NSString
            guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
                  selection.location <= rendered.length, selection.length <= rendered.length - selection.location else { return nil }
            let selection = rendered.rangeOfComposedCharacterSequences(for: selection)
            let pieces = mappings.compactMap { mapping -> NSRange? in
                let intersection = NSIntersectionRange(selection, mapping.displayed)
                guard intersection.length > 0 else { return nil }
                if mapping.exact {
                    return NSRange(location: mapping.source.location + intersection.location - mapping.displayed.location,
                                   length: intersection.length)
                }
                return mapping.source
            }
            guard let first = pieces.first else { return nil }
            let range = pieces.dropFirst().reduce(first, NSUnionRange)
            guard let valid = Range(range, in: source) else { return nil }
            let quote = String(source[valid])
            return quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : quote
        }

        static func plain(_ text: String, sourceOffset: Int = 0) -> Self {
            Self(attributed: AttributedString(text), mappings: [Mapping(displayed: NSRange(location: 0, length: text.utf16.count),
                source: NSRange(location: sourceOffset, length: text.utf16.count), exact: true)])
        }
    }
    struct Decoration: Sendable {
        var heading: Int?
        var listDepth = 0
        var marker: String?
        var quoteDepth = 0
    }
    struct Table: Sendable {
        struct Cell: Sendable { let column: Int; let fragment: Fragment }
        struct Row: Sendable { let header: Bool; var cells: [Cell] }
        let columns: [PresentationIntent.TableColumn]
        var rows: [Row]
    }
    enum Block: Sendable {
        case text(Fragment, Decoration)
        case code(Fragment, language: String?, Decoration)
        case table(Table, Decoration)
        case rule
    }

    let source: String
    let blocks: [Block]
    /// Large messages retain all bytes, but only a bounded prefix runs through the parser.
    /// The remaining original text is available in a disclosure rather than silently dropped.
    let remainder: Fragment?
    static let maximumParsedBytes = 65_536
    static let maximumBlocks = 300

    init(markdown: String) {
        source = markdown
        var end = markdown.startIndex, count = 0
        while end < markdown.endIndex {
            let next = markdown.index(after: end)
            let bytes = markdown[end..<next].utf8.count
            if count + bytes > Self.maximumParsedBytes { break }
            count += bytes; end = next
        }
        let prefix = String(markdown[..<end])
        remainder = end == markdown.endIndex ? nil : .plain(String(markdown[end...]), sourceOffset: prefix.utf16.count)
        guard !prefix.isEmpty else { blocks = []; return }
        guard let parsed = try? AttributedString(markdown: prefix, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)) else {
            blocks = [.text(.plain(prefix), Decoration())]; return
        }
        let leaves = Self.leaves(parsed, source: prefix)
        // Pathological Markdown can contain tens of thousands of tiny blocks. Its exact text
        // stays selectable, without constructing an equally large native view hierarchy.
        guard leaves.count <= Self.maximumBlocks else {
            blocks = [.text(.plain(prefix), Decoration())]; return
        }
        var result: [Block] = []
        var seenItems = Set<Int>()
        var index = 0
        while index < leaves.count {
            let leaf = leaves[index]
            let decoration = Self.decoration(leaf.components, seenItems: &seenItems)
            if let tableIntent = leaf.components.first(where: { if case .table = $0.kind { true } else { false } }),
               case .table(let columns) = tableIntent.kind {
                var table = Table(columns: columns, rows: [])
                var previousRow: Int?
                while index < leaves.count, leaves[index].components.contains(where: { $0.identity == tableIntent.identity }) {
                    let cell = leaves[index]
                    let row = cell.components.first { if case .tableHeaderRow = $0.kind { true } else if case .tableRow = $0.kind { true } else { false } }
                    let column = cell.components.compactMap { component -> Int? in
                        if case .tableCell(let column) = component.kind { column } else { nil }
                    }.first ?? 0
                    if previousRow != row?.identity || table.rows.isEmpty {
                        table.rows.append(Table.Row(header: row?.kind == .tableHeaderRow, cells: []))
                        previousRow = row?.identity
                    }
                    table.rows[table.rows.count - 1].cells.append(.init(column: column, fragment: cell.fragment))
                    index += 1
                }
                result.append(.table(table, decoration)); continue
            }
            switch leaf.components.first?.kind {
            case .codeBlock(let language): result.append(.code(leaf.fragment, language: language, decoration))
            case .thematicBreak: result.append(.rule)
            default: result.append(.text(leaf.fragment, decoration))
            }
            index += 1
        }
        // Unsupported empty/raw-HTML input remains visible as text. No HTML is executed and no
        // remote images are fetched by this renderer.
        blocks = result.isEmpty ? [.text(.plain(prefix), Decoration())] : result
    }

    private struct Leaf {
        let components: [PresentationIntent.IntentType]
        var fragment: Fragment
    }
    private static func leaves(_ parsed: AttributedString, source: String) -> [Leaf] {
        var result: [Leaf] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let text = String(parsed[run.range].characters)
            var mapping: Mapping?
            if let position = run.markdownSourcePosition, let stringRange = Range(position, in: source) {
                var range = NSRange(stringRange, in: source)
                let raw = String(source[stringRange])
                var exact = raw == text
                // Fenced code's source position includes its fences; locate its literal body
                // inside that one source span, never in another repeated code block.
                if !exact, components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }),
                   let body = raw.range(of: text), !text.isEmpty,
                   raw.range(of: text, range: body.upperBound..<raw.endIndex) == nil {
                    range = NSRange(location: range.location + NSRange(body, in: raw).location, length: text.utf16.count)
                    exact = true
                }
                mapping = Mapping(displayed: NSRange(location: 0, length: text.utf16.count), source: range, exact: exact)
            }
            let fragment = Fragment(attributed: AttributedString(parsed[run.range]), mappings: mapping.map { [$0] } ?? [])
            if let last = result.last, last.components.first?.identity == components.first?.identity {
                let offset = last.fragment.text.utf16.count
                let mappings = last.fragment.mappings + fragment.mappings.map {
                    Mapping(displayed: NSRange(location: $0.displayed.location + offset, length: $0.displayed.length), source: $0.source, exact: $0.exact)
                }
                result[result.count - 1].fragment = Fragment(attributed: last.fragment.attributed + fragment.attributed, mappings: mappings)
            } else { result.append(Leaf(components: components, fragment: fragment)) }
        }
        return result
    }
    private static func decoration(_ components: [PresentationIntent.IntentType], seenItems: inout Set<Int>) -> Decoration {
        var result = Decoration()
        for (index, component) in components.enumerated() {
            switch component.kind {
            case .header(let level): result.heading = level
            case .blockQuote: result.quoteDepth += 1
            case .listItem(let ordinal):
                result.listDepth += 1
                if result.listDepth == 1, seenItems.insert(component.identity).inserted {
                    let ordered = components.dropFirst(index + 1).first?.kind == .orderedList
                    result.marker = ordered ? "\(ordinal)." : "•"
                }
            default: break
            }
        }
        return result
    }
}
