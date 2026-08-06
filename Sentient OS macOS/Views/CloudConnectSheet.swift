//
//  CloudConnectSheet.swift
//  Sentient OS macOS
//
//  The Gmail / Google Calendar connect popup — ONE sheet for both cloud sources (they are exact
//  twins: same OpenAI connector page flow, same codex probe, same storage shape). Flow:
//    Connect …  → opens OpenAI's hosted connector page (the user links Google there).
//    Done       → settles 1s, then the `codex exec` YES/NO probe (a green fill sweeps the button
//                 while it runs — decelerating, ~95% by 17s, snapping full on the answer). YES →
//                 persists connected + selected, shows the green beat, and auto-dismisses. NO → a
//                 quiet amber retry line.
//    ✕ (top-left) → closes without saving.
//  Already connected → a whisper "Stop reading …" link disconnects the source entirely (no
//  in-between state); turning it back on is the full connect flow again, probe included.
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
            [("checkmark.shield", "Sentient enables only the named read tools for this source"),
             ("link", "The account link is managed on OpenAI's page"),
             ("lock", "Other apps, Codex memories, and user MCP servers stay blocked")]
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
        var source: SourceSelection.CloudSource { self == .gmail ? .gmail : .calendar }

        func probe() async -> Bool {
            self == .gmail ? await GmailConnect.probeConnected() : await CalendarConnect.probeConnected()
        }
    }

    private let service: Service
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var connected: Bool
    @AppStorage private var selected: Bool

    private enum Phase { case idle, checking, connected, failed }
    @State private var phase: Phase = .idle
    @State private var checkStart: Date?     // non-nil while the fill sweep runs (and through the green beat)
    @State private var showRemoveConfirmation = false
    @State private var removalError: String?
    @State private var mayContainImportedKnowledge = false
    @State private var lastAccess: Date?

    init(_ service: Service) {
        self.service = service
        _connected = AppStorage(wrappedValue: false, service.connectedKey)
        _selected  = AppStorage(wrappedValue: false, service.selectedKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(service.logoAsset)
                .resizable().scaledToFit()
                .frame(height: 34)

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

            if connected && phase != .checking {
                sourceControls.padding(.top, 2)
            }
        }
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 400)
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { closeButton.padding(12) }
        .animation(.easeOut(duration: 0.2), value: phase)
        .onAppear { if connected && selected { phase = .connected } }   // already linked → Done just closes
        .task { await refreshSourceFacts() }
        .alert("Remove imported knowledge?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove & Rebuild", role: .destructive) { removeAndRebuild() }
        } message: {
            Text("Sentient cannot safely delete individual claims. It will erase the derived knowledge base and rebuild it from your remaining enabled sources. Your account link and setup stay intact.")
        }
    }

    // MARK: - The two buttons (+ the ✕)

    private var connectButton: some View {
        Button { NSWorkspace.shared.open(service.connectorURL) } label: {
            HStack(spacing: 7) {
                Text(connected ? "Manage connection on OpenAI" : service.connectTitle)
                    .font(.system(size: 14, weight: .semibold))
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
            Text(doneLabel)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.Ink.bright)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.07))
                        if let start = checkStart {
                            GeometryReader { geo in
                                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                                    Rectangle()
                                        .fill(Theme.Ink.green.opacity(phase == .connected ? 0.3 : 0.22))
                                        .frame(width: geo.size.width *
                                               (phase == .connected ? 1 : checkFillFraction(since: start, at: ctx.date)))
                                }
                            }
                            .clipShape(Capsule())
                            .transition(.opacity)
                        }
                    }
                }
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(phase == .checking)
    }

    private var doneLabel: String {
        switch phase {
        case .checking: return "Checking…"
        case .connected where checkStart != nil: return "Connected"
        default: return "Done"
        }
    }

    /// The check's fill sweep — deliberately non-linear so it reads as real work, not a timer:
    /// fast out of the gate, decelerating to ~95% at 17s (the observed probe time), then a slow
    /// asymptotic crawl. The probe's answer snaps it full (or clears it on failure).
    private func checkFillFraction(since start: Date, at now: Date) -> CGFloat {
        let t = now.timeIntervalSince(start)
        let sweep = 0.95 * (1 - pow(1 - min(t / 17.0, 1), 2.2))
        let crawl = t > 17 ? 0.04 * (1 - exp(-(t - 17) / 8)) : 0
        return CGFloat(sweep + crawl)
    }

    private var closeButton: some View {
        CloseHoverButton { dismiss() }
    }

    // MARK: - The status line (instruction → amber retry → green beat)

    private var statusLine: some View {
        Group {
            switch phase {
            case .connected:
                Label(service.connectedLine, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Ink.green)
            case .failed:
                Text(service.failedLine).foregroundStyle(Theme.Ink.amber)
            default:
                Text(connected && !selected
                     ? "Linked on OpenAI, but not enabled in Sentient. Press Done to verify and enable it."
                     : "Linked it on the page? Press Done and I'll check.")
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Sentient enablement and derived-knowledge controls. The OpenAI account link is deliberately
    /// independent: stopping local use never claims to revoke that external connection.
    private var sourceControls: some View {
        VStack(spacing: 8) {
            if selected {
                Button("Stop using in Sentient") {
                    Task {
                        await SourceSelection.stopUsing(service.source)
                        selected = false
                        await refreshSourceFacts()
                    }
                }
                .buttonStyle(.plain)
            }
            if mayContainImportedKnowledge {
                Button("Remove imported knowledge and rebuild", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .buttonStyle(.plain)
                .disabled(PipelineActivity.shared.isRunning)
            }
            if let lastAccess {
                Text("Last successful access: \(lastAccess.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(Theme.faint)
            }
            if mayContainImportedKnowledge {
                Text("The current knowledge base may still contain this source until it is rebuilt.")
                    .foregroundStyle(Theme.Ink.amber)
            }
            if let removalError { Text(removalError).foregroundStyle(Theme.Ink.amber) }
        }
        .font(.system(size: 11))
    }

    private func refreshSourceFacts() async {
        let state = await VaultProvenanceStore.shared.state()
        let kind: SourceKind = service.source == .gmail ? .gmail : .calendar
        let accessed = await CodexAccessLedger.shared.lastSuccessfulAccess(to: service.source)
        await MainActor.run {
            mayContainImportedKnowledge = state.mayContain(kind)
            lastAccess = accessed
        }
    }

    private func removeAndRebuild() {
        Task {
            do {
                try await DerivedKnowledgeReset.removeImportedKnowledge(from: service.source)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    removalError = (error as? LocalizedError)?.errorDescription ?? "Removal failed."
                }
            }
        }
    }

    // MARK: - Done: verify, persist, and let the green beat land

    private func done() {
        if phase == .connected { dismiss(); return }
        phase = .checking
        checkStart = Date()
        Task {
            try? await Task.sleep(for: .seconds(1))     // brief settle; the probe's own latency covers the rest
            let ok = await service.probe()
            await MainActor.run {
                if ok {
                    if !connected { Analytics.signal("Source.connected", parameters: ["source": service.analyticsName]) }
                    connected = true
                    selected = true                     // include in INITIAL / ITERATIVE runs
                    phase = .connected
                } else {
                    phase = .failed
                    checkStart = nil          // the fill fades out with the retry line's arrival
                }
            }
            if ok {
                try? await Task.sleep(for: .seconds(1.1))
                await MainActor.run { dismiss() }
            }
        }
    }
}

/// The quiet ✕ — a small glass circle that brightens on hover.
private struct CloseHoverButton: View {
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
