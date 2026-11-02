import SwiftUI

@MainActor @Observable
final class ProviderAccountActions {
    static let shared = ProviderAccountActions()
    private(set) var changing = false

    static func reviewKey(_ backend: ModelBackend) -> String { "account.reviewConnectors.\(backend.rawValue)" }

    func signOut(_ backend: ModelBackend, appState: AppState) async throws {
        guard !changing else { throw AccountError.busy }
        let conversation = appState.commandCoordinator.run.conversation
        guard conversation.beginMaintenance() else { throw AccountError.busy }
        changing = true
        defer { changing = false; conversation.endMaintenance() }
        let processing = appState.processing
        if processing.isBusy { processing.pause() }
        await processing.suspend()
        defer { processing.resumeMonitoring(); appState.scheduler.reevaluate() }
        guard await appState.commandCoordinator.run.stopAndDrain() else { throw AccountError.stopping }
        await conversation.drainBackgroundWork()
        // Retire selection consent before any credential changes, including failed/retried logout.
        if let origin = ConnectorCensus.DetectedConnector.Origin(backend: backend) {
            ConnectorCensus.forgetAccount(origin)
        }
        UserDefaults.standard.set(true, forKey: Self.reviewKey(backend))
        switch backend {
        case .chatgpt:
            CodexAuth.clearAccountPreferences()
            try await CodexSetup.shared.signOut()
        case .claude:
            try await ClaudeSetup.shared.signOut()
        default: return
        }
    }

    enum AccountError: LocalizedError {
        case busy, stopping
        var errorDescription: String? {
            switch self {
            case .busy: "Sentient is finishing another account or data change. Please try again."
            case .stopping: "Sidekick is still stopping. Please try again once it finishes."
            }
        }
    }
}

struct ProviderAccountControls: View {
    let backend: ModelBackend
    @Environment(AppState.self) private var appState: AppState?
    @State private var actions = ProviderAccountActions.shared
    @State private var confirm = false
    @State private var switchAccount = false
    @State private var error: String?
    @State private var accountTask: Task<Void, Never>?
    @AppStorage("account.reviewConnectors.chatgpt") private var reviewChatGPT = false
    @AppStorage("account.reviewConnectors.claude") private var reviewClaude = false

    private var name: String { backend == .chatgpt ? "ChatGPT" : "Claude" }
    private var loggedIn: Bool { backend == .chatgpt ? CodexSetup.shared.loggedIn : ClaudeSetup.shared.loggedIn }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Button("Switch account") { switchAccount = true; confirm = true }
                Button("Sign out") { switchAccount = false; confirm = true }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .disabled(actions.changing || appState == nil)
            if actions.changing { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            if loggedIn && (backend == .chatgpt ? reviewChatGPT : reviewClaude) {
                Text("Choose which connected apps Sentient can use with this account.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("Review connected apps") {
                    if backend == .chatgpt { reviewChatGPT = false } else { reviewClaude = false }
                    HomeWindowOpening.open(.settings, settingsPane: .sources)
                }
            }
        }
        .alert(switchAccount ? "Switch \(name) account?" : "Sign out of \(name)?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) {}
            Button(switchAccount ? "Switch account" : "Sign out", role: .destructive) { perform() }
        } message: {
            Text("This stops current AI work. After signing in, choose your connected apps again."
                 + (backend == .claude ? " This also signs out of Claude Code in Terminal." : ""))
        }
    }

    private func perform() {
        guard let appState else { return }
        error = nil
        let shouldSignIn = switchAccount
        accountTask = Task {
            do {
                try await actions.signOut(backend, appState: appState)
                if shouldSignIn {
                    if backend == .chatgpt { _ = await CodexSetup.shared.startLogin(force: true) }
                    else { ClaudeSetup.shared.startLogin(force: true) }
                }
            } catch {
                self.error = "Couldn't finish signing out. Please try again."
                Log("Account sign-out failed: \(ErrorLabel(error))")
            }
            accountTask = nil
        }
    }
}

struct ChatGPTPlanControls: View {
    @State private var choice = CodexAuth.planChoice
    @AppStorage(CodexAuth.modelFallbackKey) private var fallbackAccount = ""

    var body: some View {
        VStack(spacing: 10) {
            Picker("ChatGPT plan", selection: $choice) {
                ForEach(CodexAuth.PlanChoice.allCases, id: \.rawValue) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .onChange(of: choice) { CodexAuth.planChoice = choice }
            .onAppear { choice = CodexAuth.planChoice }
            if choice == .automatic && CodexAuth.currentPlan() == nil {
                Text("We couldn't identify your plan. You can keep using Sentient with Luna, or select your plan above.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if !fallbackAccount.isEmpty && CodexAuth.usingModelFallback {
                Text("Your selected model wasn't available. Sentient is using Luna.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("Try selected model again") { CodexAuth.retrySelectedModel() }
            }
        }
    }
}
