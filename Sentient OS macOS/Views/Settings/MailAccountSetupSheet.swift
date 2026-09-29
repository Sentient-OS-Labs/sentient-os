// MailAccountSetupSheet.swift
// Shows the exact connected addresses before saving; Claude Gmail is entered by the user.
// The same disclosure and validation apply to onboarding, Settings and existing installations.
// Doc: ../../Cloud/Mail Accounts/Documentation - Connected Email Accounts.md

import SwiftUI

struct MailAccountSetupSheet: View {
    let engine: MailAccount.Engine
    var provider: MailAccount.Provider?
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MailAccountCandidate] = []
    @State private var entered: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?
    @State private var checkID = UUID()
    #if DEBUG
    private var previewOnly = false
    #endif

    init(engine: MailAccount.Engine, provider: MailAccount.Provider? = nil, onSaved: @escaping () -> Void = {}) {
        self.engine = engine; self.provider = provider; self.onSaved = onSaved
    }

    #if DEBUG
    init(previewCandidates: [MailAccountCandidate], engine: MailAccount.Engine) {
        self.init(engine: engine)
        _candidates = State(initialValue: previewCandidates)
        _loading = State(initialValue: false)
        previewOnly = true
    }
    #endif

    private var valid: Bool {
        !candidates.isEmpty && candidates.allSatisfy { $0.email != nil || MailAccount.normalizedEmail(entered[$0.id] ?? "") != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your connected email")
                .display(23).foregroundStyle(.white)
            Text("Sentient saves these email addresses in its cloud database, hosted by Supabase, to keep a record of your connected accounts. This does not upload messages, passwords or your AI login. You can delete the saved addresses in Settings → System.")
                .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            if loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking your connected accounts…").font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(candidates) { candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.provider.title + " · " + (engine == .claude ? "Claude" : "ChatGPT"))
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Ink.body)
                            if let email = candidate.email {
                                Text(email).font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white).textSelection(.enabled)
                            } else {
                                Text("Which email address did you connect to Claude?")
                                    .font(.system(size: 12)).foregroundStyle(.white)
                                TextField("Email address", text: Binding(
                                    get: { entered[candidate.id] ?? "" },
                                    set: { entered[candidate.id] = $0 }), prompt: Text(verbatim: "you@example.com"))
                                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                                    .accessibilityLabel("Gmail address connected to Claude")
                                Text("Claude doesn't share this address with Sentient. Enter the account you linked.")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.body)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: candidates.count > 2 ? 260 : (candidates.contains { $0.email == nil } ? 180 : 120))
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                if !loading && candidates.isEmpty {
                    Button("Try again") { checkID = UUID() }.disabled(saving)
                }
                Button(saved ? "Done" : (saving ? "Saving…" : "Save email addresses")) {
                    if saved { onSaved(); dismiss() } else { save() }
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .disabled(!saved && (!valid || loading || saving))
            }
        }
        .padding(30).frame(width: 480).background(Theme.bg).preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .task(id: checkID) {
            #if DEBUG
            if previewOnly { return }
            #endif
            loading = true; message = nil
            defer { loading = false }
            do {
                candidates = try await MailAccountProbe.discover(engine: engine, provider: provider)
                let prior = try await MailAccountCloud.shared.savedAccounts()
                for candidate in candidates where candidate.email == nil {
                    entered[candidate.id] = prior.first { $0.id == candidate.id }?.email ?? ""
                }
            } catch is CancellationError { return }
            catch { message = (error as? MailAccountError)?.errorDescription ?? "The connected accounts couldn't be checked. Please try again." }
        }
    }

    private func save() {
        #if DEBUG
        if previewOnly { return }
        #endif
        saving = true; message = nil
        Task {
            defer { saving = false }
            do {
                let accounts = try candidates.map { try $0.confirmed(email: entered[$0.id]) }
                let synced = try await MailAccountCloud.shared.save(accounts, engine: engine, provider: provider)
                if synced { onSaved(); dismiss() }
                else {
                    saved = true
                    message = "Saved securely on this Mac. Cloud sync is pending and will retry when Sentient is active."
                }
            } catch { message = (error as? MailAccountError)?.errorDescription ?? "The addresses couldn't be saved. Please try again." }
        }
    }
}

#if DEBUG
#Preview("Claude Gmail address") {
    MailAccountSetupSheet(previewCandidates: [MailAccountCandidate(engine: .claude, provider: .gmail,
        connectionKey: "preview", email: nil)], engine: .claude)
}
#Preview("Detected mail addresses") {
    MailAccountSetupSheet(previewCandidates: [MailAccountCandidate(engine: .chatgpt, provider: .gmail,
        connectionKey: "preview", email: "you@example.com")], engine: .chatgpt)
}
#endif
