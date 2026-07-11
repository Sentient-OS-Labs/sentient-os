//
//  GiftShareImage.swift
//  Sentient OS macOS  ·  Views/
//
//  The gift letter as a keepsake — a poster-framed PNG of the welcome letter, saved to the Desktop
//  from the letter's "Save to Desktop" button. The composition: the letter on OLED black inside the
//  welcome-gradient hairline, and a quiet branding footer below it (the orb + wordmark, the one-line
//  pitch, sentient-os.ai) so a shared screenshot carries its own attribution. The body renders
//  through the SAME LetterBody as the on-screen letter, so what you read is exactly what you save.
//
//  Key pieces:
//   - GiftShareView                        (the export composition; #Preview'd for design work)
//   - GiftShareImage.save(letter:) → URL   (ImageRenderer @2x → PNG on the Desktop, never overwrites)
//

import SwiftUI

/// The export composition: the gift letter card + the branding footer, on true black.
/// Takes the built Briefing (not raw markdown) — the gift init promotes `# Title` out of the letter
/// text, so the briefing is the only faithful carrier of both.
struct GiftShareView: View {
    let briefing: Briefing

    /// The export's point width; the PNG renders at 2x (1520 px) for retina-crisp sharing.
    static let width: CGFloat = 760

    var body: some View {
        VStack(spacing: 26) {
            // The letter card — the same frame the expanded letter wears in the app.
            VStack(alignment: .leading, spacing: 0) {
                MonoCaps(briefing.kicker, size: 10, tracking: 2.2, color: briefing.accent)
                Text(briefing.title)
                    .font(.system(size: 30, design: .serif)).foregroundStyle(.white)
                    .padding(.top, 8)
                LetterBody(text: briefing.letter ?? briefing.body, accent: briefing.accent)
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(34)
            .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(BriefingCard.welcomeGradient, lineWidth: 1))

            // The branding colophon — left-aligned flush with the card, one shared edge (wordmark,
            // tagline, and URL all start together), so a shared screenshot carries its attribution
            // like a poster credit, not a greeting card.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    OrbMark(size: 16)
                    Text("Sentient OS")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                Text("On-device intelligence that understands your entire life to proactively help you. Open-source & free.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                MonoCaps("sentient-os.ai", size: 10, tracking: 2.4, color: .white.opacity(0.4))
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 34)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

enum GiftShareImage {

    enum ShareError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "Couldn't render the gift image." }
    }

    /// Render the letter as a @2x PNG and save it to the Desktop as "Gift from Sentient.png"
    /// (counter-suffixed if one already exists — a keepsake is never overwritten). Returns the file.
    @MainActor
    static func save(briefing: Briefing) throws -> URL {
        let renderer = ImageRenderer(content: GiftShareView(briefing: briefing))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: GiftShareView.width, height: nil)
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw ShareError.renderFailed }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        var url = desktop.appendingPathComponent("Gift from Sentient.png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("Gift from Sentient \(n).png"); n += 1
        }
        try png.write(to: url)
        Log("GiftShareImage: saved the gift keepsake → \(url.lastPathComponent) (\(png.count) bytes)")
        return url
    }
}

#Preview("Gift share image") {
    GiftShareView(briefing: Briefing(fromGiftMarkdown: """
    # The System Builder's Map

    I just analyzed your entire digital life to understand you. So much stands out :)
    ### Something you might not know about yourself

    **Your real pattern is not just building AI products; it is turning recurring ambiguity into reusable systems.**
    In IB Math AA HL, you made decision-tree guides for integration, trig, logs, complex numbers, and proofs. Sentient OS is the same reflex at startup scale: take the chaos of screenshots, files, notes, and messages, then compress it into a queryable vault.

    ## Also noticed

    ✦ Your breakout projects keep starting from Apple-shaped constraints: Writing Tools as an open-source Apple Intelligence port, and Sentient's on-device macOS layer.
    ✦ You care about assistants having the right "operating manual" for a person: you maintain prompts across ChatGPT, Claude, Gemini, and Perplexity.
    ✦ Your public technical credibility is unusually concrete: 30,000+ Writing Tools users, WIRED coverage, and a 2025 UMass Tech Challenge win.

    -- Your Sentient
    """))
}
