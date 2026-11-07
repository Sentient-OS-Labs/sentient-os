// A bounded, non-focus-stealing glimpse of one durable conversation message.
// The coordinator owns presentation/timing; opening or replying targets the original message.
import SwiftUI

struct SidekickNotchMessageView: View {
    let message: SidekickConversationStore.Record
    let isTaskRunning: Bool
    var isTaskFinishing = false
    let onReply: (String?) -> Void
    let onStop: () -> Void
    let onMicPress: () -> Void
    let onMic: () -> Void
    let onSelecting: (Bool) -> Void
    var voice: DictationPresentation? = nil
    var onVoiceSend: () -> Void = {}
    var onVoiceStop: () -> Void = {}
    var draft: Binding<String> = .constant("")
    var replyFocused = false
    var replyingToSelection = false
    var onReplyFocusChanged: (Bool) -> Void = { _ in }
    var onSend: (String) -> Bool = { _ in false }
    var composerCornerRadius: CGFloat = 12
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        voice?.finalizing != true && (voice != nil || (!isTaskRunning && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidekickNotchMessageLayout.sectionSpacing) {
            ScrollView(.vertical) {
                SidekickMarkdown(markdown: message.event.text, compact: true, onReply: {
                    onReply($0); fieldFocused = true
                },
                    onSelectionChange: onSelecting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, SidekickNotchMessageLayout.textVerticalPad)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask {
                VStack(spacing: 0) {
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 9)
                }
                .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    TextField(replyingToSelection ? "Reply to selected text…" : "Reply to Sidekick…",
                              text: voice.map { value in Binding(get: { value.composedText(value.text) }, set: { _ in }) } ?? draft)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.94)).tint(.white)
                        .focused($fieldFocused).onSubmit(send)
                        .disabled(voice != nil)
                        .opacity(voice?.text.isEmpty == true ? 0 : 1)
                        .accessibilityLabel("Reply to Sidekick")
                        .accessibilityIdentifier("sidekick.notch.reply")
                    if let voice, voice.text.isEmpty {
                        PromptDictationWaveform(levels: voice.levels)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: voice?.text.isEmpty == true)
                NotchMicrophoneButton(onPress: { if voice != nil { onVoiceStop() } else { onMicPress() } },
                    onActivate: { if voice != nil { onVoiceStop() } else { onMic() } }, recording: voice != nil)
                    .frame(width: 18, height: 18).disabled((isTaskRunning && !isTaskFinishing) || voice?.finalizing == true)
                if replyingToSelection {
                    Button { onReply(nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).help("Reply to the whole message instead")
                    .accessibilityLabel("Clear selected-text reply")
                }
                if isTaskRunning && !isTaskFinishing && message.event.messageKind == .update {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(NotchMessageButtonStyle(prominent: false))
                    .help("Stop current task").accessibilityLabel("Stop current Sidekick task")
                }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(canSend ? 0.94 : 0.3), in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend)
                .help(isTaskRunning ? "Send when Sidekick finishes" : "Send reply")
                .accessibilityLabel("Send reply")
                .accessibilityIdentifier("sidekick.notch.sendReply")
            }
            .padding(.horizontal, 11)
            .frame(height: SidekickNotchMessageLayout.replyHeight)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: composerCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: composerCornerRadius)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
            }
        }
        .padding(.top, SidekickNotchMessageLayout.topPad)
        .padding(.bottom, SidekickNotchMessageLayout.bottomPad)
        // The hardware notch remains OLED black in both appearances. Its content follows
        // that local appearance while keeping the same Sentient spectrum as the main UI.
        .environment(\.colorScheme, .dark)
        .onChange(of: fieldFocused) { _, value in onReplyFocusChanged(value) }
        .onChange(of: draft.wrappedValue) { _, _ in onReplyFocusChanged(fieldFocused) }
        .onChange(of: replyFocused) { _, value in if !value { fieldFocused = false } }
        .onDisappear { onSelecting(false); onReplyFocusChanged(false) }
        .accessibilityElement(children: .contain)
    }

    private func send() {
        guard canSend else { return }
        if voice != nil { onVoiceSend(); return }
        let text = draft.wrappedValue
        if onSend(text) { fieldFocused = false }
    }
}

struct NotchMessageButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(prominent ? 0.94 : 0.73))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(prominent ? (hovering ? 0.12 : 0.09) : (hovering ? 0.075 : 0.045)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.20 : 0.10), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: hovering)
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: configuration.isPressed)
    }
}
