//
//  ProactivePane.swift
//  Sentient OS macOS
//
//  Settings → Proactive & Sidekick: the user's standing instructions for the proactive
//  suggestion writer, Sidekick's shortcut key + standing context, and the speed-vs-intelligence
//  slider (ComputerUseSpeed — how hard gpt-5.6-sol thinks on EVERY computer-use run). The strings
//  persist and autosave. The hotkey choice (right ⌘ / right ⌥) is LIVE — toggling it posts
//  `.sidekickHotkeyChanged`, which re-keys the running SidekickHotkeyMonitor with no restart. The
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

    var body: some View {
        SettingsPane(title: "Proactive & Sidekick",
                     whisper: "Morning suggestions, and the hold-to-talk magic in your notch.") {
            VStack(alignment: .leading, spacing: 30) {
                SettingsGroup(label: "Proactive Intelligence") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsProse("Every morning, Sentient surfaces a few things worth doing, already done and waiting for your go. Tell it what you care about, and what to skip.")
                        SettingsProse("The language of morning cards is set in Settings → System → Response language — it is applied automatically and is not edited here.")
                        SettingsTextBox(placeholder: "e.g. Don't give me suggestions about Chase Bank alerts.",
                                        text: $proactiveInstructions)
                    }
                }
                SettingsHairline(opacity: 0.12)
                    .padding(.vertical, -7)   // sit tighter than the pane's 30pt group rhythm
                SettingsGroup(label: "Sidekick") {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsProse("Hold the shortcut key and just talk (\u{201C}finish this for me\u{201D}), and Sidekick acts on whatever you're looking at.")
                        ChipFlow {
                            SettingsChip(label: "Right ⌘", on: sidekickHotkey == "rightCommand") {
                                sidekickHotkey = "rightCommand"
                            }
                            SettingsChip(label: "Right ⌥", on: sidekickHotkey == "rightOption") {
                                sidekickHotkey = "rightOption"
                            }
                        }
                        .onChange(of: sidekickHotkey) {
                            // Re-key the live monitor immediately — no restart.
                            NotificationCenter.default.post(name: .sidekickHotkeyChanged, object: nil)
                        }
                        SettingsTextBox(placeholder: "e.g. When I say text someone, use WhatsApp. My main browser is Microsoft Edge.",
                                        text: $sidekickContext)
                    }
                }
                SettingsGroup(label: "Speed vs Intelligence") {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsProse("How hard your AI thinks when acting on your Mac: Sidekick, the command bar, and firing a card. Faster is right for most tasks; Smarter takes its time on the tricky ones.")
                        SpeedIntelligenceSlider(selection: Binding(
                            get: { ComputerUseSpeed(rawValue: speedRaw) ?? .faster },
                            set: { speedRaw = $0.rawValue }))
                    }
                }
            }
        }
    }
}

// MARK: - The speed-vs-intelligence slider

/// A compact three-detent slider in the reference's proportions: a THICK pill permanently
/// wearing its own three-stop spectrum (green → cyan → purple) at full strength, the detent
/// dots living inside, and only the white circle moving. Drag or click; the readout underneath
/// names the tier AND the honest spec (GPT-5.6 Sol · how hard it thinks) — live during a drag.
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
                Text(verbatim: hovered.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                MonoCaps(verbatim: hovered.modelLine, size: 8.5, tracking: 1.6, color: Theme.Ink.deepMuted)
            }
            .frame(width: Self.width)
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
