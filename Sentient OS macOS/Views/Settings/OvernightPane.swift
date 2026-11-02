// Overnight timing, wake readiness, and morning suggestions share one settings page.
// Uses the original preference keys; visiting this page never enables scheduling.
import SwiftUI
import AppKit

struct OvernightPane: View {
    @Environment(AppState.self) private var appState
    @AppStorage(OvernightScheduler.minutesKey) private var wakeMinutes = OvernightScheduler.defaultMinutes
    @AppStorage(OvernightScheduler.prodEnabledKey) private var scheduleEnabled = false
    @AppStorage(OvernightScheduler.enabledKey) private var developerScheduleEnabled = false
    @AppStorage(CustomInstructions.proactiveKey) private var proactiveInstructions = ""
    @State private var wakeSetup = OvernightWakeSetup()

    private var overnightRequested: Bool {
        scheduleEnabled || developerScheduleEnabled || appState.processing.hasPendingFirstNight
    }

    @State private var checkedWake = false
    @State private var setupExpansionOverride: Bool?

    private var setupExpanded: Binding<Bool> {
        Binding(
            get: { setupExpansionOverride ?? (checkedWake && (!wakeSetup.ready || appState.scheduler.needsSchedulerSetup)) },
            set: { setupExpansionOverride = $0 })
    }

    var body: some View {
        SettingsPane(title: "Overnight & Suggestions",
                     whisper: "When to learn, and what to prepare for your morning.") {
            VStack(alignment: .leading, spacing: 22) {
                scheduleCard
                suggestionsCard
            }
        }
        .environment(\.settingsCompactLayout, true)
        .task { await refreshWakeStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshWakeStatus() }
        }
        .onChange(of: wakeSetup.ready) { _, ready in
            if ready && overnightRequested { appState.scheduler.reevaluate() }
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Overnight analysis", isOn: Binding(
                get: { overnightRequested },
                set: { appState.scheduler.setEnabled($0) }))
                .font(.system(size: 17, weight: .medium))
                .toggleStyle(.switch)
                .tint(Theme.Ink.green)
                .accessibilityIdentifier("settings.overnightEnabled")
            Text(scheduleStatus)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.overnightStatus")
            SettingsHairline(opacity: 0.07)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Overnight time")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.Ink.statusInk)
                    Text("Each night, in your Mac’s local time.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.body)
                }
                Spacer(minLength: 0)
                DatePicker("Overnight time", selection: wakeTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                    .accessibilityIdentifier("settings.overnightWakeTime")
            }
            DisclosureGroup(isExpanded: setupExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    OvernightWakeRow(setup: wakeSetup)
                    SettingsProse("Leave Sentient open in the menu bar and your Mac plugged in. With wake setup complete, your first analysis and overnight runs can continue with the lid closed. Pause or resume anytime in Analysis.")
                    Button("Manage launch at login") {
                        MainNavigation.shared.show(.settings, settingsPane: .health)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.bright)
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            } label: {
                Text(overnightRequested && checkedWake && !wakeSetup.ready ? "Finish wake setup" : "Setup & requirements")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(overnightRequested && checkedWake && !wakeSetup.ready ? Theme.Ink.amber : Theme.Ink.body)
            }
            .tint(Theme.Ink.body)
        }
        .padding(24)
        .background(Color.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(SettingsStyle.border, lineWidth: 1))
    }

    private var scheduleStatus: String {
        if !overnightRequested { return "Turn on to keep your knowledge up to date overnight." }
        if appState.processing.paused { return "Analysis is paused. Resume it in Analysis to schedule the next wake." }
        if !appState.hasCompletedPersonalSetup { return "Finish personal setup to start overnight analysis." }
        if let next = appState.scheduler.nextWakeAt {
            return "Next wake · \(ProcessingCoordinator.scheduleLabel(next))"
        }
        return appState.scheduler.statusLine
    }

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Morning suggestions")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.Ink.statusInk)
                Text("What should Sentient focus on or skip?")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.body)
            }
            SettingsTextBox(placeholder: "Focus on work follow-ups. Skip shopping and bank alerts.", text: $proactiveInstructions)
                .frame(height: 92)
                .accessibilityLabel("Morning suggestion instructions")
            HStack {
                Text("Saved automatically")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Ink.label)
                Spacer()
            }
            SettingsHairline(opacity: 0.07)
            NotificationPermissionSetting()
        }
        .padding(24)
        .background(Color.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(SettingsStyle.border, lineWidth: 1))
    }

    private func refreshWakeStatus() async {
        // Check readiness even when analysis is off, without enabling the scheduler.
        await wakeSetup.refresh()
        checkedWake = true
    }

    private var wakeTime: Binding<Date> {
        Binding(get: {
            let minutes = OvernightScheduler.validatedMinutes(wakeMinutes)
            // A fixed date keeps the time-only editor independent of today's DST transition.
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15,
                hour: minutes / 60, minute: minutes % 60)) ?? Date()
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minutes = (components.hour ?? 3) * 60 + (components.minute ?? 0)
            guard minutes != wakeMinutes else { return }
            wakeMinutes = minutes
            appState.scheduler.commit()
        })
    }

}
