// Service sign-in and explicit per-account knowledge choice for Sentient-hosted connectors.
// Done saves consent immediately; OAuth polling never reads source content or overrides a choice.
// Doc: Documentation - Settings.md
import SwiftUI
import AppKit

struct HostedConnectorConnectSheet: View {
    let service: String
    var account: HostedConnectorAccount?
    let refreshOnOpen: Bool
    let client: HostedConnectorClient
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [HostedConnectorAccount] = []
    @State private var selectedID: UUID?
    @State private var label = "Account"
    @State private var busy = false
    @State private var busyMessage = "Finish sign-in in your browser…"
    @State private var revokeAccount: HostedConnectorAccount?
    @State private var message: String?
    @State private var attempt: HostedConnectorClient.Attempt?
    @State private var operation: Task<Void, Never>?
    @State private var choices: [UUID: Bool] = [:]
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.sentient.rawValue
    private var title: String { ConnectorRegistry.packs.first { $0.slug == service }?.displayName ?? service }

    init(service: String, account: HostedConnectorAccount? = nil, refreshOnOpen: Bool = true, client: HostedConnectorClient = .current) {
        self.service = service; self.account = account; self.refreshOnOpen = refreshOnOpen
        self.client = client
        _accounts = State(initialValue: HostedConnectorStore.accounts().filter { $0.service == service })
        _selectedID = State(initialValue: account?.id)
        let count = HostedConnectorStore.accounts().filter { $0.service == service }.count
        _label = State(initialValue: count == 0 ? "Account" : "Account \(count + 1)")
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "link").font(.system(size: 26)).foregroundStyle(.white.opacity(0.85))
            Text("Connect \(title)").display(22).foregroundStyle(Theme.Ink.statusInk)
            Text("Sign in to \(title) in your browser. Your connection works with Sentient without an AI subscription.")
                .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if ["google-calendar", "outlook-calendar"].contains(service) {
                Text("Uses the account’s primary calendar.").font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            } else if service == "google-drive" {
                Text("Reads text and Google Docs, with metadata for other files.").font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }

            if !accounts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { ForEach(accounts) { accountRow($0) } }
                }.frame(height: min(CGFloat(accounts.count) * 54 + (selectedID == nil ? 0 : 40), 280))
                    .disabled(busy)
            }
            if refreshOnOpen, let item = accounts.first(where: { $0.id == selectedID }) {
                HostedConnectorActionReview(account: item, client: client)
            }
            if !busy {
                HStack {
                    TextField("Account label", text: $label).textFieldStyle(.plain).font(.system(size: 12))
                    Button(accounts.isEmpty ? "Connect" : "Add account") { connect(reconnect: nil) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text(busyMessage).font(.system(size: 12)) }
            }
            Text(PrivacyCopy.hostedConnectors)
                .font(.system(size: 10.5)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            ConnectorActionButton(title: "Done", kind: .done) {
                for item in accounts {
                    if let chosen = choices[item.id] { ConnectorRegistry.setKBEnabled(item.slug, chosen) }
                }
                dismiss()
            }.disabled(busy)
        }
        .padding(32).frame(width: 440).background(Theme.bg)
        .overlay(alignment: .topLeading) { CloseHoverButton { dismiss() }.padding(10) }
        .task {
            guard refreshOnOpen else { return }
            accounts = HostedConnectorStore.accounts().filter { $0.service == service }
            selectedID = account?.id
            do { _ = try await client.refresh(); reload() }
            catch { message = (error as? LocalizedError)?.errorDescription ?? "Connections could not be refreshed. Your saved choices are unchanged." }
        }
        .onChange(of: backendRaw) { dismiss() }
        .confirmationDialog("Revoke service access?", isPresented: Binding(get: { revokeAccount != nil }, set: { if !$0 { revokeAccount = nil } }), titleVisibility: .visible) {
            if let item = revokeAccount {
                Button("Revoke and disconnect", role: .destructive) { disconnect(item, revokeProvider: true); revokeAccount = nil }
            }
            Button("Cancel", role: .cancel) { revokeAccount = nil }
        } message: {
            Text("The service may revoke other connections using the same Composio OAuth app. Ordinary Disconnect removes only this Sentient connection. If this service does not support revocation, remove access in its account settings.")
        }
        .onDisappear {
            operation?.cancel()
            if let attempt { Task { await client.cancel(attempt) } }
        }
    }

    private func accountRow(_ item: HostedConnectorAccount) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { selectedID = item.id } label: {
                HStack {
                    Image(systemName: selectedID == item.id ? "checkmark.circle.fill" : "circle")
                    Text(item.label).lineLimit(1)
                    Spacer()
                    Text(item.connected ? "Connected" : item.status == "revocation_pending" ? "Revocation pending" : item.status == "disconnect_pending" ? "Disconnecting" : "Reconnect")
                        .font(.system(size: 10)).foregroundStyle(Theme.Ink.body)
                }.foregroundStyle(Theme.Ink.bright)
            }.buttonStyle(.plain)
            if selectedID == item.id {
                Toggle("Use for knowledge base", isOn: Binding(
                    get: { choices[item.id] ?? ConnectorRegistry.isKBEnabled(item.slug) },
                    set: { choices[item.id] = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                HStack {
                    Button("Reconnect") { connect(reconnect: item) }.disabled(item.status.hasSuffix("_pending"))
                    Spacer()
                    Menu("Disconnect") {
                        Button("Disconnect this connection") { disconnect(item) }
                        Button("Revoke service access…") { revokeAccount = item }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(!item.connected)
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }
        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reload() { accounts = HostedConnectorStore.accounts().filter { $0.service == service } }
    private func connect(reconnect: HostedConnectorAccount?) {
        guard !busy else { return }; busy = true; message = nil; busyMessage = "Finish sign-in in your browser…"
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let started = try await client.begin(service: service,
                    label: String((reconnect?.label ?? label).prefix(100)), reconnect: reconnect)
                attempt = started
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(started.redirect_url) else { throw HostedConnectorFailure.authorizationExpired }
                for _ in 0..<200 {
                    try await Task.sleep(for: .seconds(3))
                    let completed: Bool
                    do { completed = try await client.poll(started) }
                    catch HostedInference.Failure.unavailable {
                        message = "Waiting for the connection to return. Your sign-in is still pending."
                        continue
                    } catch HostedInference.Failure.rejected(let code, let retryAt) where
                        ["connector_upstream_unavailable", "connector_rate_limited", "service_unavailable", "authentication_unavailable"].contains(code) {
                        message = "Waiting for the connection service. Your browser sign-in is preserved."
                        if let retryAt { try await Task.sleep(for: .seconds(max(1, retryAt.timeIntervalSinceNow))) }
                        continue
                    }
                    if completed {
                        try Task.checkCancellation()
                        reload(); selectedID = started.connection_id; attempt = nil
                        if reconnect == nil { choices[started.connection_id] = true }
                        message = "Connected. Choose how Sentient uses this account, then click Done."
                        return
                    }
                }
                throw HostedConnectorFailure.authorizationExpired
            } catch {
                if let attempt { await client.cancel(attempt); self.attempt = nil }
                reload()
                if !Task.isCancelled { message = (error as? LocalizedError)?.errorDescription ?? "Sign-in could not finish. Try again." }
            }
        }
    }
    private func disconnect(_ account: HostedConnectorAccount, revokeProvider: Bool = false) {
        guard !busy else { return }; busy = true; message = nil; busyMessage = "Disconnecting…"
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                try await client.disconnect(account, revokeProvider: revokeProvider); reload()
                message = accounts.first(where: { $0.id == account.id })?.status == "revocation_pending"
                    ? "Access is blocked in Sentient. Provider revocation is still pending; you can also revoke access in the service’s settings."
                    : "Access is blocked in Sentient. The saved connection is being removed; your knowledge choice stays saved until you turn it off."
            } catch { message = (error as? LocalizedError)?.errorDescription ?? "Disconnect could not finish. Try again." }
        }
    }
}

#if DEBUG
#Preview("Hosted service connection") {
    HostedConnectorConnectSheet(service: "gmail")
}
#endif
