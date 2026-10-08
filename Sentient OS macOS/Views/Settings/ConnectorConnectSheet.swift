//
// ConnectorConnectSheet.swift
// Hosted connection popups save the user's selection immediately. Direct accounts retain their
// browser OAuth, account IDs, knowledge toggle and cancellation lifecycle.
// Doc: Documentation - Settings.md
//

import SwiftUI
import AppKit

struct ConnectorConnectSheet: View {
    let source: ConnectorSource
    @Binding var connectors: [ConnectorCensus.DetectedConnector]
    let context: KnowledgeSourcesPicker.Context

    @Environment(\.dismiss) private var dismiss
    @State private var openedConnectorPage = false
    @State private var startedDirectConnection = false
    @State private var boundConnectorID: String?
    @State private var connectionPhase: DirectMCPConnectPhase?
    @State private var newConnectionID: UUID?
    @State private var connectionCompleted = false
    @State private var disconnecting = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @AppStorage private var hostedSelected: Bool
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    private let hostedBackend: ModelBackend

    init(source: ConnectorSource, connectors: Binding<[ConnectorCensus.DetectedConnector]>,
         context: KnowledgeSourcesPicker.Context = .settings) {
        self.source = source
        _connectors = connectors
        self.context = context
        _boundConnectorID = State(initialValue: source.connector?.id)
        _hostedSelected = AppStorage(wrappedValue: false,
            ConnectorRegistry.kbKey(source.connector?.slug ?? source.serviceSlug))
        switch source.connector?.origin {
        case .claude: hostedBackend = .claude
        case .chatgpt: hostedBackend = .chatgpt
        default: hostedBackend = ModelBackend.current
        }
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

    private var selectionSlug: String { connector?.slug ?? source.serviceSlug }
    private var connecting: Bool { connectionPhase != nil }
    private var busy: Bool { connecting || disconnecting }
    private var connectTitle: String {
        switch connectionPhase {
        case .openingBrowser: "Opening sign-in…"
        case .waitingForBrowser: "Waiting for sign-in…"
        case .savingConnection: "Saving connection…"
        case .checkingTools: "Preparing tools…"
        case nil: connector == nil ? "Connect \(name)" : "Reconnect \(name)"
        }
    }
    private var name: String { ConnectorRegistry.pack(forSlug: source.serviceSlug)?.displayName ?? source.displayName }
    private var reader: String { hostedBackend == .claude ? "Claude" : "ChatGPT" }
    private var hostedCanRead: Bool { ConnectorRegistry.kbEligible(source.serviceSlug, backend: hostedBackend) }
    private var hostedConnected: Bool {
        if hostedCanRead { return hostedSelected }
        // Task-only apps have no reading preference. Keep their saved declaration without
        // inventing an analysis opt-in or treating a cached health result as a setup gate.
        guard let origin = ConnectorCensus.DetectedConnector.Origin(backend: hostedBackend) else { return false }
        return ConnectorCensus.cached(for: origin).contains { $0.slug == selectionSlug }
    }

    var body: some View {
        VStack(spacing: 0) {
            serviceIcon
            Text(usesDirect ? "Connect \(name)" : name)
                .display(20).foregroundStyle(Theme.Ink.statusInk)
                .multilineTextAlignment(.center)

            if usesDirect {
                VStack(alignment: .leading, spacing: 9) {
                    bullet("link", "Sign in to \(name) in your browser")
                    bullet("lock", "Your connection stays in this Mac's Keychain")
                    bullet("sparkles", "Your selected AI processes the content you request")
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

                if ConnectorRegistry.kbEligible(selectionSlug) {
                    if context == .settings {
                        ConnectorKnowledgeControl(slug: selectionSlug)
                            .disabled(busy)
                            .padding(.top, 20)
                    }
                } else if connector != nil {
                    taskOnlyNotice
                        .padding(.top, 20)
                }

                if startedDirectConnection {
                    Text("Sign in to \(name) in your browser, and then come back to Sentient.")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Ink.body)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }

                ConnectorActionButton(title: connectTitle, isLoading: connecting, action: connect)
                    .padding(.top, 26)
                    .disabled(busy)
                if startedDirectConnection {
                    ConnectorActionButton(title: "Done", kind: .done, action: done)
                        .padding(.top, 14).disabled(busy)
                }

                statusLine.padding(.top, 14).frame(minHeight: 42, alignment: .top)

                if direct != nil {
                    Button(disconnecting ? "Disconnecting…" : "Disconnect account", action: disconnect)
                        .buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.deepMuted)
                        .padding(.top, 18).disabled(busy)
                }
            } else {
                hostedControls
            }
        }
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 400).background(Theme.bg)
        .overlay(alignment: .topLeading) {
            CloseHoverButton { dismiss() }.padding(12).disabled(disconnecting)
        }
        .onChange(of: connector?.id, initial: true) { _, id in
            // Once linked, never silently move this popup to another account of the service.
            if boundConnectorID == nil { boundConnectorID = id }
        }
        .onChange(of: backendRaw) { if !usesDirect { dismiss() } }
        .onDisappear(perform: cancelOperation)
    }

    private var hostedControls: some View {
        VStack(spacing: 0) {
            if !hostedConnected {
                Text(hostedInstructions)
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                if hostedBackend == .claude && ["outlook-mail", "outlook-calendar"].contains(source.serviceSlug) {
                    Text("Uses Microsoft 365 with a work or school account.")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }

            ConnectorActionButton(title: hostedConnected ? "Open connector settings" : "Connect \(name)",
                                  action: connect)
                .padding(.top, 26)

            if hostedConnected {
                if hostedCanRead {
                    Button("Stop reading \(name)", action: stopHostedReading)
                        .buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.deepMuted)
                        .padding(.top, 18)
                } else {
                    taskOnlyNotice
                        .padding(.top, 18)
                }
            } else if openedConnectorPage {
                ConnectorActionButton(title: "Done", kind: .done, action: done)
                    .padding(.top, 14)
            }
        }
    }

    private var hostedInstructions: String {
        if openedConnectorPage {
            return "Connect \(name) to your \(reader) account, and then come back to Sentient."
        }
        return hostedCanRead
            ? "Sentient reads \(name) through your \(reader) connector. Enable it and sign in there, then press Done."
            : "Enable \(name) in your \(reader) connectors and sign in there, then press Done to use it for tasks."
    }

    private var taskOnlyNotice: some View {
        Text("Available for tasks. This app does not support knowledge-base analysis.")
            .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
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
                case .savingConnection:
                    Text("Saving your sign-in…").foregroundStyle(Theme.Ink.body)
                case .checkingTools:
                    Text("Signed in. Checking available tools. This can take a moment.").foregroundStyle(Theme.Ink.body)
                }
            } else {
                Text("Sign in in your browser, then press Done.")
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private func connect() {
        guard !busy else { return }
        message = nil
        guard usesDirect else {
            openConnectorPage()
            return
        }
        guard let provider = direct?.provider ?? source.directProvider else { return }
        startedDirectConnection = true
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
                    // Carry the catalog choice onto this account's stable source key.
                    let defaults = UserDefaults.standard
                    if let enabled = defaults.object(forKey: ConnectorRegistry.kbKey(source.serviceSlug)) as? Bool {
                        ConnectorRegistry.setKBEnabled(connection.slug, enabled)
                        defaults.removeObject(forKey: ConnectorRegistry.kbKey(source.serviceSlug))
                    }
                    boundConnectorID = connection.detected.id
                    connectors.removeAll { $0.id == connection.detected.id }
                    connectors.append(connection.detected)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = (error as? DirectMCPError)?.errorDescription
                    ?? "Sign-in couldn't be completed. Please try again."
            }
        }
    }

    private func openConnectorPage() {
        guard ModelBackend.current == hostedBackend, hostedBackend != .custom else { dismiss(); return }
        if NSWorkspace.shared.open(ConnectorLinks.page(for: source.serviceSlug, backend: hostedBackend)) {
            openedConnectorPage = true
            HostedConnectorSetup.settingsOpened(slug: source.serviceSlug, backend: hostedBackend)
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
        guard !busy else { return }
        if !usesDirect {
            _ = HostedConnectorSetup.confirm(slug: source.serviceSlug, backend: hostedBackend,
                                              reconnected: openedConnectorPage)
            dismiss()
            return
        }
        if ConnectorRegistry.kbEligible(selectionSlug),
           UserDefaults.standard.object(forKey: ConnectorRegistry.kbKey(selectionSlug)) == nil {
            ConnectorRegistry.setKBEnabled(selectionSlug, true)
        }
        dismiss()
    }

    private func stopHostedReading() {
        guard ModelBackend.current == hostedBackend else { dismiss(); return }
        hostedSelected = false
        dismiss()
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
    @AppStorage private var enabled: Bool

    init(slug: String) {
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
            }
            Text("Include this app in your analysis and nightly updates.")
                .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Connect Google Drive · not connected") {
    ConnectorConnectSheet(source: ConnectorSource.catalog(with: [])[0], connectors: .constant([]))
}

#Preview("Onboarding · connect Granola") {
    if let source = ConnectorSource.catalog(with: []).first(where: { $0.serviceSlug == "granola" }) {
        ConnectorConnectSheet(source: source, connectors: .constant([]), context: .onboarding)
    }
}

#Preview("Connect Asana · no logo") {
    let connector = ConnectorCensus.DetectedConnector(
        slug: "asana", displayName: "Asana", origin: .claude,
        serverURL: nil, catalogID: nil, iconPath: nil, healthy: true, lastSeen: .now)
    if let source = ConnectorSource.catalog(with: [connector]).first(where: { $0.id == connector.id }) {
        ConnectorConnectSheet(source: source, connectors: .constant([connector]))
    }
}
