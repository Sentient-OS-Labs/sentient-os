//
//  ProactivePane.swift
//  Sentient OS macOS
//
//  Settings → Proactive & Sidekick: the user's standing instructions for the proactive
//  suggestion writer, Sidekick's shortcut key + standing context, and the speed-vs-intelligence
//  slider (ComputerUseSpeed — the model/effort EVERY computer-use run rides, per engine). The strings
//  persist and autosave. The hotkey choice (right ⌘ / right ⌥) is LIVE — toggling it posts
//  `.sidekickHotkeyChanged`, which re-keys the running SidekickHotkeyMonitor with no restart (Double
//  Tap rides the same key, so it follows the choice too). The
//  two text fields are LIVE too: `proactive.instructions` feeds the proactive prompts
//  (Proactive.instructionsBlock, PART 1 + 2) and `sidekick.context` feeds the command/Sidekick
//  prompt (CommandRunModel.commandPrompt) — the two keys live in CustomInstructions so producer
//  and consumers can't drift. The slider is live the same way (read fresh per run).
//

import SwiftUI

struct ProactivePane: View {
    @AppStorage(CustomInstructions.proactiveKey) private var proactiveInstructions = ""
    @AppStorage("sidekick.hotkey") private var sidekickHotkey = "rightCommand"
    @AppStorage(CustomInstructions.sidekickKey) private var sidekickContext = ""
    @AppStorage(ComputerUseSpeed.key) private var speedRaw = ComputerUseSpeed.faster.rawValue
    /// The slider drives the subscription engines (ChatGPT and Claude); a custom frontier model
    /// carries ONE reasoning level set in Frontier Model Choice (provider quirks make per-run
    /// tuning unsafe there), so only .custom locks it.
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue

    private var sliderLive: Bool { (ModelBackend(rawValue: backendRaw) ?? .chatgpt) != .custom }

    var body: some View {
        SettingsPane(title: "Proactive & Sidekick",
                     whisper: "Make everyday help feel like your own.") {
            VStack(alignment: .leading, spacing: 32) {
                SettingsGroup(label: "Sidekick", inset: 0) {
                    VStack(spacing: 0) {
                        SettingsRow(title: "Shortcut key", subtitle: "Tap to open Sidekick. Double tap to draft a reply.") {
                            SettingsMenu(title: "Sidekick shortcut", value: sidekickHotkey == "rightOption" ? "Right ⌥" : "Right ⌘", selection: $sidekickHotkey) {
                                Text("Right ⌘").tag("rightCommand")
                                Text("Right ⌥").tag("rightOption")
                            }
                            .frame(width: 136)
                            .onChange(of: sidekickHotkey) {
                                NotificationCenter.default.post(name: .sidekickHotkeyChanged, object: nil)
                            }
                        }
                        SettingsHairline(opacity: 0.10)
                        VStack(alignment: .leading, spacing: 12) {
                            instructionLabel("Custom instructions", detail: "Sidekick learns your preferences as you work. Edit its instructions anytime.")
                            SettingsTextBox(placeholder: "Use WhatsApp for messages and Safari for browsing.", text: Binding(
                                get: { sidekickContext }, set: { CustomInstructions.saveSidekick($0) }))
                                .frame(height: 104)
                                .accessibilityLabel("Sidekick custom instructions")
                        }
                        .padding(20)
                    }
                }

                SettingsGroup(label: "Speed & intelligence",
                              description: "Choose how much thought goes into computer tasks.") {
                    VStack(alignment: .leading, spacing: 16) {
                        SpeedIntelligenceSlider(selection: Binding(
                            get: { ComputerUseSpeed(rawValue: speedRaw) ?? .faster },
                            set: { speedRaw = $0.rawValue }))
                            .disabled(!sliderLive)
                            .allowsHitTesting(sliderLive)
                            .opacity(sliderLive ? 1 : 0.4)
                        SettingsProse(sliderLive
                            ? "Faster for everyday tasks. Smarter for the tricky ones."
                            : "Your custom model uses the reasoning level set in Frontier Model Choice.")
                    }
                }

                SettingsGroup(label: "Morning suggestions",
                              description: "Tell Sentient what to focus on, and what to skip.") {
                    SettingsTextBox(placeholder: "Focus on work follow-ups. Skip shopping and bank alerts.", text: $proactiveInstructions)
                        .frame(height: 104)
                        .accessibilityLabel("Morning suggestion instructions")
                }
                Text("Instructions and preferences save automatically.")
                    .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
            }
        }
    }

    private func instructionLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            SettingsProse(detail)
        }
    }
}

// MARK: - The speed-vs-intelligence slider

/// A compact three-detent slider in the reference's proportions: a THICK pill permanently
/// wearing its own three-stop spectrum (green → cyan → purple) at full strength, the detent
/// dots living inside, and only the white circle moving. Drag or click; the readout underneath
/// names the tier AND the honest spec (GPT-6 Sol · how hard it thinks) — live during a drag.
private struct SpeedIntelligenceSlider: View {
    @Binding var selection: ComputerUseSpeed

    /// The pointer's live position while dragging (nil = resting on the selection's detent).
    @State private var dragFraction: CGFloat?

    private static let width: CGFloat = 300
    private static let trackHeight: CGFloat = 24
    private static let thumb: CGFloat = 28          // slightly proud of the track, like the reference
    /// The slider's own three-stop spectrum: the app green → cyan → purple.
    private static let spectrum = [Theme.Ink.green,
                                   Color(red: 0.13, green: 0.83, blue: 0.93),
                                   Color(red: 0.66, green: 0.33, blue: 0.97)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            track
                .frame(width: Self.width, height: Self.thumb)
            // One line under the pill: the landed tier under the left edge, the honest
            // model spec under the right — both live during a drag.
            HStack(alignment: .firstTextBaseline) {
                Text(hovered.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(hovered.modelLine)
                    .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
            }
            .frame(width: Self.width)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed and intelligence")
        .accessibilityValue("\(selection.label), \(selection.modelLine)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = Self.tier(nearest: min(Self.fraction(of: selection) + 0.5, 1))
            case .decrement: selection = Self.tier(nearest: max(Self.fraction(of: selection) - 0.5, 0))
            @unknown default: break
            }
        }
    }

    private var fraction: CGFloat { dragFraction ?? Self.fraction(of: selection) }
    /// The tier the thumb is nearest RIGHT NOW — previews in the readout mid-drag.
    private var hovered: ComputerUseSpeed { Self.tier(nearest: fraction) }

    private static func fraction(of tier: ComputerUseSpeed) -> CGFloat {
        switch tier {
        case .faster: 0
        case .medium: 0.5
        case .smarter: 1
        }
    }

    private static func tier(nearest f: CGFloat) -> ComputerUseSpeed {
        f < 0.25 ? .faster : (f < 0.75 ? .medium : .smarter)
    }

    private var track: some View {
        let usable = Self.width - Self.thumb
        let center = fraction * usable + Self.thumb / 2
        let gradient = LinearGradient(colors: Self.spectrum,
                                      startPoint: .leading, endPoint: .trailing)

        return ZStack(alignment: .leading) {
            // The permanent spectrum: the whole gradient always dresses the pill at full
            // strength, its glow breathing underneath.
            gradient
                .frame(width: Self.width, height: Self.trackHeight)
                .clipShape(Capsule())
                .blur(radius: 10)
                .opacity(0.4)
            gradient
                .frame(width: Self.width, height: Self.trackHeight)
                .clipShape(Capsule())

            // The detents, living INSIDE the pill.
            ForEach([CGFloat](arrayLiteral: 0, 0.5, 1), id: \.self) { f in
                Circle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 4, height: 4)
                    .offset(x: f * usable + Self.thumb / 2 - 2)
            }

            // The one moving thing.
            Circle()
                .fill(.white)
                .frame(width: Self.thumb, height: Self.thumb)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .offset(x: center - Self.thumb / 2)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = min(max((g.location.x - Self.thumb / 2) / usable, 0), 1)
                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.85)) {
                        dragFraction = f
                    }
                }
                .onEnded { _ in
                    let landed = hovered
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = landed
                        dragFraction = nil
                    }
                }
        )
    }
}

#Preview("Proactive & Sidekick pane") {
    ProactivePane()
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
