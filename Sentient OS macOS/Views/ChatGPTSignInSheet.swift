// Home's private ChatGPT sign-in. Presentation never opens a browser; the user's button
// starts the shared setup flow. Only a login started by this sheet belongs to its cleanup.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI

struct ChatGPTSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var codex = CodexSetup.shared
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    @State private var startTask: Task<Void, Never>?
    @State private var startID = UUID()
    @State private var ownedLoginAttempt: UUID?

    private var busy: Bool { startTask != nil || codex.preparing || codex.installing }

    var body: some View {
        VStack(spacing: 0) {
            OrbMark(size: 36)
            Text("Sign in to ChatGPT")
                .display(24).foregroundStyle(Theme.Ink.statusInk)
                .padding(.top, 20)
            Text("Please sign in to ChatGPT to continue using Sentient.")
                .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            if codex.loggingIn {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.")
                        .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                }
                .padding(.top, 24)
            }

            if codex.loggingIn {
                LoginLinkButton(url: codex.loginURL)
                    .padding(.top, 26)
            } else {
                Button(action: signIn) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small).tint(.black) }
                        Text("Sign in with ChatGPT")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(.white.opacity(busy ? 0.5 : 1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(busy || !codex.installed)
                .padding(.top, 26)
            }

            if let status = codex.loginStatusLine, status.hasPrefix("✗") {
                Text(status.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            Button("Not now") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(Theme.Ink.deepMuted)
                .padding(.top, 18)
        }
        .padding(.horizontal, 36).padding(.top, 42).padding(.bottom, 26)
        .frame(width: 430)
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { CloseHoverButton { dismiss() }.padding(12) }
        .task(id: codex.loggingIn) {
            while !Task.isCancelled, codex.loggingIn, !codex.loggedIn, ModelBackend.current == .chatgpt {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled, ModelBackend.current == .chatgpt else { return }
                await codex.refreshLoginStatus()
            }
        }
        .onChange(of: codex.loggedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
        .onChange(of: backendRaw) { _, _ in
            if backendRaw != ModelBackend.chatgpt.rawValue {
                cancelOwnedLogin()
                dismiss()
            }
        }
        .onDisappear { cancelOwnedLogin() }
    }

    private func signIn() {
        guard !busy, ModelBackend.current == .chatgpt else { return }
        let request = UUID()
        startID = request
        startTask = Task {
            defer { if startID == request { startTask = nil } }
            let attempt = await codex.startLogin()
            guard !Task.isCancelled, startID == request, ModelBackend.current == .chatgpt else {
                if let attempt { await codex.cancelLogin(ifAttempt: attempt) }
                return
            }
            if let attempt { ownedLoginAttempt = attempt }
            if codex.loggedIn { dismiss() }
        }
    }

    private func cancelOwnedLogin() {
        startID = UUID()
        startTask?.cancel()
        startTask = nil
        if let attempt = ownedLoginAttempt {
            ownedLoginAttempt = nil
            Task {
                guard !codex.loggedIn else { return }
                await codex.cancelLogin(ifAttempt: attempt)
                if ModelBackend.current == .chatgpt { await codex.refreshLoginStatus() }
            }
        }
    }
}

#Preview("ChatGPT sign-in") {
    ChatGPTSignInSheet().preferredColorScheme(.dark)
}
