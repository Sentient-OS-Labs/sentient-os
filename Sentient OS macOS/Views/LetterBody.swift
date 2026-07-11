//
//  LetterBody.swift
//  Sentient OS macOS  ·  Views/
//
//  The letter renderer — the editorial Markdown subset our letters use (the gift letter, research
//  briefings), drawn line-by-line: `##`/`###` section headings, `✦ ` accent bullets, a closing
//  sign-off line, and plain paragraphs with `**bold**` inline. A blank line is a paragraph break.
//  (`# H1` is promoted to the card title upstream, but a stray one still renders defensively.)
//  Shared by the expanded letter (LetterView) and the saved share image (GiftShareImage), so what
//  you read is exactly what you save.
//

import SwiftUI

struct LetterBody: View {
    let text: String
    let accent: Color

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                letterBlock(raw.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @ViewBuilder
    private func letterBlock(_ line: String) -> some View {
        if line.isEmpty {
            Color.clear.frame(height: 2)                              // a paragraph break
        } else if line.hasPrefix("### ") {
            Text(Self.inline(String(line.dropFirst(4))))             // soulful subhead (serif italic)
                .font(.system(size: 16, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.92))
                .padding(.top, 6)
        } else if line.hasPrefix("## ") {
            MonoCaps(String(line.dropFirst(3)).uppercased(), size: 10, tracking: 2.2,
                     color: accent.opacity(0.95))                     // section whisper (mono-caps)
                .padding(.top, 12)
        } else if line.hasPrefix("# ") {
            Text(Self.inline(String(line.dropFirst(2))))             // a stray title, defensive
                .font(.system(size: 22, design: .serif)).foregroundStyle(.white)
                .padding(.top, 4)
        } else if let bullet = Self.bulletText(line) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("✦").font(.system(size: 12)).foregroundStyle(accent)
                Text(Self.inline(bullet))
                    .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.84)).lineSpacing(4.5)
            }
        } else if Self.isSignoff(line) {
            Text(Self.inline(line))                                  // "-- Your Sentient"
                .font(.system(size: 13, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 10)
        } else {
            Text(Self.inline(line))
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.84)).lineSpacing(5)
        }
    }

    /// "✦ …" (tolerating a stray word-joiner / nbsp the model sometimes slips in) → the bullet's text;
    /// nil if the line isn't a bullet.
    private static func bulletText(_ line: String) -> String? {
        guard line.first == "✦" else { return nil }
        let rest = line.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\u{2060}" || $0 == "\u{00A0}" }
        return rest.isEmpty ? nil : String(rest)
    }

    /// A closing line like "-- Your Sentient" / "— your Sentient" (line-start only, so inline em-dashes
    /// mid-paragraph aren't mistaken for a sign-off).
    private static func isSignoff(_ line: String) -> Bool {
        line.hasPrefix("--") || line.hasPrefix("—") || line.hasPrefix("– ")
    }

    /// Inline-markdown parse (**bold** etc.) so letters can carry a skimmable bold rail.
    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
