// MailAccountSetupSheet.swift
// Discovers connected addresses, automatically saving a clear Claude Gmail sender when the
// caller has already shown the storage disclosure. Missing addresses are skipped without entry.
// The same disclosure and validation apply to onboarding, Settings and existing installations.
// Doc: ../../Cloud/Mail Accounts/Documentation - Connected Email Accounts.md

import SwiftUI

struct MailAccountSetupSheet: View {
    static let gmailStorageDisclosure = "By pressing Done, you save your email address to Sentient's cloud database. Claude Gmail uses sender details from sent mail; message bodies stay out of this lookup."
    let engine: MailAccount.Engine
    var provider: MailAccount.Provider?
    var automaticallySaveDetectedGmail = false
    var onUnavailable: () -> Void = {}
    var onConnected: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MailAccountCandidate] = []
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?
    #if DEBUG
    private var previewOnly = false
    #endif

    init(engine: MailAccount.Engine, provider: MailAccount.Provider? = nil,
         automaticallySaveDetectedGmail: Bool = false,
         onUnavailable: @escaping () -> Void = {}, onConnected: @escaping () -> Void = {}) {
        self.engine = engine; self.provider = provider
        self.onUnavailable = onUnavailable; self.onConnected = onConnected
        self.automaticallySaveDetectedGmail = automaticallySaveDetectedGmail
    }

    #if DEBUG
    init(previewCandidates: [MailAccountCandidate], engine: MailAccount.Engine) {
        self.init(engine: engine)
        _candidates = State(initialValue: previewCandidates)
        _loading = State(initialValue: false)
        previewOnly = true
    }
    #endif

    private var detectedAccounts: [MailAccount] { candidates.compactMap(\.detectedAccount) }
    private var skippedConnectionIDs: Set<String> {
        Set(candidates.filter { $0.detectedAccount == nil }.map(\.id))
    }
    private var valid: Bool { !detectedAccounts.isEmpty }

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
                    ForEach(detectedAccounts) { candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.provider.title + " · " + (engine == .claude ? "Claude" : "ChatGPT"))
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Ink.body)
                            Text(candidate.email).font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: detectedAccounts.count > 2 ? 260 : 120)
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button(saved || !valid ? "Done" : (saving ? "Saving…" : "Save email addresses")) {
                    if saved || !valid { finish(connected: !candidates.isEmpty) } else { Task { await save() } }
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .disabled(loading || saving)
            }
        }
        .padding(30).frame(width: 480).background(Theme.bg).preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .task {
            #if DEBUG
            if previewOnly { return }
            #endif
            loading = true; message = nil
            defer { loading = false }
            do {
                candidates = try await MailAccountProbe.discover(engine: engine, provider: provider)
                try Task.checkCancellation()
                guard valid else {
                    // A connected, empty/ambiguous mailbox can still be selected as a source.
                    // No address is invented and no cloud identity is created for a skipped read.
                    finish(connected: !candidates.isEmpty)
                    return
                }
                if automaticallySaveDetectedGmail && MailAccountCandidate.canAutomaticallySaveGmail(candidates) {
                    loading = false
                    await save(automatically: true)
                    return
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                // No observed connection: return to source selection without marking it linked.
                finish(connected: false)
            }
        }
    }

    private func finish(connected: Bool) {
        if automaticallySaveDetectedGmail {
            // This explicit setup/update already displayed the storage disclosure. A skipped
            // address should not reopen the migration sheet immediately after onboarding.
            UserDefaults.standard.set(true, forKey: "connectedEmail.disclosurePrompted.\(engine.rawValue)")
        }
        if connected { onConnected() } else { onUnavailable() }
        dismiss()
    }

    private func save(automatically: Bool = false) async {
        #if DEBUG
        if previewOnly { return }
        #endif
        guard !saving else { return }
        saving = true; message = nil
        defer { saving = false }
        do {
            try Task.checkCancellation()
            guard valid else { finish(connected: !candidates.isEmpty); return }
            let synced = try await MailAccountCloud.shared.save(detectedAccounts, engine: engine, provider: provider,
                                                                preservingConnectionIDs: skippedConnectionIDs)
            try Task.checkCancellation()
            if synced || automatically { finish(connected: true) }
            else {
                saved = true
                message = "Saved securely on this Mac. Cloud sync is pending and will retry when Sentient is active."
            }
        } catch is CancellationError { return }
        catch { message = (error as? MailAccountError)?.errorDescription ?? "The addresses couldn't be saved. Please try again." }
    }
}

#if DEBUG
#Preview("Claude Gmail without a detected address") {
    MailAccountSetupSheet(previewCandidates: [MailAccountCandidate(engine: .claude, provider: .gmail,
        connectionKey: "preview", email: nil)], engine: .claude)
}
#Preview("Claude Gmail detected sender") {
    MailAccountSetupSheet(previewCandidates: [MailAccountCandidate(engine: .claude, provider: .gmail,
        connectionKey: "preview", email: "you@example.com", reportedVia: .sentMailMetadata)], engine: .claude)
}
#Preview("Detected mail addresses") {
    MailAccountSetupSheet(previewCandidates: [MailAccountCandidate(engine: .chatgpt, provider: .gmail,
        connectionKey: "preview", email: "you@example.com")], engine: .chatgpt)
}
#endif
