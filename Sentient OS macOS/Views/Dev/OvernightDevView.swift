//
//  OvernightDevView.swift
//  Sentient OS macOS  ·  Views/
//
//  The dev cockpit for overnight processing, in its OWN window (opened from DEV TOOLS → "Overnight
//  Processing…"). A simple top-to-bottom checklist to set up + test the 3am self-processing:
//    ① approve the root wake helper  ② launch-at-login  ③ test the 18h auto-enable  ④ manual arm.
//  A live status panel at the top mirrors reality (helper approval + login item are polled every 2s,
//  so approving in System Settings updates here without a manual refresh). Dev-only; the shipping
//  onboarding/Settings UX binds to the same seams (WakeHelperClient / LoginItem / OvernightScheduler).
//

import SwiftUI
import ServiceManagement
import Combine

struct OvernightDevView: View {
    static let windowID = "overnight-dev"

    @Environment(AppState.self) private var appState
    @AppStorage(OvernightScheduler.enabledKey) private var schedEnabled = false
    @AppStorage(OvernightScheduler.minutesKey) private var schedMinutes = OvernightScheduler.defaultMinutes
    @AppStorage(OvernightScheduler.autoEnableDelayKey) private var delayOverride: Double = 0

    @State private var helperStatus: SMAppService.Status = .notRegistered
    @State private var loginOn = false

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Overnight Processing").font(.system(.largeTitle, design: .serif).weight(.semibold))
                Text("Set up and test the 3am self-processing. Work top to bottom.")
                    .font(.callout).foregroundStyle(.secondary)

                statusPanel
                helperStep
                loginStep
                autoEnableStep
                manualStep
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 720)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    // MARK: - Live status panel

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("STATUS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
            statusRow("Root helper", Self.helperText(helperStatus), Self.helperColor(helperStatus))
            statusRow("Launch at login", loginOn ? "on" : "off", loginOn ? Theme.Ink.green : .secondary)
            statusRow("Scheduler", schedulerOn ? appState.scheduler.statusLine : "off", schedulerOn ? Theme.Ink.green : .secondary)
            statusRow("Auto-enable", autoEnableShort, appState.scheduler.needsSchedulerSetup ? .orange : .secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value).font(.subheadline.monospaced()).foregroundStyle(color)
        }
    }

    // MARK: - ① Approve the root helper

    private var helperStep: some View {
        stepCard("1", "Approve the root helper",
                 "Lets the app wake your Mac at 3am. Click Approve, then flip “Sentient OS” ON in the System Settings window that opens. (Works on any signed build — no notarization needed.)") {
            HStack(spacing: 10) {
                Button {
                    let s = WakeHelperClient.shared.register()
                    if s != .enabled { WakeHelperClient.shared.openLoginItemsSettings() }   // jump to approve
                    refresh()
                } label: {
                    Label(helperStatus == .enabled ? "Re-register helper" : "Approve helper", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                Button("Open System Settings") { WakeHelperClient.shared.openLoginItemsSettings() }
                if helperStatus == .enabled {
                    Label("approved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Ink.green).font(.caption)
                }
            }
        }
    }

    // MARK: - ② Launch at login

    private var loginStep: some View {
        stepCard("2", "Launch at login",
                 "The app must be open at 3am to run. This starts Sentient OS automatically when you log in.") {
            Toggle("Start Sentient OS at login", isOn: $loginOn)
                .toggleStyle(.switch)
                .onChange(of: loginOn) { _, on in
                    if on { LoginItem.enable() } else { Task { await LoginItem.disable() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
                }
        }
    }

    // MARK: - ③ Test the 18h auto-enable

    private var autoEnableStep: some View {
        stepCard("3", "Test the 18h auto-enable",
                 "Normally the scheduler turns itself on 18h after your first full analyze — but only once steps 1 & 2 are done. Shorten the wait here to test it in seconds.") {
            VStack(alignment: .leading, spacing: 12) {
                Text(autoEnableSummary).font(.callout).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("Wait:").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $delayOverride) {
                        Text("18h (real)").tag(0.0)
                        Text("10s").tag(10.0)
                        Text("60s").tag(60.0)
                    }.pickerStyle(.segmented).frame(width: 240).labelsHidden()
                }

                HStack(spacing: 8) {
                    Button("Simulate first analyze done") {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: OvernightScheduler.firstCycleAtKey)
                        appState.scheduler.maybeAutoEnable(); refresh()
                    }
                    Button("Run check now") { appState.scheduler.maybeAutoEnable(); refresh() }
                    Button("Reset", role: .destructive) { resetAutoEnable() }
                }
            }
        }
    }

    // MARK: - ④ Manual arm (bypass the 18h logic)

    private var manualStep: some View {
        stepCard("4", "Manual arm (bypass)",
                 "Directly arm a wake at a set time, ignoring the 18h logic — the fastest end-to-end test.") {
            HStack(spacing: 12) {
                Toggle("On", isOn: $schedEnabled).toggleStyle(.switch)
                    .onChange(of: schedEnabled) { _, _ in appState.scheduler.reevaluate() }
                DatePicker("at", selection: schedTimeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden().disabled(!schedEnabled)
                Button("Arm") { appState.scheduler.commit() }.disabled(!schedEnabled)
                Spacer()
                Text(schedEnabled ? appState.scheduler.statusLine : "off")
                    .font(.caption.monospaced()).foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: - Reusable step card

    @ViewBuilder
    private func stepCard(_ n: String, _ title: String, _ help: String,
                          @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text(n).font(.caption.bold()).foregroundStyle(.black)
                    .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.85)))
                Text(title).font(.headline)
            }
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content().padding(.top, 2)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }

    // MARK: - Logic

    private var schedulerOn: Bool {
        schedEnabled || UserDefaults.standard.bool(forKey: OvernightScheduler.prodEnabledKey)
    }

    private func refresh() {
        helperStatus = WakeHelperClient.shared.status
        loginOn = LoginItem.isEnabled
    }

    private func resetAutoEnable() {
        let d = UserDefaults.standard
        [OvernightScheduler.firstCycleAtKey, OvernightScheduler.autoEnableFiredKey, OvernightScheduler.prodEnabledKey]
            .forEach { d.removeObject(forKey: $0) }
        appState.scheduler.needsSchedulerSetup = false
        appState.scheduler.reevaluate()
        refresh()
    }

    private var autoEnableSummary: String {
        let d = UserDefaults.standard
        guard OvernightScheduler.firstCycleCompletedAt != nil, let fire = OvernightScheduler.autoEnableFireDate else {
            return "First analyze not done yet — the clock hasn't started. Use “Simulate first analyze done” to start it."
        }
        if d.bool(forKey: OvernightScheduler.autoEnableFiredKey) { return "✓ Already auto-enabled." }
        if appState.scheduler.needsSchedulerSetup {
            return "⚠️ Ready, but needs setup — finish steps 1 & 2, then “Run check now”."
        }
        if Date() >= fire { return "Delay elapsed — click “Run check now”." }
        return "Will auto-enable at \(Self.stamp(fire)) — in \(Int(fire.timeIntervalSinceNow))s."
    }

    private var autoEnableShort: String {
        if UserDefaults.standard.bool(forKey: OvernightScheduler.autoEnableFiredKey) { return "enabled ✓" }
        if appState.scheduler.needsSchedulerSetup { return "needs setup" }
        guard let fire = OvernightScheduler.autoEnableFireDate else { return "clock not started" }
        return Date() >= fire ? "ready — run check" : "fires \(Self.stamp(fire))"
    }

    /// Bridges the stored minutes-since-midnight to/from the DatePicker's Date.
    private var schedTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                c.hour = schedMinutes / 60; c.minute = schedMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                schedMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    private static func helperText(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled:          return "enabled ✓"
        case .requiresApproval: return "needs approval"
        case .notRegistered:    return "not registered"
        case .notFound:         return "not found (unsigned)"
        @unknown default:       return "unknown"
        }
    }
    private static func helperColor(_ s: SMAppService.Status) -> Color {
        switch s {
        case .enabled:          return Theme.Ink.green
        case .requiresApproval: return .orange
        default:                return .red
        }
    }
    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f.string(from: d)
    }
}
