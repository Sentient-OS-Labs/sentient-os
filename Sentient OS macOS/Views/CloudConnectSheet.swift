//
//  CloudConnectSheet.swift
//  Sentient OS macOS
//
//  The Gmail / Google Calendar connect popup — ONE sheet for both cloud sources (they are exact
//  twins: same connector page flow and storage shape), engine-aware: the
//  ChatGPT backend links on OpenAI's hosted connector page, the Claude backend on claude.ai's
//  connector directory (GmailConnect/CalendarConnect.connectorURL pick; the copy follows). Flow:
//    Connect …  → opens the engine's connector page (the user links Google there).
//    Done       → appears after Connect opens the browser; saves the user's selection.
//    ✕ (top-left) → closes without saving.
//  Already connected → "Stop reading …" clears selection, not the provider connection.
//
//  Presented from Settings → Knowledge Sources, the home's Analysis popover, onboarding's ready
//  screen, and Dev Tools. See GmailConnect / CalendarConnect for the codex side.
//

import SwiftUI
import AppKit

struct CloudConnectSheet: View {
    enum Service {
        case gmail, calendar

        var logoAsset: String { self == .gmail ? "GmailMark" : "GoogleCalendarMark" }
        var title: String { self == .gmail ? "Gmail" : "Google Calendar" }
        var connectTitle: String { self == .gmail ? "Connect Gmail" : "Connect Calendar" }
        var stopLine: String { self == .gmail ? "Stop reading Gmail" : "Stop reading Google Calendar" }
        var connectorURL: URL { self == .gmail ? GmailConnect.connectorURL : CalendarConnect.connectorURL }
        var slug: String { self == .gmail ? "gmail" : "google-calendar" }
        var connectedKey: String { self == .gmail ? "dbg.gmail.connected" : "dbg.calendar.connected" }
        var selectedKey: String { self == .gmail ? "dbg.run.gmail" : "dbg.run.calendar" }
        var analyticsName: String { self == .gmail ? "gmail" : "calendar" }
    }

    private let service: Service
    private let backend: ModelBackend
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var connected: Bool
    @AppStorage private var selected: Bool
    @AppStorage(ModelBackend.key) private var backendRaw = ""

    @State private var openedConnectorPage = false

    init(_ service: Service) {
        self.service = service
        self.backend = .current
        let connection = AppStorage(wrappedValue: false, service.connectedKey)
        let selection = AppStorage(wrappedValue: false, service.selectedKey)
        _connected = connection
        _selected = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectorLogo(asset: service.logoAsset)

            Text(service.title)
                .display(20)
                .foregroundStyle(Theme.Ink.statusInk)
                .padding(.top, 18)

            if !selected {
                Text(openedConnectorPage
                     ? "Connect \(service.title) to your \(backend == .claude ? "Claude" : "ChatGPT") account, and then come back to Sentient."
                     : "Sentient reads through your \(backend == .claude ? "Claude" : "ChatGPT") connector. Enable it and sign in on that page, then press Done.")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Ink.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }

            connectButton.padding(.top, 26)
            if selected {
                stopLink.padding(.top, 18)
            } else if openedConnectorPage {
                doneButton.padding(.top, 14)
            }
        }
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 400)
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { closeButton.padding(12) }
        .onChange(of: backendRaw) { dismiss() }
    }

    // MARK: - The two buttons (+ the ✕)

    private var connectButton: some View {
        ConnectorActionButton(title: selected ? "Open connector settings" : service.connectTitle,
                              action: openConnectorPage)
    }

    private func openConnectorPage() {
        guard ModelBackend.current == backend, backend != .custom else { dismiss(); return }
        if NSWorkspace.shared.open(service.connectorURL) {
            openedConnectorPage = true
            HostedConnectorSetup.settingsOpened(slug: service.slug, backend: backend)
        }
    }

    private var doneButton: some View {
        ConnectorActionButton(title: "Done", kind: .done, action: done)
    }

    private var closeButton: some View {
        CloseHoverButton { dismiss() }
    }

    /// Reading remains an explicit opt-in.
    private var stopLink: some View {
        Button(service.stopLine) {
            guard ModelBackend.current == backend else { dismiss(); return }
            selected = false
            dismiss()
        }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.Ink.deepMuted)
    }

    // MARK: - Done: trust the user's declaration without waiting for provider discovery

    private func done() {
        let firstConnection = !connected
        guard HostedConnectorSetup.confirm(slug: service.slug, backend: backend,
                                           reconnected: openedConnectorPage) else { dismiss(); return }
        if firstConnection { Analytics.signal("Source.connected", parameters: ["source": service.analyticsName]) }
        dismiss()
    }

}

/// The quiet ✕ — a small glass circle that brightens on hover.
struct CloseHoverButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hover ? .white : Theme.Ink.label)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Close")
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

#Preview("Connect Gmail") {
    CloudConnectSheet(.gmail)
}

#Preview("Connect Google Calendar") {
    CloudConnectSheet(.calendar)
}
