import SwiftUI

/// One conversation action, backed by the same clear operation on every provider.
struct SidekickClearChatButton: View {
    let coordinator: CommandCoordinator
    let presentation: SidekickPresentation
    @State private var failure: String?
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reducedMotion: Bool { motionOverride ?? systemReducedMotion }
    private var clearing: Bool { coordinator.run.isClearingChat }

    static let reassurance = "You can keep chatting. Sidekick automatically summarizes older messages in the background, so there’s no need to clear your chat unless you want to start fresh."
    static let consequence = "Clearing your chat deletes its history and conversation context. Your knowledge base and saved Sidekick instructions stay."

    var body: some View {
        SidekickToolbarIconButton(symbol: "trash", busy: clearing) {
            presentation.clearChatConfirmationShown = true
        }
        .disabled(clearing)
        .help(clearing ? "Clearing chat…" : "Clear chat…")
        .accessibilityLabel(clearing ? "Clearing chat" : "Clear chat…")
        .accessibilityIdentifier("sidekick.clearChat")
        .sheet(isPresented: Binding(
            get: { presentation.clearChatConfirmationShown },
            set: { presentation.clearChatConfirmationShown = $0 }
        )) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Clear chat?").font(.system(size: 17, weight: .semibold))
                Text(Self.reassurance).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(Self.consequence).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if coordinator.run.isRunning {
                    Text("Sidekick will stop its current task before clearing the chat.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        presentation.clearChatConfirmationShown = false
                    } label: {
                        Text("Cancel").frame(maxWidth: .infinity).frame(height: 34)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(action: confirmClear) {
                        Text(coordinator.run.isRunning ? "Stop and clear chat" : "Clear chat")
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .foregroundStyle(.white)
                            .background(Color.blue, in: Capsule())
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
            }
            .foregroundStyle(SidekickStyle.ink)
            .padding(24).frame(width: 340)
            .background(Color(white: 0.09))
            .preferredColorScheme(.dark)
        }
        .alert("Chat couldn’t be cleared", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "Please try again.") }
    }

    private func confirmClear() {
        presentation.clearChatConfirmationShown = false
        Task { @MainActor in
            do {
                try await coordinator.clearChat()
                withAnimation(SidekickStyle.motion(reducedMotion)) {
                    presentation.didClearChat(generation: coordinator.run.conversation.generation)
                }
            } catch { failure = error.localizedDescription }
        }
    }

}
