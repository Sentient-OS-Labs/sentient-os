// A bounded, non-focus-stealing glimpse of one durable conversation message.
// The coordinator owns presentation/timing; opening or replying targets the original message.
import SwiftUI

struct SidekickNotchMessageView: View {
    let message: SidekickConversationStore.Record
    let isTaskRunning: Bool
    let onOpen: () -> Void
    let onReply: (String?) -> Void
    let onStop: () -> Void
    let onSelecting: (Bool) -> Void
    var draft: Binding<String> = .constant("")
    var replyFocused = false
    var replyingToSelection = false
    var onReplyFocusChanged: (Bool) -> Void = { _ in }
    var onSend: (String) -> Bool = { _ in false }
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        !isTaskRunning && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidekickNotchMessageLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.event.messageKind == .answer ? "Sidekick" : "An update from Sidekick")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Text(message.event.createdAt, style: .time)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .accessibilityLabel("Received at \(message.event.createdAt.formatted(date: .omitted, time: .shortened))")
            }
            .frame(height: SidekickNotchMessageLayout.labelHeight)
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
                TextField(replyingToSelection ? "Reply to selected text…" : "Reply to Sidekick…", text: draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.94)).tint(.white)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Reply to Sidekick")
                    .accessibilityIdentifier("sidekick.notch.reply")
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
            .background(.white.opacity(fieldFocused ? 0.10 : 0.065), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(fieldFocused ? 0.32 : 0.14), lineWidth: 0.75)
            }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: fieldFocused)
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    Label("Open in Sentient", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: SidekickNotchMessageLayout.footerHeight)
                }
                .buttonStyle(NotchMessageButtonStyle(prominent: true))
                .accessibilityHint("Open this exact response in your full conversation")
                Spacer(minLength: 8)
                if replyingToSelection {
                    Button { onReply(nil) } label: {
                        Label("Selected text", systemImage: "xmark")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    }.buttonStyle(.plain).help("Reply to the whole message instead")
                } else if isTaskRunning {
                    Text("You can draft a reply")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                if isTaskRunning {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: SidekickNotchMessageLayout.footerHeight, height: SidekickNotchMessageLayout.footerHeight)
                    }
                    .buttonStyle(NotchMessageButtonStyle(prominent: false))
                    .help("Stop current task")
                    .accessibilityLabel("Stop current Sidekick task")
                }
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
        let text = draft.wrappedValue
        if onSend(text) { fieldFocused = false }
    }
}

private struct NotchMessageButtonStyle: ButtonStyle {
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
