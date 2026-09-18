//
// ConnectorConnectSheet.swift
// Gmail-style connection popup for catalog apps and all detected accounts. Uses the pane's live
// discovery state and starts direct browser sign-in here. Knowledge selection remains explicit
// and direct accounts retain their IDs.
// Doc: Documentation - Settings.md
//

import SwiftUI

struct ConnectorConnectSheet: View {
    let source: ConnectorSource
    @Binding var connectors: [ConnectorCensus.DetectedConnector]
    let onRefresh: () async -> Void
    let onConnect: () -> Void
    var refreshing = false

    @Environment(\.dismiss) private var dismiss
    @State private var boundConnectorID: String?
    @State private var connectionPhase: DirectMCPConnectPhase?
    @State private var newConnectionID: UUID?
    @State private var connectionCompleted = false
    @State private var checking = false
    @State private var disconnecting = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?

    init(source: ConnectorSource, connectors: Binding<[ConnectorCensus.DetectedConnector]>,
         onRefresh: @escaping () async -> Void, onConnect: @escaping () -> Void,
         refreshing: Bool = false) {
        self.source = source
        _connectors = connectors
        self.onRefresh = onRefresh
        self.onConnect = onConnect
        self.refreshing = refreshing
        _boundConnectorID = State(initialValue: source.connector?.id)
    }

    private var connector: ConnectorCensus.DetectedConnector? {
        if let newConnectionID {
            let id = DirectMCPStore.connection(id: newConnectionID)?.detected.id
            return connectors.first { $0.id == id }
        }
        if let boundConnectorID { return connectors.first { $0.id == boundConnectorID } }
        return connectors.first { ConnectorRegistry.pack(for: $0)?.slug == source.serviceSlug }
    }

    private var direct: DirectMCPConnection? {
        if let newConnectionID { return DirectMCPStore.connection(id: newConnectionID) }
        return connector.flatMap { DirectMCPStore.connection($0.slug) }
    }

    private var usesDirect: Bool {
        (connector ?? source.connector).map { $0.origin == .direct } ?? (source.directProvider != nil)
    }

    private var healthy: Bool { connector?.healthy == true }
    private var connecting: Bool { connectionPhase != nil }
    private var busy: Bool { connecting || checking || disconnecting }
    private var connectTitle: String {
        switch connectionPhase {
        case .openingBrowser: "Opening sign-in…"
        case .waitingForBrowser: "Waiting for sign-in…"
        case .verifyingAccount, .checkingTools: "Verifying connection…"
        case nil: connector == nil ? "Connect \(name)" : "Reconnect \(name)"
        }
    }
    private var name: String { ConnectorRegistry.pack(forSlug: source.serviceSlug)?.displayName ?? source.displayName }
    private var origin: ConnectorCensus.DetectedConnector.Origin? {
        (connector ?? source.connector)?.origin ?? .init(backend: ModelBackend.current)
    }
    private var reader: String { origin == .claude ? "Claude" : "ChatGPT" }

    var body: some View {
        VStack(spacing: 0) {
            serviceIcon
            Text("Connect \(name)")
                .display(20).foregroundStyle(Theme.Ink.statusInk)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 9) {
                if usesDirect {
                    bullet("link", "Sign in to \(name) in your browser")
                    bullet("lock", "Your connection stays in this Mac's Keychain")
                    bullet("sparkles", "Your selected AI processes the content you request")
                } else {
                    bullet("icloud.slash", "Your \(reader) reads \(name), never our servers")
                    bullet("link", "Link your account on \(reader)'s connectors page")
                    bullet("lock", "Sentient never sees your password")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)

            if let direct {
                VStack(spacing: 4) {
                    Text(direct.label).foregroundStyle(Theme.Ink.bright)
                    Text(direct.accountLabel ?? "Uses the account you approved in the browser.")
                        .foregroundStyle(Theme.Ink.body)
                }
                .font(.system(size: 11)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            }

            if let connector, ConnectorRegistry.kbEligible(connector.slug) {
                ConnectorKnowledgeControl(slug: connector.slug, healthy: healthy)
                    .disabled(busy)
                    .padding(.top, 20)
            } else if healthy {
                Text("Available for tasks. This app does not support knowledge-base analysis.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            }

            actionButton(connectTitle,
                         primary: true, external: !connecting, action: connect)
                .padding(.top, 26)
                .disabled(busy || direct?.state == .verifying)
            actionButton(checking || refreshing ? "Checking…" : "Done", action: done)
                .padding(.top, 10).disabled(busy || refreshing)

            statusLine.padding(.top, 14).frame(minHeight: 42, alignment: .top)

            if direct != nil {
                Button(disconnecting ? "Disconnecting…" : "Disconnect account", action: disconnect)
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(Theme.Ink.deepMuted)
                    .padding(.top, 18).disabled(busy)
            }
        }
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 400).background(Theme.bg)
        .overlay(alignment: .topLeading) {
            CloseHoverButton { dismiss() }.padding(12).disabled(disconnecting)
        }
        .animation(.easeOut(duration: 0.2), value: healthy)
        .onChange(of: connector?.id, initial: true) { _, id in
            // Once linked, never silently move this popup to another account of the service.
            if boundConnectorID == nil { boundConnectorID = id }
        }
        .onChange(of: connector) {
            if !usesDirect && healthy { message = nil }
        }
        .onDisappear(perform: cancelOperation)
    }

    @ViewBuilder private var serviceIcon: some View {
        if source.isCurated, let asset = source.logoAsset {
            ConnectorLogo(asset: asset)
                .padding(.bottom, 18)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.faint).frame(width: 16)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, primary: Bool = false, external: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if (connecting && primary) || (checking && !primary) {
                    ProgressView().controlSize(.mini)
                }
                Text(title).font(.system(size: primary ? 14 : 13.5, weight: primary ? .semibold : .medium))
                if external { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(primary ? .black : Theme.Ink.bright)
            .frame(maxWidth: .infinity, minHeight: primary ? 44 : 40)
            .background(Capsule().fill(.white.opacity(primary ? 1 : 0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.16), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var statusLine: some View {
        Group {
            if let message {
                Text(message).foregroundStyle(Theme.Ink.amber)
            } else if let connectionPhase {
                switch connectionPhase {
                case .openingBrowser:
                    Text("Opening \(name)'s sign-in page…").foregroundStyle(Theme.Ink.body)
                case .waitingForBrowser:
                    Text("Finish signing in in your browser.").foregroundStyle(Theme.Ink.body)
                case .verifyingAccount:
                    Text("Signed in. Verifying your account…").foregroundStyle(Theme.Ink.body)
                case .checkingTools:
                    Text("Signed in. Checking available tools. This can take a moment.").foregroundStyle(Theme.Ink.body)
                }
            } else if checking {
                Text("Checking your connection…").foregroundStyle(Theme.Ink.body)
            } else if healthy {
                Label("\(name) connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Ink.green)
            } else if direct?.state == .verifying {
                Text("Connection setup is in progress.").foregroundStyle(Theme.Ink.body)
            } else if connector != nil {
                Text("This connection needs attention. Sign in again, then press Done.")
                    .foregroundStyle(Theme.Ink.amber)
            } else {
                Text(usesDirect ? "Connect your account to get started." : "Linked it on the page? Press Done and I'll check.")
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private func connect() {
        guard !busy else { return }
        message = nil
        guard usesDirect else { onConnect(); return }
        guard let provider = direct?.provider ?? source.directProvider else { return }
        let existing = direct
        let id = existing?.id ?? newConnectionID ?? UUID()
        let label = existing?.label ?? nextAccountLabel(for: provider)
        if existing == nil { newConnectionID = id }
        connectionPhase = .openingBrowser
        operation = Task {
            defer { connectionPhase = nil }
            do {
                _ = try await DirectMCPConnections.shared.connect(provider: provider, label: label, replacing: id,
                    onProgress: { phase in
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            connectionPhase = phase
                        }
                    })
                guard !Task.isCancelled else { return }
                connectionCompleted = true
                if let connection = DirectMCPStore.connection(id: id) {
                    boundConnectorID = connection.detected.id
                    connectors.removeAll { $0.id == connection.detected.id }
                    connectors.append(connection.detected)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = (error as? DirectMCPError)?.errorDescription
                    ?? "The connection couldn't be verified. Please try again."
            }
        }
    }

    private func nextAccountLabel(for provider: DirectMCPProvider) -> String {
        let accounts = DirectMCPStore.connections().filter { $0.providerSlug == provider.slug }
        var label = "Account"
        var number = 2
        while accounts.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
            label = "Account \(number)"
            number += 1
        }
        return label
    }

    private func cancelOperation() {
        let pending = operation
        pending?.cancel()
        guard let newConnectionID, !connectionCompleted else { return }
        // Wait for OAuth cancellation to settle before removing this sheet's unfinished account.
        // Reconnects retain their existing grant through DirectMCPConnections' recovery path.
        Task {
            await pending?.value
            _ = try? await DirectMCPConnections.shared.disconnect(newConnectionID)
        }
    }

    private func done() {
        if healthy { dismiss(); return }
        checking = true
        message = nil
        operation = Task {
            await onRefresh()
            guard !Task.isCancelled else { return }
            checking = false
            if !healthy {
                message = "Couldn't confirm \(name) yet. Finish connecting, then press Done again."
            }
        }
    }

    private func disconnect() {
        guard let direct else { return }
        disconnecting = true
        message = nil
        operation = Task {
            do {
                _ = try await DirectMCPConnections.shared.disconnect(direct.id)
                dismiss()
            } catch {
                message = "Local access couldn't be fully removed. Please try again."
            }
            disconnecting = false
        }
    }
}

/// The existing opt-in, on its production key. Discovery never selects a source for the user.
private struct ConnectorKnowledgeControl: View {
    let healthy: Bool
    @AppStorage private var enabled: Bool

    init(slug: String, healthy: Bool) {
        self.healthy = healthy
        _enabled = AppStorage(wrappedValue: false, ConnectorRegistry.kbKey(slug))
    }

    var body: some View {
        VStack(spacing: 10) {
            SettingsHairline()
            HStack(spacing: 12) {
                Text("Use for knowledge base")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                Spacer(minLength: 12)
                Toggle("Use for knowledge base", isOn: $enabled)
                    .labelsHidden().toggleStyle(.switch).tint(Theme.Ink.green)
                    .disabled(!healthy && !enabled)
            }
            Text("Include this app in your analysis and nightly updates.")
                .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Connect Google Drive · not connected") {
    ConnectorConnectSheet(source: ConnectorSource.catalog(with: [])[0], connectors: .constant([]),
                          onRefresh: {}, onConnect: {})
}

#Preview("Connect Asana · no logo") {
    let connector = ConnectorCensus.DetectedConnector(
        slug: "asana", displayName: "Asana", origin: .claude,
        serverURL: nil, catalogID: nil, iconPath: nil, healthy: true, lastSeen: .now)
    if let source = ConnectorSource.catalog(with: [connector]).first(where: { $0.id == connector.id }) {
        ConnectorConnectSheet(source: source, connectors: .constant([connector]),
                              onRefresh: {}, onConnect: {})
    }
}
