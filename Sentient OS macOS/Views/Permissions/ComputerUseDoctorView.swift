import AppKit
import SwiftUI

struct ComputerUseDoctorView: View {
    @Bindable var doctor: ComputerUseDoctor
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                SidekickMark(size: 28, illuminated: true)
                Text("SENTIENT CHECKUP").font(.system(size: 11, weight: .semibold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(doctor.report?.title ?? "Computer-use check").font(.system(size: 25, weight: .semibold))
                Text(doctor.report?.explanation ?? "Test the tools Sidekick uses across your computer.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(doctor.report?.steps ?? []) { step in
                        HStack(spacing: 12) {
                            if step.status == .running { ProgressView().controlSize(.small).frame(width: 16) }
                            else { Image(systemName: symbol(step.status)).frame(width: 16).foregroundStyle(color(step.status)) }
                            Text(step.check.title).font(.system(size: 13))
                            Spacer()
                            Text(label(step.status)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                        }.padding(.vertical, 11)
                    }
                }.padding(.horizontal, 16)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
            }
            if let controls = doctor.controls {
                TestControlsHost(controls: controls).frame(height: 100)
                    .padding(.horizontal, 10)
                    .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("computerUse.checkControls")
            }
            if doctor.report?.outcome == .permissionsNeeded {
                HStack(spacing: 8) {
                    SettingsPillButton(title: "Screen Recording") { Permissions.openScreenRecordingSettings() }
                    SettingsPillButton(title: "Accessibility") { Permissions.openAccessibilitySettings() }
                    SettingsPillButton(title: "Automation") {
                        if doctor.report?.permissions["automation"] == "notAsked" { ComputerUseGate.shared.requestAutomation() }
                        else { Permissions.openAutomationSettings() }
                    }
                }
                Text("In Automation, expand Sentient OS and allow ChatGPT/Codex Computer Use.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            HStack {
                if doctor.isRunning {
                    Text("Only this test window is used.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    SettingsPillButton(title: "Cancel check") { doctor.cancel() }
                } else {
                    SettingsPillButton(title: "Review report…") { reviewing = true }
                    Spacer()
                    SettingsPillButton(title: "Check again") { doctor.start() }.disabled(doctor.uploading)
                }
            }
        }
        .padding(28).frame(width: 540, height: 620)
        .background(Color(white: 0.025)).foregroundStyle(.white)
        .sheet(isPresented: $reviewing) { reportPreview }
    }

    private var reportPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review your diagnostic report").font(.system(size: 21, weight: .semibold))
            Text("Includes versions, permission status, test results and recent technical error categories and codes. Tool errors may have recovered during the task. No screenshots, messages, account details or document contents. Sending shares this report with the Sentient team, stored in Supabase.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView([.vertical, .horizontal]) {
                Text(doctor.report.flatMap { try? $0.encoded() }.map { String(decoding: $0, as: UTF8.self) } ?? "Report unavailable")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if let message = doctor.uploadMessage { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("Done") { reviewing = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save a copy…") { doctor.saveReport() }
                Button(doctor.uploading ? "Sending…" : "Send report") { doctor.sendReport() }
                    .buttonStyle(.borderedProminent).tint(.blue).disabled(doctor.uploading || doctor.report == nil)
            }
        }.padding(26).frame(width: 580, height: 580).preferredColorScheme(.dark)
    }
    private func symbol(_ state: ComputerUseCheckReport.Status) -> String {
        switch state {
        case .passed: "checkmark"
        case .needsAttention: "circle.dotted"
        case .interrupted: "arrow.clockwise"
        default: "minus"
        }
    }
    private func color(_ state: ComputerUseCheckReport.Status) -> Color { state == .passed ? .green.opacity(0.8) : .white.opacity(0.55) }
    private func label(_ state: ComputerUseCheckReport.Status) -> String {
        switch state {
        case .running: "Checking"
        case .passed: "Passed"
        case .needsAttention: "Needs a look"
        case .interrupted: "Interrupted"
        case .skipped: "Not tested"
        }
    }
}

private struct TestControlsHost: NSViewRepresentable {
    let controls: ComputerUseTestControls
    func makeNSView(context: Context) -> NSView { controls.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ComputerUseCheckRow: View {
    @State private var doctor = ComputerUseDoctor.shared
    var body: some View {
        SettingsGroup(label: "A real check") {
            SettingsRow(title: "Test & repair computer use", subtitle: note) {
                SettingsPillButton(title: doctor.isRunning ? "View check" : "Test & repair…") {
                    if doctor.isRunning { doctor.show() } else { doctor.start() }
                }
            }
        }
    }
    private var note: String {
        guard let report = doctor.report, let ended = report.finishedAt,
              report.environment.binaryID == BuildIdentity.identifier else {
            return "Test reading, screenshots, clicks and text entry in a small Sentient window."
        }
        if report.outcome == .passed || report.outcome == .repaired {
            return "Last check passed " + ended.formatted(date: .abbreviated, time: .shortened) + ". Permissions are checked separately."
        }
        return report.explanation
    }
}
