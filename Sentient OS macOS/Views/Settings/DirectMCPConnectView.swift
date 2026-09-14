//
// DirectMCPConnectView.swift
// Browser-based connection setup for supported services. Account labels remain visible so a
// personal connection and a work connection are never silently treated as the same account.
// Doc: Documentation - Settings.md
//

import SwiftUI

struct DirectMCPConnectView: View {
    var existing: DirectMCPConnection? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var providerSlug = "granola"
    @State private var label = "Personal"
    @State private var working = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var newConnectionID = UUID()
    @State private var completed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(existing == nil ? "Connect an app" : "Reconnect your account")
                .font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
            Text("Sign in on the app's website. This connection works with either of your AI engines.")
                .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                MonoCaps("App", size: 9, tracking: 1.6, color: .white.opacity(0.5))
                Picker("App", selection: $providerSlug) {
                    ForEach(DirectMCPProvider.catalog, id: \.slug) { Text($0.name).tag($0.slug) }
                }.labelsHidden().pickerStyle(.menu).disabled(working || existing != nil)
            }
            VStack(alignment: .leading, spacing: 10) {
                MonoCaps("Account label", size: 9, tracking: 1.6, color: .white.opacity(0.5))
                TextField("Personal, Work, or a workspace name", text: $label)
                    .textFieldStyle(.plain).font(.system(size: 13)).padding(11)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.13)))
                    .disabled(working)
                Text("Choose the matching account on the website. This label helps you recognize it in Sentient.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if working {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser. Sentient will verify the connection.")
                        .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                }
            }
            SettingsHairline()
            Text("Login credentials stay in your Mac's Keychain. Content you request is processed by your selected AI provider.")
                .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Connecting…" : "Continue in browser") { connect() }
                    .buttonStyle(.borderedProminent).tint(Theme.Ink.green)
                    .disabled(working || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.count > 60)
            }
        }
        .padding(30).frame(width: 460).background(Theme.bg)
        .onAppear { if let existing { providerSlug = existing.providerSlug; label = existing.label } }
        .onDisappear {
            operation?.cancel()
            if existing == nil && !completed {
                Task { _ = try? await DirectMCPConnections.shared.disconnect(newConnectionID) }
            }
        }
    }
    private func connect() {
        guard let provider = DirectMCPProvider.find(providerSlug) else { return }
        working = true; message = nil
        operation = Task {
            do {
                _ = try await DirectMCPConnections.shared.connect(provider: provider, label: label, replacing: existing?.id ?? newConnectionID)
                completed = true
                working = false
                dismiss()
            } catch is CancellationError { working = false }
            catch {
                working = false
                message = (error as? DirectMCPError)?.errorDescription ?? "The connection couldn't be verified. Please try again."
            }
        }
    }
}

#Preview("Connect a direct account") { DirectMCPConnectView() }
