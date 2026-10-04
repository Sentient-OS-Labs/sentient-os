//
//  CloudConnectSheet.swift
//  Sentient OS macOS
//
//  The Gmail / Google Calendar connect popup — ONE sheet for both cloud sources (they are exact
//  twins: same connector page flow and storage shape), engine-aware: the
//  ChatGPT backend links on OpenAI's hosted connector page, the Claude backend on claude.ai's
//  connector directory (GmailConnect/CalendarConnect.connectorURL pick; the copy follows). Flow:
//    Connect …  → opens the engine's connector page (the user links Google there).
//    Done       → Gmail reads and saves the connected email address; Calendar saves selection.
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
        var title: String { self == .gmail ? "Connect Gmail" : "Connect Google Calendar" }
        var connectTitle: String { self == .gmail ? "Connect Gmail" : "Connect Calendar" }
        var bullets: [(icon: String, text: String)] {
            let claude = ModelBackend.current == .claude
            let reader = claude ? "your Claude" : "your ChatGPT"
            let page = claude ? "Claude's page" : "OpenAI's page"
            return [("person.crop.circle", self == .gmail ? "Read email through \(reader)"
                                                          : "Read calendar through \(reader)"),
                    ("link", "Link your Google account on \(page)"),
                    ("lock", "Sign in directly with your provider")]
        }
        var connectedLine: String { self == .gmail ? "Gmail selected" : "Calendar selected" }
        var stopLine: String { self == .gmail ? "Stop reading Gmail" : "Stop reading Google Calendar" }
        var connectorURL: URL { self == .gmail ? GmailConnect.connectorURL : CalendarConnect.connectorURL }
        var connectedKey: String { self == .gmail ? "dbg.gmail.connected" : "dbg.calendar.connected" }
        var selectedKey: String { self == .gmail ? "dbg.run.gmail" : "dbg.run.calendar" }
        var analyticsName: String { self == .gmail ? "gmail" : "calendar" }
    }

    private let service: Service
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var connected: Bool
    @AppStorage private var selected: Bool
    @AppStorage(ModelBackend.key) private var backendRaw = ""

    private enum Phase { case idle, connected }
    @State private var openedConnectorPage = false
    @State private var checkingEmail = false
    @State private var emailCheck: Task<Void, Never>?
    @State private var emailCheckError: String?
    @State private var phase: Phase

    init(_ service: Service) {
        self.service = service
        let connection = AppStorage(wrappedValue: false, service.connectedKey)
        let selection = AppStorage(wrappedValue: false, service.selectedKey)
        _connected = connection
        _selected = selection
        // Resolve the opening state before presentation, so the sheet's initial layout isn't animated.
        _phase = State(initialValue: selection.wrappedValue ? .connected : .idle)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectorLogo(asset: service.logoAsset)

            Text(service.title)
                .display(20)
                .foregroundStyle(Theme.Ink.statusInk)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(service.bullets, id: \.text) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: line.icon)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.faint)
                            .frame(width: 16)
                        Text(line.text).font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                    }
                }
            }
            .padding(.top, 14)

            if service == .gmail {
                Text(MailAccountCollection.storageDisclosure)
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }

            connectButton.padding(.top, 26).disabled(checkingEmail)
            doneButton.padding(.top, 10).disabled(checkingEmail)

            statusLine
                .padding(.top, 14)
                .frame(minHeight: 42, alignment: .top)
                .animation(.easeOut(duration: 0.2), value: phase)

            if selected {
                stopLink.padding(.top, 2)
            }
        }
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 400)
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { closeButton.padding(12) }
        .onChange(of: backendRaw) { dismiss() }
        .onDisappear { emailCheck?.cancel() }
    }

    // MARK: - The two buttons (+ the ✕)

    private var connectButton: some View {
        Button {
            phase = .idle
            openedConnectorPage = true
            NSWorkspace.shared.open(service.connectorURL)
        } label: {
            HStack(spacing: 7) {
                Text(service.connectTitle).font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule(style: .continuous).fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var doneButton: some View {
        Button(action: done) {
            HStack(spacing: 7) {
                Text(checkingEmail ? "Checking…" : "Done")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(Theme.Ink.bright)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Capsule().fill(.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var closeButton: some View {
        CloseHoverButton { dismiss() }
    }

    // MARK: - The instruction or saved selection

    private var statusLine: some View {
        Group {
            if checkingEmail {
                Text("Checking your connected email…").foregroundStyle(Theme.Ink.body)
            } else if let emailCheckError {
                Text(emailCheckError).foregroundStyle(Theme.Ink.amber)
            } else if phase == .connected {
                Label(service.connectedLine, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Ink.green)
            } else {
                Text("Linked it on the page? Press Done to use it in Sentient.")
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Reading remains an explicit opt-in.
    private var stopLink: some View {
        Button(service.stopLine) { selected = false; dismiss() }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.Ink.deepMuted)
    }

    // MARK: - Done: collect the address and select the source

    private func done() {
        if service == .gmail {
            guard !checkingEmail, let engine = MailAccount.Engine(rawValue: ModelBackend.current.rawValue) else { return }
            checkingEmail = true; emailCheckError = nil
            emailCheck = Task {
                defer { checkingEmail = false }
                do {
                    let result = try await MailAccountCollection.collect(engine: engine, provider: .gmail)
                    try Task.checkCancellation()
                    guard ModelBackend.current.rawValue == engine.rawValue else { return }
                    if result.connectionAvailable { confirmDone() } else { dismiss() }
                } catch is CancellationError { return }
                catch { emailCheckError = (error as? MailAccountError)?.errorDescription ?? "Account details couldn't be saved. Please try again." }
            }
            return
        }
        confirmDone()
    }

    private func confirmDone() {
        if !connected { Analytics.signal("Source.connected", parameters: ["source": service.analyticsName]) }
        // Keep the production connection key as the user's declaration for task routing.
        ConnectorCensus.confirmSelection(slug: service == .gmail ? "gmail" : "google-calendar",
                                         reconnected: openedConnectorPage)
        connected = true
        selected = true
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
