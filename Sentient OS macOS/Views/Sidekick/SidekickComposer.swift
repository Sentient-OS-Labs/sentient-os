import SwiftUI
import AppKit

struct SidekickComposer: View {
    let coordinator: CommandCoordinator
    let presentation: SidekickPresentation
    var isPresented: Bool
    var onAccepted: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduced: Bool { motionOverride ?? systemReduced }
    @FocusState private var focused: Bool
    @State private var submissionError: String?

    private var conversation: SidekickConversation { coordinator.run.conversation }
    private var recovery: SidekickRecovery { coordinator.run.recovery }
    private var notchHasKeyboard: Bool {
        coordinator.phase == .typing || coordinator.phase == .listening || coordinator.messageReplyFocused
    }
    private var answering: Bool { recovery.isPending }
    private var text: Binding<String> {
        Binding(get: { answering ? recovery.draft : conversation.draft },
                set: { if answering { recovery.draft = $0 } else { conversation.draft = $0 }; submissionError = nil })
    }
    private var canSend: Bool {
        !coordinator.run.isClearingChat && !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (answering || !coordinator.run.isRunning)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let error = submissionError ?? conversation.storageError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.65))
                .padding(.horizontal, 10)
            }
            VStack(alignment: .leading, spacing: 12) {
                if answering, let content = recovery.content {
                    recoveryHeader(content)
                        .transition(SidekickStyle.entrance(reduced))
                } else if let reference = conversation.replyReference {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(SidekickStyle.accent).frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Replying to a message").font(.system(size: 11, weight: .semibold)).foregroundStyle(SidekickStyle.accent)
                            Text(replyPreview(reference))
                                .font(.system(size: 12)).lineLimit(2).foregroundStyle(SidekickStyle.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { conversation.show(messageID: reference.messageID) } label: { Image(systemName: "arrow.up.right") }
                            .help("Show original message")
                        Button { withAnimation(SidekickStyle.motion(reduced)) { conversation.replyReference = nil } } label: { Image(systemName: "xmark") }
                            .help("Remove reply").accessibilityLabel("Remove reply")
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(SidekickStyle.entrance(reduced))
                }
                HStack(alignment: .bottom, spacing: 14) {
                    TextField(answering ? "Add your answer…" : "Ask Sidekick…", text: text, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .foregroundStyle(SidekickStyle.ink).tint(SidekickStyle.accent)
                        .lineLimit(1...5).focused($focused).onSubmit(handleReturn)
                        .padding(.vertical, 10)
                        .accessibilityLabel(answering ? "Answer Sidekick" : "Message Sidekick")
                        .accessibilityIdentifier("sidekick.composer")
                        .help("Return to send. Shift-Return for a new line.")
                    if coordinator.run.isRunning && !answering {
                        Button(action: coordinator.stop) {
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SidekickStyle.ink)
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.10), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                        }
                        .buttonStyle(SidekickPressStyle())
                        .accessibilityLabel("Stop current task")
                        .accessibilityIdentifier("sidekick.stop")
                        .help("Stop")
                    } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(canSend ? SidekickStyle.base : .white.opacity(0.30))
                            .frame(width: 36, height: 36)
                            .background(canSend ? SidekickStyle.ink : .white.opacity(0.055), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(canSend ? 0.6 : 0.09)))
                            .background {
                                if canSend {
                                    ZStack {
                                        Circle().fill(AngularGradient(colors: GlowHalo.stops, center: .center))
                                            .frame(width: 48, height: 48).blur(radius: 11)
                                            .opacity(focused ? 0.75 : 0.52)
                                        Circle().stroke(AngularGradient(colors: GlowHalo.stops, center: .center), lineWidth: 3)
                                            .frame(width: 39, height: 39).blur(radius: 1.5)
                                            .opacity(0.95)
                                    }
                                    .saturation(1.25).allowsHitTesting(false)
                                }
                            }
                    }
                    .buttonStyle(SidekickPressStyle()).disabled(!canSend)
                    .accessibilityLabel(answering ? "Send answer" : "Send message")
                    .accessibilityIdentifier("sidekick.send")
                    .help("Send (Return)")
                    }
                }
                if answering {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(SidekickStyle.accent.opacity(0.8))
                    Text("Your answer continues this task")
                        .lineLimit(1)
                    Spacer()
                    if coordinator.run.isRunning {
                        Button(action: coordinator.stop) { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.plain).foregroundStyle(SidekickStyle.ink)
                            .accessibilityIdentifier("sidekick.stop")
                    } else if answering {
                        Button("Dismiss") { recovery.cancel() }.buttonStyle(.plain)
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(SidekickStyle.secondary)
                }
            }
            .padding(17)
            .sidekickGlass(radius: 18, prominent: true)
            .shadow(color: .white.opacity(focused ? 0.035 : 0), radius: 22, y: 2)
            .shadow(color: .black.opacity(0.13), radius: 18, y: 12)
        }
        .disabled(coordinator.run.isClearingChat)
        .onChange(of: coordinator.run.isClearingChat) { _, clearing in
            if clearing { focused = false; presentation.composerFocused = false; submissionError = nil }
        }
        .animation(SidekickStyle.motion(reduced), value: recovery.content?.id)
        .animation(.easeInOut(duration: 0.35), value: focused)
        .defaultFocus($focused, isPresented && !answering && !notchHasKeyboard)
        .onChange(of: notchHasKeyboard) { _, ownsKeyboard in
            if ownsKeyboard { focused = false; presentation.composerFocused = false }
        }
        .onChange(of: focused) { _, value in presentation.composerFocused = value }
        .onChange(of: isPresented) { _, visible in
            if !visible { focused = false; presentation.composerFocused = false }
        }
        .onChange(of: conversation.replyReference) { _, value in if value != nil && isPresented { focused = true } }
        .onDisappear { presentation.composerFocused = false }
    }

    private func recoveryHeader(_ content: SidekickRecoveryContent) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: content.question == nil ? "arrow.clockwise" : "bubble.left.and.text.bubble.right")
                Text(content.question == nil ? "A little guidance?" : "A quick question")
                    .fontWeight(.semibold)
            }.font(.system(size: 11)).foregroundStyle(SidekickStyle.accent)
            Text(content.question?.question ?? content.error ?? "")
                .font(.system(size: 13)).foregroundStyle(SidekickStyle.ink).lineLimit(4)
            if let question = content.question {
                HStack(spacing: 8) {
                    ForEach(Array(question.answers.enumerated()), id: \.offset) { index, answer in
                        Button {
                            recovery.answer(id: question.id, choice: index)
                            if recovery.content?.id != question.id {
                                Self.didAccept(conversation: conversation, presentation: presentation)
                                onAccepted(); focused = true
                            }
                        } label: {
                            Text(answer).font(.system(size: 12, weight: .medium)).lineLimit(3)
                                .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 10)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.13)))
                        }.buttonStyle(SidekickPressStyle())
                    }
                }
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func replyPreview(_ reference: SidekickConversationEvent.ReplyReference) -> AttributedString {
        let raw = reference.selectedText ?? conversation.messages.first(where: { $0.event.id == reference.messageID })?.event.text ?? "Earlier in your conversation"
        let preview = String(raw.prefix(600))
        return (try? AttributedString(markdown: preview, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(preview)
    }

    private func handleReturn() {
        guard isPresented, !coordinator.run.isClearingChat else { return }
        // AppKit's multiline TextField commits on Shift-Return by default. Chat keeps that
        // chord for a newline, including an insertion in the middle of an existing draft.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.insertNewlineIgnoringFieldEditor(nil)
            } else { text.wrappedValue += "\n" }
            return
        }
        send()
    }

    private func send() {
        guard isPresented, canSend else { return }
        let accepted = withAnimation(SidekickStyle.motion(reduced)) {
            Self.sendDraft(coordinator: coordinator, presentation: presentation)
        }
        if accepted { onAccepted(); focused = true }
        else {
            submissionError = coordinator.run.statusLine.isEmpty ? "Your message wasn’t sent. Your draft is still here." : coordinator.run.statusLine
        }
    }

    /// The native acceptance lab calls this same composer action. Clear only a durably
    /// accepted request; a busy run, setup refusal or storage failure preserves the draft.
    @discardableResult
    static func sendDraft(coordinator: CommandCoordinator, presentation: SidekickPresentation) -> Bool {
        guard !coordinator.run.isClearingChat else { return false }
        let conversation = coordinator.run.conversation
        let recovery = coordinator.run.recovery
        let value = (recovery.isPending ? recovery.draft : conversation.draft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if let content = recovery.content {
            recovery.answer(id: content.id, text: value)
            guard recovery.content?.id != content.id else { return false }
        } else {
            guard !coordinator.run.isRunning,
                  coordinator.submit(value, mode: .computer, source: .promptBar) else { return false }
            conversation.draft = ""
        }
        didAccept(conversation: conversation, presentation: presentation)
        return true
    }

    private static func didAccept(conversation: SidekickConversation, presentation: SidekickPresentation) {
        presentation.sendPulse &+= 1
        presentation.surface = .conversation
        conversation.requestNavigation()
    }
}
