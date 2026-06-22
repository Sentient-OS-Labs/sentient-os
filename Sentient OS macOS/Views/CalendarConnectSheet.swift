//
//  CalendarConnectSheet.swift
//  Sentient OS macOS
//
//  The Google Calendar connection popup (dev) — twin to GmailConnectSheet. Flow:
//    Connect Calendar → opens OpenAI's hosted Google Calendar connector page (user links Google there).
//    I'm done         → spins, waits 3s for the connection to settle, then a `codex exec` YES/NO probe
//                       (CalendarConnect.probeConnected). YES → "Finish" lights up; NO → reconnect.
//    Finish           → persists the connected flag + selects Calendar for INITIAL / ITERATIVE runs.
//
//  See CalendarConnect for the codex side.
//

import SwiftUI
import AppKit

struct CalendarConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dbg.calendar.connected") private var connected = false
    @AppStorage("dbg.run.calendar")       private var selected = false

    private enum Phase { case idle, checking, connected, failed }
    @State private var phase: Phase = .idle

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 30)).foregroundStyle(Theme.accent)
                Text("Connect Google Calendar").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("Link your Google account on OpenAI's connector page. Your Codex reads your calendar through it — Sentient never sees your password.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button { NSWorkspace.shared.open(CalendarConnect.connectorURL) } label: {
                    Label("Connect Calendar", systemImage: "arrow.up.forward.app")
                        .font(.callout.weight(.medium)).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)

                Button { checkDone() } label: {
                    HStack(spacing: 7) {
                        if phase == .checking { ProgressView().controlSize(.small) }
                        Text(phase == .checking ? "Checking…" : "I'm done")
                    }
                    .font(.callout.weight(.medium)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(phase == .checking)

                Group {
                    switch phase {
                    case .failed:
                        Text("Couldn't see your calendar yet. Finish connecting on the page, then tap “I'm done” again.")
                            .foregroundStyle(.orange)
                    case .connected:
                        Label("Calendar connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    default:
                        Text("After connecting on the page, come back and tap “I'm done”.")
                            .foregroundStyle(Theme.faint)
                    }
                }
                .font(.caption2.weight(.medium))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                    Button(selected ? "Done" : "Finish") {
                        connected = true
                        selected = true            // include Calendar in INITIAL / ITERATIVE runs
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(phase != .connected)
                }
                if connected && selected {
                    Button("Remove Calendar from runs") { selected = false; dismiss() }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(28).frame(width: 420).background(Theme.bg)
        .onAppear { if connected { phase = .connected } }   // already linked → Finish ready immediately
    }

    /// "I'm done": settle 3s, then the codex YES/NO probe.
    private func checkDone() {
        phase = .checking
        Task {
            try? await Task.sleep(for: .seconds(3))
            let ok = await CalendarConnect.probeConnected()
            await MainActor.run {
                phase = ok ? .connected : .failed
                if ok { connected = true }
            }
        }
    }
}
