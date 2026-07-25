//
//  ComputerUseSpeed.swift
//  Sentient OS macOS
//
//  The speed-vs-intelligence dial for EVERY computer-use run — Sidekick, the command bar, and a
//  card's fire all ride the same runAgentCommand spine, so one knob governs them all. The model
//  never changes (gpt-5.6-sol); the tier only picks how hard it thinks. Read fresh at fire time,
//  so the Settings slider is live with no restart. Default = .faster (low thinking — the shipped
//  behavior before the slider existed).
//  Producer: ProactivePane's slider · Consumer: CodexCLI.runAgentCommand.
//

import Foundation

enum ComputerUseSpeed: String, CaseIterable, Sendable {
    case faster, medium, smarter

    /// The UserDefaults key the Settings slider writes.
    static let key = "sidekick.speed"

    /// The live setting.
    static var current: ComputerUseSpeed {
        ComputerUseSpeed(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .faster
    }

    /// The codex reasoning effort each tier buys on gpt-5.6-sol.
    var effort: CodexCLI.Effort {
        switch self {
        case .faster: .low
        case .medium: .medium
        case .smarter: .high
        }
    }

    /// The tier's display name (the slider's readout).
    var label: String {
        switch self {
        case .faster: "Faster"
        case .medium: "Medium"
        case .smarter: "Smarter"
        }
    }

    /// The honest spec line under the slider — the model named out loud. ("med", not the
    /// effort's raw "medium" — the whisper reads tighter.) On a custom frontier model the
    /// user's own model is the one doing the thinking, so it gets the credit.
    var modelLine: String {
        let thinking = switch self {
        case .faster: "low"
        case .medium: "med"
        case .smarter: "high"
        }
        if ModelBackend.current == .custom {
            // The slider doesn't drive custom models — the pane's reasoning level does, so the
            // readout under the (dimmed) slider tells the truth about what actually runs.
            let name = CustomProvider.current.modelName
            return "\(name.isEmpty ? "Your model" : name) · \(CustomProvider.reasoning) thinking"
        }
        return "GPT-5.6 Sol · \(thinking) thinking"
    }
}
