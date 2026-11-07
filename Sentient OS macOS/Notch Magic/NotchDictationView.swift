// Voice keeps the surface from which it started: activity, composer or reply.
// The waveform reads local energy independently of transcription/network progress.
// Doc: Documentation - Sidekick - Notch Window & Visual.md
import SwiftUI

@MainActor @Observable
final class DictationPresentation {
    var text = ""
    var connected = false
    var capturing = false
    enum Context {
        case activity, composer
        case reply(SidekickConversationStore.Record)
    }
    private(set) var context: Context = .activity
    var replyMessage: SidekickConversationStore.Record? {
        if case .reply(let message) = context { return message }
        return nil
    }
    var keepsDraft: Bool {
        if case .activity = context { return false }
        return true
    }

    /// Geometry follows the surface the user is already using. Audio lifecycle changes
    /// must never introduce a second, delayed copy of this presentation state.
    func layoutPhase(for phase: NotchPhase) -> NotchPhase {
        guard phase == .listening || phase == .transcribing else { return phase }
        switch context {
        case .activity: return .running
        case .composer: return .typing
        case .reply: return .message
        }
    }
    func endContext() { context = .activity; baseDraft = "" }
    var finalizing = false
    var baseDraft = ""
    func composedText(_ transcript: String) -> String {
        baseDraft + (baseDraft.isEmpty || baseDraft.last?.isWhitespace == true || transcript.isEmpty ? "" : " ") + transcript
    }
    var error: String?
    private(set) var levels = Array(repeating: Float(0), count: 24)
    private var smoothed: Float = 0
    func reset(context: Context = .activity, baseDraft: String = "") {
        self.context = context; self.baseDraft = baseDraft
        text = ""; connected = false; capturing = false; error = nil; finalizing = false
        smoothed = 0; levels = Array(repeating: 0, count: 24)
    }
    func push(_ volume: Float) {
        smoothed += (volume - smoothed) * (volume > smoothed ? 0.85 : 0.35)
        levels.removeFirst(); levels.append(smoothed)
    }
}

/// The voice status occupies the same row as Sidekick's running status, under one
/// persistent header. It is not a separate screen or a separately-sized container.
struct NotchVoiceCaption: View {
    let presentation: DictationPresentation
    var submittedText: String? = nil
    private var text: String { submittedText ?? presentation.text }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                PromptDictationWaveform(levels: presentation.levels, height: 16)
                    .transition(.opacity)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                Text(text)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.95)).lineLimit(1).fixedSize()
                                Color.clear.frame(width: 1, height: 1).id("latest")
                            }
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .leading)
                        }
                        .onAppear { scroll.scrollTo("latest", anchor: .trailing) }
                        .onChange(of: text) { _, _ in scroll.scrollTo("latest", anchor: .trailing) }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: text.isEmpty)
        .allowsHitTesting(false)
        .accessibilityLabel(text.isEmpty ? (presentation.capturing ? "Listening" : "Preparing microphone") : text)
    }
}

/// Left-aligned pre-transcript feedback, shared by Home and the inline response composer.
struct PromptDictationWaveform: View {
    let levels: [Float]
    var height: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.suffix(12).enumerated()), id: \.offset) { _, level in
                Capsule().fill(.white.opacity(0.8))
                    .frame(width: 2, height: max(3, CGFloat(level) * (height - 4)))
            }
        }
        .frame(height: height, alignment: .leading)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
        .accessibilityLabel("Listening")
    }
}
