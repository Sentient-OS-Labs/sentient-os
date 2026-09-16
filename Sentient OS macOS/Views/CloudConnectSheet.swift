//
//  CloudConnectSheet.swift
//  Sentient OS macOS
//
//  The Gmail / Google Calendar connect popup — ONE sheet for both cloud sources (they are exact
//  twins: same connector page flow, shared connector census, same storage shape), engine-aware: the
//  ChatGPT backend links on OpenAI's hosted connector page, the Claude backend on claude.ai's
//  connector directory (GmailConnect/CalendarConnect.connectorURL pick; the copy follows). Flow:
//    Connect …  → opens the engine's connector page (the user links Google there).
//    Done       → refreshes ConnectorCensus (Claude health list / Codex refreshed plugin cache).
//                 A healthy record selects the source, shows a success status, and dismisses.
//                 A missing or unhealthy record shows a quiet amber retry line.
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
            let reader = claude ? "Your Claude" : "Your ChatGPT"
            let page = claude ? "Claude's page" : "OpenAI's page"
            return [("icloud.slash", self == .gmail ? "\(reader) reads your email, never our servers"
                                                    : "\(reader) reads your calendar, never our servers"),
                    ("link", "Link your Google account on \(page)"),
                    ("lock", "Sentient never sees your password")]
        }
        var connectedLine: String { self == .gmail ? "Gmail connected" : "Calendar connected" }
        var failedLine: String {
            self == .gmail
            ? "Couldn't see Gmail yet. Finish linking on the page, then press Done again."
            : "Couldn't see your calendar yet. Finish linking on the page, then press Done again."
        }
        var stopLine: String { self == .gmail ? "Stop reading Gmail" : "Stop reading Google Calendar" }
        var connectorURL: URL { self == .gmail ? GmailConnect.connectorURL : CalendarConnect.connectorURL }
        var connectedKey: String { self == .gmail ? "dbg.gmail.connected" : "dbg.calendar.connected" }
        var selectedKey: String { self == .gmail ? "dbg.run.gmail" : "dbg.run.calendar" }
        var analyticsName: String { self == .gmail ? "gmail" : "calendar" }

        func probe() async -> Bool {
            self == .gmail ? await GmailConnect.probeConnected() : await CalendarConnect.probeConnected()
        }
    }

    private let service: Service
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var connected: Bool
    @AppStorage private var selected: Bool
    @AppStorage(ModelBackend.key) private var backendRaw = ""

    private enum Phase { case idle, checking, connected, failed }
    @State private var phase: Phase
    @State private var operation: Task<Void, Never>?

    init(_ service: Service) {
        self.service = service
        let connection = AppStorage(wrappedValue: false, service.connectedKey)
        let selection = AppStorage(wrappedValue: false, service.selectedKey)
        _connected = connection
        _selected = selection
        // Resolve the opening state before presentation, so the sheet's initial layout isn't animated.
        _phase = State(initialValue: connection.wrappedValue && selection.wrappedValue ? .connected : .idle)
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

            connectButton.padding(.top, 26)
            doneButton.padding(.top, 10)

            statusLine
                .padding(.top, 14)
                .frame(minHeight: 42, alignment: .top)
                .animation(.easeOut(duration: 0.2), value: phase)

            if connected && selected && phase != .checking {
                stopLink.padding(.top, 2)
            }
        }
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 400)
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { closeButton.padding(12) }
        .onChange(of: connected) { _, linked in
            if !linked && phase != .checking { phase = .idle }
        }
        .onChange(of: backendRaw) { operation?.cancel(); dismiss() }
        .onDisappear { operation?.cancel() }
    }

    // MARK: - The two buttons (+ the ✕)

    private var connectButton: some View {
        Button {
            phase = .idle
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
        .disabled(phase == .checking)
    }

    private var doneButton: some View {
        Button(action: done) {
            HStack(spacing: 7) {
                if phase == .checking { ProgressView().controlSize(.mini) }
                Text(phase == .checking ? "Checking…" : "Done")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(Theme.Ink.bright)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Capsule().fill(.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(phase == .checking)
    }

    private var closeButton: some View {
        CloseHoverButton { dismiss() }
    }

    // MARK: - The status line (instruction → amber retry → success)

    private var statusLine: some View {
        Group {
            switch phase {
            case .connected:
                Label(service.connectedLine, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Ink.green)
            case .failed:
                Text(service.failedLine).foregroundStyle(Theme.Ink.amber)
            default:
                Text("Linked it on the page? Press Done and I'll check.")
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Reading is an opt-in independent of the detected provider connection.
    private var stopLink: some View {
        Button(service.stopLine) { selected = false; dismiss() }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.Ink.deepMuted)
    }

    // MARK: - Done: verify, persist, and briefly show success

    private func done() {
        if phase == .connected { dismiss(); return }
        phase = .checking
        let backend = ModelBackend.current
        let wasConnected = connected
        operation = Task {
            let ok = await service.probe()
            guard !Task.isCancelled, ModelBackend.current == backend else { return }
            await MainActor.run {
                if ok {
                    if !wasConnected { Analytics.signal("Source.connected", parameters: ["source": service.analyticsName]) }
                    selected = true                     // include in INITIAL / ITERATIVE runs
                    phase = .connected
                } else {
                    phase = .failed
                }
            }
            if ok {
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled, ModelBackend.current == backend else { return }
                await MainActor.run { dismiss() }
            }
        }
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
