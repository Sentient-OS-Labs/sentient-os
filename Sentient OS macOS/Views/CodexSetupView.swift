//
//  CodexSetupView.swift
//  Sentient OS macOS
//
//  The single Codex SETUP window — all three setup steps in one place, driven entirely by the
//  shared `CodexSetup` engine. This view is a pure trigger + status renderer (ZERO setup logic
//  lives here), so the real onboarding flow can present its own polished screen over the very same
//  engine without re-implementing anything.
//    1. Install the Codex CLI     2. Log in (browser OAuth)     3. Set up computer use (to build)
//
//  Opened today from the dev tools' CODEX SETUP button.
//

import SwiftUI

struct CodexSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var codex = CodexSetup.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CODEX SETUP").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    Text("Three steps to let Sentient act for you with Codex computer use. This window just triggers the shared setup engine; onboarding calls the exact same code.")
                        .font(.caption2).foregroundStyle(Theme.faint.opacity(0.8))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

                    installCard
                    loginCard
                    computerUseCard
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 640)
        .background(Theme.bg)
        .onAppear {
            codex.refreshInstalled()
            codex.refreshComputerUse()
            Task { await codex.refreshLoginStatus() }
        }
    }

    // MARK: Step 1 — install

    private var installCard: some View {
        stepCard(1, "Install the Codex CLI", done: codex.installed) {
            Button { Task { await codex.installCodex() } } label: {
                buttonLabel("arrow.down.circle.fill", "Install Codex CLI", busy: codex.installing)
            }
            .buttonStyle(.bordered).tint(Theme.Ink.green)
            .disabled(codex.installing)

            statusLine(codex.installStatus)
            hint("Runs OpenAI's official installer (curl … | sh) → ~/.local/bin/codex. A no-op if codex is already there.")
        }
    }

    // MARK: Step 2 — login

    private var loginCard: some View {
        stepCard(2, "Log in to Codex", done: codex.loggedIn) {
            if codex.loggedIn {
                hint("Signed in with your OpenAI account. Codex is in every plan, free included, so there's no subscription to check.")
                Button { codex.startLogin(force: true) } label: {
                    buttonLabel("arrow.triangle.2.circlepath", "Log in again", busy: false)
                }
                .buttonStyle(.bordered).tint(Theme.secondary).controlSize(.small)
            } else if codex.loggingIn {
                hint("A browser window opened for you to sign in. Finish there, then tap below.")
                Button { Task { await codex.confirmLogin() } } label: {
                    buttonLabel("checkmark.circle.fill", "Finished logging into codex", busy: false)
                }
                .buttonStyle(.borderedProminent).tint(Theme.Ink.green)
            } else {
                Button { codex.startLogin() } label: {
                    buttonLabel("person.crop.circle.badge.checkmark", "Log in to Codex", busy: false)
                }
                .buttonStyle(.bordered).tint(Theme.Ink.green)
                .disabled(!codex.installed)
            }
            statusLine(codex.loginStatusLine)
        }
    }

    // MARK: Step 3 — computer use

    private var computerUseCard: some View {
        stepCard(3, "Set up computer use", done: codex.computerUseReady) {
            if codex.computerUseReady {
                hint("Computer use is wired into ~/.codex; Codex can drive your Mac through the CLI.")
                Button { Task { await codex.setupComputerUse(force: true) } } label: {
                    buttonLabel("arrow.triangle.2.circlepath", "Re-install computer use", busy: codex.settingUpComputerUse)
                }
                .buttonStyle(.bordered).tint(Theme.secondary).controlSize(.small)
                .disabled(codex.settingUpComputerUse)
            } else {
                Button { Task { await codex.setupComputerUse() } } label: {
                    buttonLabel("cpu.fill", "Set up computer use", busy: codex.settingUpComputerUse)
                }
                .buttonStyle(.bordered).tint(Theme.Ink.green)
                .disabled(codex.settingUpComputerUse || !codex.installed)
            }
            statusLine(codex.computerUseStatus)
            hint("Downloads OpenAI's official ChatGPT (Codex) app (~535 MB), lifts out the bundled computer-use plugin, and patches ~/.codex. No desktop app install; nothing hosted by us.")
        }
    }

    // MARK: Building blocks

    /// A numbered step card: number badge + title + a DONE/PENDING pill, then its controls.
    private func stepCard<Content: View>(_ number: Int, _ title: String, done: Bool,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(done ? Theme.Ink.green.opacity(0.22) : Color.white.opacity(0.06)))
                    .foregroundStyle(done ? Theme.Ink.green : Theme.secondary)
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(done ? "DONE" : "PENDING")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((done ? Theme.Ink.green : Theme.secondary).opacity(0.22)))
                    .foregroundStyle(done ? Theme.Ink.green : Theme.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private func buttonLabel(_ systemImage: String, _ title: String, busy: Bool) -> some View {
        HStack(spacing: 7) {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: systemImage) }
            Text(title).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 38)
    }

    @ViewBuilder private func statusLine(_ s: String?) -> some View {
        if let s {
            Text(s)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(s.hasPrefix("✓") ? Theme.Ink.green : s.hasPrefix("✗") ? .red : Theme.secondary)
                .multilineTextAlignment(.leading).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(Theme.faint.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
    }
}
