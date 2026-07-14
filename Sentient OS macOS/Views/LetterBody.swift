//
//  LetterBody.swift
//  Sentient OS macOS  ·  Views/
//
//  The letter renderer — the editorial Markdown subset our letters use (the gift letter, research
//  briefings), drawn line-by-line: `##`/`###` section headings, bullets (`✦ `/`- `/`* `/`• `),
//  numbered items, `---` hairline rules, a closing sign-off line, and plain paragraphs with
//  `**bold**` inline. A blank line is a paragraph break. `neutral` swaps the accent glyphs for
//  quiet ink (research notes); the default accent dress is the gift letter's.
//  (`# H1` is promoted to the card title upstream, but a stray one still renders defensively.)
//  Shared by the expanded letter (LetterView) and the saved share image (GiftShareImage), so what
//  you read is exactly what you save.
//

import SwiftUI

struct LetterBody: View {
    let text: String
    let accent: Color
    var neutral = false   // research notes: quiet ink instead of accent — the house • bullet and
                          // dim mono-caps headings (accent text is unpleasant over a whole read)

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
                     color: neutral ? .white.opacity(0.5) : accent.opacity(0.95))   // section whisper
                .padding(.top, 12)
        } else if line.hasPrefix("# ") {
            Text(Self.inline(String(line.dropFirst(2))))             // a stray title, defensive
                .font(.system(size: 22, design: .serif)).foregroundStyle(.white)
                .padding(.top, 4)
        } else if Self.isRule(line) {
            Rectangle().fill(Color.white.opacity(0.1))               // a `---` rule → hairline divider
                .frame(height: 1)
                .padding(.vertical, 6)
        } else if let bullet = Self.bulletText(line) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if neutral {
                    Text("•").font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.42))
                } else {
                    Text("✦").font(.system(size: 12)).foregroundStyle(accent)
                }
                Text(Self.inline(bullet))
                    .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.84)).lineSpacing(4.5)
            }
        } else if let (number, item) = Self.numberedText(line) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("\(number).").font(.system(size: 13.5)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.42))
                Text(Self.inline(item))
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
    /// nil if the line isn't a bullet. Standard-Markdown bullets ("- " / "* " / "• ") are accepted
    /// too — models slip into vanilla Markdown no matter what the prompt says — and every flavour
    /// renders as the same ✦ accent bullet. "- " needs its space so a "-- your Sentient" sign-off
    /// (and "**bold**"-opening lines for "* ") can never be mistaken for a bullet.
    private static func bulletText(_ line: String) -> String? {
        let rest: Substring
        if line.first == "✦" || line.first == "•" {
            rest = line.dropFirst()
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            rest = line.dropFirst(2)
        } else { return nil }
        let text = rest.drop { $0 == " " || $0 == "\t" || $0 == "\u{2060}" || $0 == "\u{00A0}" }
        return text.isEmpty ? nil : String(text)
    }

    /// "1. …" → the item's number + text; nil if the line isn't a numbered item.
    private static func numberedText(_ line: String) -> (String, String)? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex,
              line[line.startIndex..<dot].allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.first == " " else { return nil }
        let text = rest.drop { $0 == " " }
        return text.isEmpty ? nil : (String(line[..<dot]), String(text))
    }

    /// A `---` horizontal rule (3+ dashes and nothing else). Checked BEFORE the sign-off, which
    /// would otherwise claim it via its "--" prefix.
    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "-" }
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
