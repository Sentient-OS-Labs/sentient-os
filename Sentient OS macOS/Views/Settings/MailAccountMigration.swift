// MailAccountMigration.swift
// Offers the email-storage disclosure to existing installations before uploading addresses.
// Doc: ../../Cloud/Mail Accounts/Documentation - Connected Email Accounts.md

import SwiftUI

/// Existing installations see the same disclosure before any address is uploaded.
struct MailAccountMigration: ViewModifier {
    @AppStorage(ModelBackend.key) private var backendRaw = ""
    @State private var present = false
    private var engine: MailAccount.Engine? { MailAccount.Engine(rawValue: ModelBackend.current.rawValue) }
    func body(content: Content) -> some View {
        content
            .task(id: backendRaw) {
                guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil,
                      ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
                await MailAccountCloud.shared.retryPendingSync()
                guard let engine,
                      !UserDefaults.standard.bool(forKey: "connectedEmail.disclosurePrompted.\(engine.rawValue)") else { return }
                let origin: ConnectorCensus.DetectedConnector.Origin = engine == .claude ? .claude : .chatgpt
                let connected = ConnectorCensus.cached(for: origin).contains { ["gmail", "outlook-mail"].contains($0.slug) }
                    || UserDefaults.standard.bool(forKey: "dbg.gmail.connected")
                guard connected else { return }
                let accounts = (try? await MailAccountCloud.shared.savedAccounts()) ?? []
                if !accounts.contains(where: { $0.engine == engine }) { present = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil else { return }
                Task { await MailAccountCloud.shared.retryPendingSync() }
            }
            .sheet(isPresented: $present, onDismiss: {
                if let engine { UserDefaults.standard.set(true, forKey: "connectedEmail.disclosurePrompted.\(engine.rawValue)") }
            }) {
                if let engine { MailAccountSetupSheet(engine: engine) }
            }
    }
}
