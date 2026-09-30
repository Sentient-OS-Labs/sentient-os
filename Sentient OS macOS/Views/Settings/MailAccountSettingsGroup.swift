// MailAccountSettingsGroup.swift
// Lists locally saved mail addresses, retries cloud sync and deletes this installation's records.
// Doc: ../../Cloud/Mail Accounts/Documentation - Connected Email Accounts.md

import SwiftUI

struct MailAccountSettingsGroup: View {
    @State private var accounts: [MailAccount] = []
    @State private var pending = false
    @State private var updating = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        SettingsGroup(label: "Saved email addresses") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Sentient stores your connected email addresses in its cloud database. Each installation can access only its own records. Your mailbox content and provider credentials are not stored there.")
                ForEach(accounts.sorted { $0.id < $1.id }) { account in
                    Text("\(account.email) · \(account.provider.title) · \(account.engine == .claude ? "Claude" : "ChatGPT")")
                        .font(.system(size: 12)).foregroundStyle(Theme.Ink.bright).textSelection(.enabled)
                }
                if pending { Text("Cloud sync pending").font(.system(size: 11)).foregroundStyle(Theme.Ink.amber) }
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(Theme.Ink.amber) }
                HStack {
                    SettingsPillButton(title: updating ? "Updating…" : "Add or update addresses", action: update)
                        .disabled(deleting || updating || ModelBackend.current == .custom)
                    if !accounts.isEmpty {
                        SettingsPillButton(title: deleting ? "Deleting…" : "Delete saved addresses", tint: Theme.Ink.red) { confirmDelete = true }
                            .disabled(deleting || updating)
                    }
                }
                if pending {
                    Button("Retry sync") { Task { await MailAccountCloud.shared.retryPendingSync(); await reload() } }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                }
            }
        }
        .task { await reload() }
        .alert("Delete saved email addresses?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleting = true; message = nil
                Task {
                    defer { deleting = false }
                    do { try await MailAccountCloud.shared.erase(); await reload() }
                    catch { message = "Deletion couldn't finish. Connect to the internet and try again. Your saved credentials are retained so deletion can be retried." }
                }
            }
        } message: {
            Text("Removes this installation's email records from Supabase and this Mac. Your Gmail and Outlook connections stay connected.")
        }
    }

    private func update() {
        guard !updating, let engine = MailAccount.Engine(rawValue: ModelBackend.current.rawValue) else { return }
        updating = true; message = nil
        Task {
            defer { updating = false }
            do {
                let outcome = try await MailAccountCollection.collect(engine: engine)
                switch outcome {
                case .noConnection: message = "No connected email accounts were found."
                case .noAddress: message = "No email address was detected. Nothing was saved."
                case .saved, .pending: break
                }
                await reload()
            } catch { message = (error as? MailAccountError)?.errorDescription ?? "Account details couldn't be saved. Please try again." }
        }
    }

    private func reload() async {
        do {
            accounts = try await MailAccountCloud.shared.savedAccounts()
            pending = try await MailAccountCloud.shared.hasPendingSync()
        } catch { message = "Unlock your Mac to read its saved account details." }
    }
}
