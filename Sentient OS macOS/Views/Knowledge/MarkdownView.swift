//
//  MarkdownView.swift
//  Sentient OS macOS
//
//  Renders a knowledge-base note as editorial SwiftUI. The vault's markdown is a small, verified
//  subset — `#/##/###` headings, paragraphs, `- ` bullets, the odd `---` rule, ``` code fences
//  (the README's vault-map tree lives in one), and very dense [[wikilinks]] (no tables /
//  blockquotes / nested or numbered lists). So this is a tidy block renderer (the same shape as
//  HomeView's LetterView) rather than a heavy markdown dependency: fenced blocks render verbatim
//  in monospace with whitespace intact; every other line renders on its own.
//
//  Inline text goes through AttributedString for **bold** / *italic* / `code` / [text](url); but
//  [[wikilinks]] are pre-split out first and rendered as accent links carrying a custom
//  `sentient-wiki:` URL. An OpenURLAction routes those to onNavigate (jump to the note) and real
//  http links to onExternal. Unresolved wikilinks render dimmed and inert.
//
//  Doc: Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md
//

import SwiftUI
import AppKit

struct MarkdownView: View {
    let markdown: String
    /// Does this wikilink target resolve to a real note? (drives link vs. dimmed styling)
    var exists: (String) -> Bool = { _ in false }
    /// A resolved wikilink was tapped — its target title.
    var onNavigate: (String) -> Void = { _ in }
    /// A real external (http/https) link was tapped.
    var onExternal: (URL) -> Void = { _ in }

    private static let wikiScheme = "sentient-wiki:"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .line(let s): line(s)
                case .code(let lines): codeBlock(lines)
                }
            }
        }
        .tint(Theme.knowledgeLink)
        .environment(\.openURL, OpenURLAction { url in
            if url.absoluteString.hasPrefix(Self.wikiScheme) {
                let title = String(url.absoluteString.dropFirst(Self.wikiScheme.count)).removingPercentEncoding ?? ""
                onNavigate(title)
            } else {
                onExternal(url)
            }
            return .handled
        })
    }

    // MARK: Blocks — fenced code is grouped verbatim; everything else is one block per line

    private enum Block {
        case line(String)     // trimmed — the everyday single-line path
        case code([String])   // raw lines, leading whitespace preserved
    }

    /// Group the note into blocks. ``` fences become verbatim code blocks (the fence lines
    /// themselves are dropped; an unterminated fence renders what's there). Runs of bare
    /// box-drawing tree rows (`├── x`) are caught too, for when the model draws the vault map
    /// without a fence — trimming their indentation would destroy the tree.
    private var blocks: [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1   // past the closing fence (or EOF)
                if !body.isEmpty { out.append(.code(body)) }
            } else if isTreeRow(trimmed) {
                var body: [String] = []
                while i < lines.count, isTreeRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    body.append(lines[i]); i += 1
                }
                out.append(.code(body))
            } else {
                out.append(.line(trimmed))
                i += 1
            }
        }
        return out
    }

    /// A box-drawing tree row (`├── x`, `│   └── y`) outside any fence.
    private func isTreeRow(_ trimmed: String) -> Bool {
        guard let first = trimmed.first else { return false }
        return "├└│".contains(first)
    }

    /// A fenced block, verbatim: monospace (the machine's voice), whitespace intact, neutral ink
    /// on a whisper of a panel. The README's vault-map tree is the main resident.
    private func codeBlock(_ lines: [String]) -> some View {
        Text(verbatim: lines.joined(separator: "\n"))
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.78))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.07), lineWidth: 1))
            .padding(.vertical, 10)
    }

    // MARK: One block per line (blank line = spacer)

    @ViewBuilder
    private func line(_ s: String) -> some View {
        if s.isEmpty {
            Color.clear.frame(height: 9)
        } else if s == "---" || s == "***" || s == "___" {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                .padding(.vertical, 12)
        } else if s.hasPrefix("### ") {
            Text(inline(String(s.dropFirst(4))))
                .font(.system(size: 15.5, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.top, 14).padding(.bottom, 2)
        } else if s.hasPrefix("## ") {
            Text(inline(String(s.dropFirst(3))))
                .font(.system(size: 20, design: .serif))
                .foregroundStyle(.white)
                .padding(.top, 20).padding(.bottom, 4)
        } else if s.hasPrefix("# ") {
            Text(inline(String(s.dropFirst(2))))
                .font(.system(size: 25, design: .serif))
                .foregroundStyle(.white)
                .padding(.top, 10).padding(.bottom, 4)
        } else if let bullet = bulletText(s) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").font(.system(size: 15)).foregroundStyle(.white.opacity(0.42))
                Text(inline(bullet))
                    .font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
        } else {
            Text(inline(s))
                .font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.82))
                .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
    }

    /// "- …" / "* …" / "• …" → the bullet's text, else nil.
    private func bulletText(_ s: String) -> String? {
        for marker in ["- ", "* ", "• "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count))
        }
        return nil
    }

    // MARK: Inline — standard markdown + [[wikilinks]]

    /// Build the attributed line: split on `[[wikilink]]` tokens, run the surrounding text through
    /// AttributedString's inline markdown, and turn each wikilink into an accent link (resolved) or
    /// dimmed text (unresolved).
    private func inline(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.range(of: "[[") {
            let before = rest[rest.startIndex..<open.lowerBound]
            if !before.isEmpty { out += markdownInline(String(before)) }
            guard let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) else {
                out += markdownInline(String(rest[open.lowerBound...]))   // unterminated — pass through
                return out
            }
            out += wikilink(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out += markdownInline(String(rest)) }
        return out
    }

    /// `[[Title]]` or `[[Title|alias]]` → a styled run. Resolved → the sky-blue link; unresolved →
    /// dimmed neutral (color here means "you can go somewhere").
    private func wikilink(_ inner: String) -> AttributedString {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        let label = (parts.count > 1 ? String(parts[1]) : String(parts[0])).trimmingCharacters(in: .whitespaces)
        var run = AttributedString(label)
        if exists(target),
           let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: Self.wikiScheme + encoded) {
            run.link = url
            run.foregroundColor = Theme.knowledgeLink
            run.underlineStyle = .single
        } else {
            run.foregroundColor = Color.white.opacity(0.38)   // unresolved — visible but inert
        }
        return run
    }

    /// Inline markdown for a non-wikilink segment (**bold** / *italic* / `code` / [text](url)).
    private func markdownInline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

#Preview("MarkdownView") {
    ScrollView {
        MarkdownView(markdown: """
        Jesai Tarun is building **Sentient OS**, a privacy-first intelligence layer for a person's
        digital life.

        ## Vault Map

        - `Identity/` — who Jesai is. Start with [[Jesai Tarun - Current Portrait]].
        - `Sentient OS/` — product thesis and roadmap. See [[Sentient OS Map]].
        - An *unresolved* one: [[Does Not Exist]].

        ### Something noticed

        His center of gravity is [[Sentient OS - Product Thesis]].

        ## Structure

        ```
        Sentient OS - Knowledge Base/
        ├── Identity/
        │   ├── Jesai Tarun - Current Portrait.md
        │   └── Values and Working Style.md
        ├── Sentient OS/
        │   ├── Product Thesis.md
        │   └── Fundraising/
        │       └── Afore Pre-Seed.md
        └── People/
            └── Aditya Vellanki.md
        ```

        And a fence-less tree, as the model sometimes draws it:

        ├── Identity/
        │   └── Jesai Tarun - Current Portrait.md
        └── People/
        """, exists: { ["jesai tarun - current portrait", "sentient os map", "sentient os - product thesis"].contains($0.lowercased()) })
        .frame(maxWidth: 680, alignment: .leading)
        .padding(40)
    }
    .frame(width: 760, height: 900)
    .background(Color.black)
}
