// Central settings for notch activation, appearance, and the shared keyboard gesture.
import SwiftUI

struct NotchShortcutsPane: View {
    @AppStorage(NotchPreferences.clickEnabledKey) private var notchClickEnabled = true
    @AppStorage(NotchPreferences.externalBarEnabledKey) private var externalBarEnabled = true
    @AppStorage(NotchPreferences.compactModeKey) private var compactNotchMode = false
    @AppStorage(NotchPreferences.physicalTapEnabledKey) private var physicalTapEnabled = true
    @AppStorage(NotchPreferences.secondPhysicalTapKey) private var secondPhysicalTap = PhysicalTapAction.close.rawValue
    @AppStorage(NotchPreferences.physicalTapSensitivityKey) private var tapSensitivity = "standard"
    @AppStorage(NotchPreferences.physicalTapCalibrationKey) private var calibrationData = Data()
    @State private var physicalTap = PhysicalNotchTap.shared

    var body: some View {
        SettingsPane(title: "Notch & Shortcuts", whisper: "Choose how you open Sentient, speak, and draft replies.") {
            VStack(alignment: .leading, spacing: 32) {
                SettingsGroup(label: "Touch your notch!", inset: 0) {
                    VStack(spacing: 0) {
                        SettingToggleLine(title: "Open quick access with a physical tap",
                            sub: "Tap the light-sensor area of the notch, then lift your finger. Tap again to close it or run your chosen action.",
                            isOn: $physicalTapEnabled)
                            .disabled(physicalTap.isCalibrating)
                            .accessibilityIdentifier("settings.physicalTapEnabled")
                        NotchCalibrationIllustration()
                            .frame(height: 152)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Tap the glowing sensor region just left of the camera in your MacBook’s notch")
                            .accessibilityIdentifier("settings.physicalTapDiagram")
                        SettingsHairline(opacity: 0.10)
                        SettingsRow(title: "Second tap", subtitle: "When Sidekick’s input is open.") {
                            SettingsMenu(title: "Second physical tap",
                                value: (PhysicalTapAction(rawValue: secondPhysicalTap) ?? .close).label,
                                selection: $secondPhysicalTap) {
                                ForEach(PhysicalTapAction.allCases, id: \.rawValue) { action in
                                    Text(action.label).tag(action.rawValue)
                                }
                            }
                            .frame(width: 170).disabled(!physicalTapEnabled)
                            .accessibilityIdentifier("settings.secondPhysicalTap")
                        }
                        SettingsHairline(opacity: 0.10)
                        SettingsRow(title: "Tap sensitivity", subtitle: "Standard uses our default touch tuning. Gentle accepts lighter taps.") {
                            SettingsMenu(title: "Physical tap sensitivity",
                                value: tapSensitivity == "gentle" ? "Gentle" : tapSensitivity == "firm" ? "Firm" : "Standard",
                                selection: $tapSensitivity) {
                                ForEach(["gentle", "standard", "firm"], id: \.self) { sensitivity in
                                    Text(sensitivity.capitalized).tag(sensitivity)
                                }
                            }
                            .frame(width: 170).disabled(!physicalTapEnabled)
                            .accessibilityIdentifier("settings.physicalTapSensitivity")
                        }
                        SettingsHairline(opacity: 0.10)
                        SettingsRow(title: "Calibrate your touch",
                            subtitle: calibration == nil ? "Optional. Fine-tune the default touch detection for your lighting and laptop position." : "Personal tuning saved. You can recalibrate or choose any sensitivity above.") {
                            SettingsPillButton(title: calibration == nil ? "Calibrate…" : "Recalibrate…") {
                                NotchTouchCalibration.shared.show()
                            }
                            .accessibilityIdentifier("settings.calibrateNotchTouch")
                        }
                        SettingsHairline(opacity: 0.10)
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsProse(physicalTap.statusText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }
                SettingsGroup(label: "Keyboard shortcut", inset: 0) {
                    ShortcutSetting()
                }
                SettingsGroup(label: "Notch controls", inset: 0) {
                    VStack(spacing: 0) {
                        SettingToggleLine(title: "Open quick access by mouse clicking the notch",
                            sub: "Turn off to leave notch clicks to other apps. You can still open Sidekick with your shortcut key.",
                            isOn: $notchClickEnabled)
                            .accessibilityIdentifier("settings.notchClickEnabled")
                        SettingsHairline(opacity: 0.10)
                        SettingToggleLine(title: "Show quick-access bar on external displays",
                            sub: "Turn off to open quick access with your shortcut key on external displays.",
                            isOn: $externalBarEnabled)
                            .accessibilityIdentifier("settings.externalBarEnabled")
                        SettingsHairline(opacity: 0.10)
                        SettingToggleLine(title: "Compact notch mode",
                            sub: "Keep the app icon and short status beside the camera while Sidekick works.",
                            isOn: $compactNotchMode)
                            .accessibilityIdentifier("settings.compactNotchMode")
                    }
                }
            }
        }
        .onChange(of: notchClickEnabled) { _, _ in
            NotificationCenter.default.post(name: .notchInteractionChanged, object: nil)
        }
        .onChange(of: externalBarEnabled) { _, _ in
            NotificationCenter.default.post(name: .notchInteractionChanged, object: nil)
        }
        .onChange(of: compactNotchMode) { _, _ in
            NotificationCenter.default.post(name: .notchAppearanceChanged, object: nil)
        }
        .onChange(of: physicalTapEnabled) { _, _ in physicalTapPreferencesChanged() }
        .onChange(of: secondPhysicalTap) { _, _ in physicalTapPreferencesChanged() }
        .onChange(of: tapSensitivity) { _, _ in physicalTapPreferencesChanged() }
    }

    private var calibration: PhysicalTapCalibrationProfile? {
        guard let profile = try? JSONDecoder().decode(PhysicalTapCalibrationProfile.self, from: calibrationData),
              profile.isValid else { return nil }
        return profile
    }

    private func physicalTapPreferencesChanged() {
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
    }
}
