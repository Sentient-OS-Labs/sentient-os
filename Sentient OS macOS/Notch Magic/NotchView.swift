//
//  NotchView.swift
//  Sentient OS macOS
//
//  The notch overlay's content — a Dynamic-Island-grade living object. `NotchView` is the thin
//  reactive binder (reads CommandCoordinator); `NotchContent` is the pure, previewable visual that
//  draws the morphing NotchShape, the camera-flanking content (spinning logo · status · STOP), the
//  serif→mono read-back dissolve, and the flowing Sentient edge glow that says "the AI is working".
//
//  The shape, size, radii, content and glow all animate together off `phase` (one spring) so nothing
//  ever hard-cuts. Only the STOP button is hit-testable; everything else passes clicks through. The
//  panel host + positioning live in NotchWindowController. Doc: Documentation/Notch Magic/.
//

import SwiftUI
import AppKit

// MARK: - Sizing (per phase), derived from the display's real notch (or a default)

struct NotchMetrics: Equatable {
    var hardwareNotch: CGSize?              // nil = this display has no physical notch

    var hasPhysicalNotch: Bool { hardwareNotch != nil }
    var baseWidth: CGFloat { max(hardwareNotch?.width ?? 0, 200) }
    var baseHeight: CGFloat { max(hardwareNotch?.height ?? 0, 32) }

    var topRowHeight: CGFloat { baseHeight }   // the camera band — logo/control sit at its level
    var captionHeight: CGFloat { 18 }          // the status text row — kept tight so the notch stays short
    var centerGap: CGFloat { 64 }              // keep logo/control clear of the camera
    var hPad: CGFloat { 18 }                   // clearance so the logo/mic clear the rounded corners
    var controlSlot: CGFloat { 17 }            // the square both the logo AND every right control fill, so they twin exactly (same size, same optical center)
    var topPad: CGFloat { 0 }
    var bottomPad: CGFloat { 4 }
    var fieldRowHeight: CGFloat { 30 }         // the tap-to-type field row (below the camera band)
    /// `baseHeight` (auxiliaryTopLeftArea) reports a hair shallower than the notch's real black cutout, so
    /// the mic state (sized to exactly baseHeight) falls short and the hardware lip peeks below. Add a
    /// small cover so it fully fills the hardware notch. (Other states are taller and already overshoot.)
    var notchBottomCover: CGFloat { 2 }
    /// The most the notch grows to fit a long spoken instruction before the caption truncates.
    var maxReadBackLines: Int { 10 }

    var runningWidth: CGFloat { max(baseWidth + 160, 360) }

    /// The running/finishing notch height for a given caption-row height (the only variable bit). Kept as
    /// tight as possible — camera band + the text + a small bottom pad — so it eats minimally into apps.
    func runningHeight(caption: CGFloat) -> CGFloat { baseHeight + caption + bottomPad }

    /// Size for a phase. When a voice read-back is showing, the running notch grows DOWN to fit the whole
    /// heard instruction (capped at `maxReadBackLines`); once it dissolves to the codex line it shrinks back.
    func size(for phase: NotchPhase, readBack: String? = nil, remembering: String? = nil) -> CGSize {
        switch phase {
        case .hidden:
            // Retract target: collapse to the EXACT hardware notch (radius matched in `radii`) so the black
            // shell merges seamlessly into the real cutout, then orders out invisibly — a physical retract,
            // not a fade. (A notch-less display has nothing to merge into → the view fades instead, see
            // `shellOpacity`; base size keeps that fallback sane.)
            return hardwareNotch ?? CGSize(width: baseWidth, height: baseHeight)
        case .opening, .listening, .transcribing:
            return CGSize(width: baseWidth + 76, height: baseHeight + notchBottomCover)   // fully fill the hardware notch
        case .typing:
            return CGSize(width: max(baseWidth + 240, 480), height: baseHeight + fieldRowHeight + bottomPad + 4)
        case .running, .finishing:
            let caption: CGFloat
            if remembering != nil { caption = captionHeight }                          // single "Remembering …" line
            else if readBack?.isEmpty == false { caption = readBackCaptionHeight(readBack!) }
            else { caption = captionHeight }
            return CGSize(width: runningWidth, height: runningHeight(caption: caption))
        case .notice:
            return CGSize(width: max(baseWidth + 120, 320), height: baseHeight + captionHeight + bottomPad)
        }
    }

    func radii(for phase: NotchPhase) -> (top: CGFloat, bottom: CGFloat) {
        switch phase {
        case .opening, .listening, .transcribing, .hidden:
            // The macOS notch's OWN corner radius (DynamicNotch's tuned match: baseHeight / 3), so at
            // the real notch height the mic state reads as the genuine notch — and the hidden state
            // collapses to that same shape so it merges cleanly into the physical cutout on dismiss.
            let r = baseHeight / 3
            return (top: max(r - 4, 0), bottom: r)
        default:
            return (top: 8, bottom: min(max(size(for: phase).height * 0.24, 8), 18))
        }
    }

    // MARK: Read-back sizing — grow the notch to fit the whole heard instruction (capped)

    /// Serif-italic font matching the read-back caption — used to measure the full spoken text's height.
    private static let readBackFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: serif.withSymbolicTraits(.italic), size: 13) ?? base
    }()

    private var readBackLineHeight: CGFloat {
        let f = Self.readBackFont
        return f.ascender - f.descender + f.leading
    }

    /// The read-back wrapped in elegant curly quotes — used for BOTH the display and the height
    /// measurement, so they always agree (a long quoted instruction never clips its last line).
    static func quoted(_ text: String) -> String { "“\(text)”" }

    /// Rendered height of the (quoted) `text` wrapped at the running caption width (uncapped, unfloored).
    private func readBackMeasuredHeight(_ text: String) -> CGFloat {
        (Self.quoted(text) as NSString).boundingRect(
            with: CGSize(width: max(runningWidth - hPad * 2, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.readBackFont]).height
    }

    /// Caption-row height needed to show `text` in full at the running width — capped at `maxReadBackLines`
    /// and floored at the normal caption height (so a one-line instruction doesn't shrink the notch).
    func readBackCaptionHeight(_ text: String) -> CGFloat {
        max(min(ceil(readBackMeasuredHeight(text)) + 4, maxReadBackCaptionHeight), captionHeight)
    }

    /// The tallest the caption row can get (the read-back cap) — drives the fixed canvas size.
    var maxReadBackCaptionHeight: CGFloat { ceil(readBackLineHeight * CGFloat(maxReadBackLines)) + 4 }

    /// How many lines the read-back wraps to (1...maxReadBackLines).
    func readBackLineCount(_ text: String) -> Int {
        max(1, min(Int((readBackMeasuredHeight(text) / readBackLineHeight).rounded()), maxReadBackLines))
    }

    /// How long to linger on the read-back, scaling LINEARLY by line count: 4s for a one-liner up to 9s
    /// at the line cap. (Running width is constant across screens, so a default `NotchMetrics` reads true.)
    static func readBackDuration(for text: String) -> Double {
        let m = NotchMetrics(hardwareNotch: nil)
        let t = Double(m.readBackLineCount(text) - 1) / Double(max(m.maxReadBackLines - 1, 1))
        return 4 + t * 5
    }

    static let preview = NotchMetrics(hardwareNotch: CGSize(width: 200, height: 37))
}

// MARK: - The reactive binder

struct NotchView: View {
    let coordinator: CommandCoordinator
    let metrics: NotchMetrics

    var body: some View {
        NotchContent(phase: coordinator.phase,
                     readBack: coordinator.readBack,
                     statusLine: coordinator.run.statusLine,
                     remembering: coordinator.run.remembering,
                     metrics: metrics,
                     onStop: { coordinator.stop() },
                     onSubmitText: { coordinator.submitTyped($0) })
    }
}

// MARK: - The pure visual

struct NotchContent: View {
    let phase: NotchPhase
    let readBack: String?
    let statusLine: String
    var remembering: String? = nil
    let metrics: NotchMetrics
    var onStop: () -> Void = {}
    var onSubmitText: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let size = metrics.size(for: phase, readBack: readBack, remembering: remembering)
        let radii = metrics.radii(for: phase)
        let visible = phase != .hidden
        // The notch sits FLUSH at the screen's top edge — its concave top corners visible on the bezel
        // (the genuine-notch flare). The glow traces only the sides + bottom (NotchSkirtShape), so the
        // bezel line never lights up and there's no need to bleed the window off-screen to hide a top glow.

        ZStack(alignment: .top) {
            glow(radii, lineWidth: 13, blur: 17, strength: 0.75)   // wide soft outer halo (behind the fill)
            glow(radii, lineWidth: 6,  blur: 6,  strength: 0.95)   // denser halo hugging the edge
            NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                .fill(.black)
                .allowsHitTesting(false)
            glow(radii, lineWidth: 3,  blur: 0.6, strength: 1.0)   // crisp bright rim, over the fill
            content(size: size)
                .opacity(visible ? 1 : 0)              // icons + caption dissolve as the shell retracts into the cutout
                .clipShape(NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom))
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .combine)        // on the notch itself, never the full canvas
        .accessibilityLabel(a11yLabel)
        .scaleEffect(visible ? 1 : 0.94, anchor: .top)
        .opacity(shellOpacity)                           // shell stays opaque & MERGES into a real notch on dismiss (fades only if there's none)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: phase)
        .animation(morph, value: readBack)               // grow/shrink the notch as the read-back appears/clears
        .animation(morph, value: remembering)            // shrink back to one line when "Remembering" takes over
        .onChange(of: phase) { _, newPhase in
            if newPhase == .typing {
                draft = ""
                DispatchQueue.main.async { fieldFocused = true }   // focus once the panel has become key
            } else {
                fieldFocused = false
            }
        }
    }

    private var morph: Animation {
        // Longer + bouncier than a flat ease — fast out of the gate, then a gentle overshoot-and-settle
        // (the Dynamic Island "alive" curve). Lower damping = visible bounce; ~0.52 response = slightly slower.
        reduceMotion ? .easeInOut(duration: 0.24) : .spring(response: 0.52, dampingFraction: 0.72)
    }

    // MARK: Content

    private func content(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SpinningLogo(size: metrics.controlSlot, fast: phase == .running)
                Spacer(minLength: metrics.centerGap)
                rightControl
                    .frame(width: metrics.controlSlot, height: metrics.controlSlot)   // same square as the logo → twinned size + center axis
                    .id(controlKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            .frame(height: metrics.topRowHeight)

            if phase == .typing {
                typingField
                    .frame(height: metrics.fieldRowHeight)
                    .transition(.opacity)
            } else if showsCaption {
                caption
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, metrics.hPad)
        .padding(.top, metrics.topPad)
        .padding(.bottom, metrics.bottomPad)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    @ViewBuilder private var rightControl: some View {
        switch phase {
        case .opening, .listening:
            // Shared identity (controlKey) → .opening intensifies INTO .listening (a gentle "lean in"),
            // never a cross-fade. The full behind-mic color dance is a later polish pass.
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(phase == .listening ? 0.92 : 0.5))
                .scaleEffect(phase == .listening ? 1 : 0.9)
                .allowsHitTesting(false)
        case .transcribing:
            ProgressView().controlSize(.small).tint(.white).scaleEffect(0.8).allowsHitTesting(false)
        case .typing:
            Image(systemName: "return")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(draft.isEmpty ? 0.3 : 0.7))
                .allowsHitTesting(false)
        case .running:
            NotchStopButton(action: onStop)
        case .finishing(let outcome):
            Image(systemName: Self.outcomeSymbol(outcome))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Self.outcomeColor(outcome))
                .allowsHitTesting(false)
        case .hidden, .notice:
            Color.clear.frame(width: 1, height: 18)
        }
    }

    /// The tap-to-type field — a focused TextField that fires the typed task on ⏎ (Esc / empty cancels).
    private var typingField: some View {
        ZStack(alignment: .leading) {
            if draft.isEmpty {
                Text("type a task…")
                    .font(.system(size: 13, design: .serif)).italic()
                    .foregroundStyle(.white.opacity(0.4))
                    .allowsHitTesting(false)
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .tint(Theme.accent)
                .focused($fieldFocused)
                .onSubmit { let t = draft; draft = ""; onSubmitText(t) }
        }
    }

    /// The bottom-row text. Running shows the serif read-back, dissolving into the mono codex line.
    @ViewBuilder private var caption: some View {
        switch phase {
        case .running:
            Group {
                if let remembering {
                    rememberingCaption(remembering)                 // gradient, blooming "Remembering" + the note
                } else if let readBack {
                    Text(NotchMetrics.quoted(readBack))              // the heard instruction, in quotes — wraps in full
                        .font(.system(size: 13, design: .serif)).italic()
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(metrics.maxReadBackLines)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Text(statusLine.isEmpty ? "working…" : statusLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentTransition(.interpolate)             // morph only the CHANGED glyphs in place; shared text stays put
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(runningCaptionKey)
            .transition(.blurDissolve)                               // remembering ⇄ read-back ⇄ codex line: a fancy blur-dissolve-pop
            .animation(.spring(duration: 0.7, bounce: 0.35), value: runningCaptionKey)
            .animation(.easeInOut(duration: 0.35), value: statusLine)
            .allowsHitTesting(false)
        case .finishing:
            Text(statusLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.tail)
                .allowsHitTesting(false)
        case .notice(let message):
            Text(message)
                .font(.system(size: 13, design: .serif)).italic()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    /// 3-way identity for the running caption, so switching remembering ⇄ read-back ⇄ status blur-dissolves
    /// (note / status changes WITHIN a state morph in place instead).
    private var runningCaptionKey: Int {
        if remembering != nil { return 2 }
        if readBack != nil { return 1 }
        return 0
    }

    /// The "it knows me" beat: a gradient, gently-blooming "Remembering" with the note codex is reading
    /// morphing alongside it (the word stays still while the file flickers by). Gradient = the analysis
    /// screen's "Everything." palette.
    private func rememberingCaption(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bloom = reduceMotion ? 0.5 : (sin(t * 2 * .pi / 1.5) + 1) / 2   // a 1.5s breathing glow
                Text("Remembering")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Self.rememberingGradient)
                    .opacity(0.78 + 0.22 * bloom)                                   // breathe via opacity only — no scale bounce
            }
            .fixedSize()
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle)
                    .contentTransition(.interpolate)               // morph the note per file; "Remembering" stays put
                    .animation(.easeInOut(duration: 0.3), value: note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The analysis screen's "Everything." gradient (ProcessingView), reused for the "Remembering" word.
    private static let rememberingGradient = LinearGradient(
        colors: [Color(red: 0.66, green: 0.42, blue: 0.85),
                 Color(red: 0.91, green: 0.45, blue: 0.75),
                 Color(red: 0.96, green: 0.55, blue: 0.50),
                 Color(red: 0.95, green: 0.70, blue: 0.35)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: Edge glow (the "AI is working" signal — running + finishing)

    /// One glow layer at a given thickness/softness, faded by `glowStrength * strength`. Stacking a few of
    /// these (wide haze → dense halo → crisp rim) builds the thick, vivid edge glow.
    private func glow(_ radii: (top: CGFloat, bottom: CGFloat),
                      lineWidth: CGFloat, blur: CGFloat, strength: Double) -> some View {
        glowLayer(radii, lineWidth: lineWidth, blur: blur)
            .opacity(glowStrength * strength)
            .allowsHitTesting(false)
    }

    /// The rotating spectrum, MASKED by the notch-skirt stroke. The mask shape lives in the regular body
    /// (NOT inside the TimelineView), so its geometry interpolates in LOCKSTEP with the black fill during
    /// a morph — the edges light up in place, never a separate rounded-rect snapping on. The layer is
    /// always present; its brightness rides `glowStrength` via opacity. Only the gradient ANGLE ticks
    /// per-frame; the skirt (sides + rounded bottom, no top) keeps the glow off the bezel line.
    private func glowLayer(_ radii: (top: CGFloat, bottom: CGFloat),
                           lineWidth: CGFloat, blur: CGFloat) -> some View {
        // The gradient must extend PAST the stroke + blur on every edge — including the bottom, which sits
        // right at the notch's frame edge. So we grow the layer (negative padding) and inset the skirt mask
        // by the same margin: the gradient then bleeds beyond ALL sides equally (no thin bottom edge).
        let m = lineWidth / 2 + blur + 6
        return TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 0 : (t.truncatingRemainder(dividingBy: 6.5) / 6.5) * 360
            let breathe = (sin(t * 2 * .pi / 3.2) + 1) / 2   // gentle alive-ness
            AngularGradient(colors: GlowHalo.stops, center: .center, angle: .degrees(angle))
                .opacity(0.88 + 0.12 * breathe)
        }
        .mask(
            NotchSkirtShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(m)
        )
        .blur(radius: blur)
        .padding(-m)
    }

    private var glowStrength: Double {
        switch phase {
        case .hidden:    return 0
        case .finishing: return 0.9
        default:         return 1.0   // alive from the moment the notch appears — opening, listening, typing, running…
        }
    }

    /// The black shell's opacity. On dismiss into a REAL notch it stays fully opaque — the shape collapses to
    /// the cutout's exact silhouette and merges (then the window orders out invisibly), so the retract reads
    /// as a physical "suck back into the notch", never a fade. With no hardware notch there's nothing to merge
    /// into, so the shell simply fades out. (The inner content + glow dissolve on their own regardless.)
    private var shellOpacity: Double {
        if phase != .hidden { return 1 }
        return metrics.hasPhysicalNotch ? 1 : 0
    }

    // MARK: Helpers

    private var showsCaption: Bool {
        switch phase { case .running, .finishing, .notice: return true; default: return false }
    }

    /// Identity for the right-control cross-fade (mic → spinner → stop → glyph).
    private var controlKey: Int {
        switch phase {
        case .hidden: return 0
        case .opening, .listening: return 1   // shared identity → .opening intensifies INTO .listening
        case .transcribing: return 2
        case .running: return 3
        case .finishing: return 4
        case .notice: return 5
        case .typing: return 6
        }
    }

    private var a11yLabel: String {
        switch phase {
        case .hidden: return ""
        case .opening, .listening, .transcribing: return "Sentient is listening"
        case .typing: return "Type a task for Sentient"
        case .running: return "Sentient is working. \(statusLine)"
        case .finishing: return statusLine
        case .notice(let m): return m
        }
    }

    private static func outcomeSymbol(_ o: CommandRunModel.Outcome) -> String {
        switch o { case .success: return "checkmark"; case .stopped: return "stop.fill"; case .failed: return "xmark" }
    }
    private static func outcomeColor(_ o: CommandRunModel.Outcome) -> Color {
        switch o {
        case .success: return Theme.Ink.mint
        case .stopped: return .white.opacity(0.6)
        case .failed:  return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }
}

// MARK: - The notch's one interactive element

private struct NotchStopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop")
    }
}

// MARK: - Blur-dissolve transition (the serif read-back ⇄ mono codex line morph)

private struct BlurFadeScale: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale)
    }
}

private extension AnyTransition {
    /// A fancy swap: the outgoing text blurs, fades, and gently expands away while the incoming blurs in,
    /// fades up, and springs from slightly small — a dissolve with a satisfying pop. Pair with a bouncy spring.
    static var blurDissolve: AnyTransition {
        .asymmetric(
            insertion: .modifier(active:   BlurFadeScale(radius: 8, opacity: 0, scale: 0.92),
                                 identity: BlurFadeScale(radius: 0, opacity: 1, scale: 1)),
            removal:   .modifier(active:   BlurFadeScale(radius: 8, opacity: 0, scale: 1.05),
                                 identity: BlurFadeScale(radius: 0, opacity: 1, scale: 1)))
    }
}

// MARK: - Previews (Claude's eyes — static look only; motion is tested live)

private struct NotchPreviewStage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.18), .black], startPoint: .top, endPoint: .bottom)
            content
        }
        .frame(width: 560, height: 230)
    }
}

#Preview("listening") {
    NotchPreviewStage { NotchContent(phase: .listening, readBack: nil, statusLine: "", metrics: .preview) }
}
#Preview("typing") {
    NotchPreviewStage { NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: .preview) }
}
#Preview("running · read-back") {
    NotchPreviewStage { NotchContent(phase: .running, readBack: "register me for ZFellows", statusLine: "", metrics: .preview) }
}
#Preview("running · streaming") {
    NotchPreviewStage { NotchContent(phase: .running, readBack: nil, statusLine: "→ filling out the application…", metrics: .preview) }
}
#Preview("finishing") {
    NotchPreviewStage { NotchContent(phase: .finishing(.success), readBack: nil, statusLine: "✓ done", metrics: .preview) }
}
#Preview("notice") {
    NotchPreviewStage { NotchContent(phase: .notice("didn’t catch that"), readBack: nil, statusLine: "", metrics: .preview) }
}
