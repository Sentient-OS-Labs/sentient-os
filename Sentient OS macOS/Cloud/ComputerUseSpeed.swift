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

    /// The Claude-engine pair each tier buys (decision 2026-08-21): the slider picks BOTH the
    /// model and how hard it thinks — sonnet·low / sonnet·high / opus·high. (ClaudeCLI applies
    /// the Pro-plan opus → sonnet downshift on top.)
    var claudeModelAndEffort: (model: ClaudeCLI.Model, effort: CodexCLI.Effort) {
        switch self {
        case .faster: (.sonnet, .low)
        case .medium: (.sonnet, .high)
        case .smarter: (.opus, .high)
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
        switch ModelBackend.current {
        case .custom:
            // The slider doesn't drive custom models — the pane's reasoning level does, so the
            // readout under the (dimmed) slider tells the truth about what actually runs.
            let name = CustomProvider.current.modelName
            return "\(name.isEmpty ? "Your model" : name) · \(CustomProvider.reasoning) thinking"
        case .claude:
            let (model, effort) = claudeModelAndEffort
            let name = (model == .opus && ClaudeAuth.isPro) ? ClaudeCLI.Model.sonnet : model
            let display = name == .opus ? "Opus" : "Sonnet"
            let level = effort == .low ? "low" : "high"
            return "Claude \(display) · \(level) thinking"
        case .chatgpt:
            return "GPT-5.6 Sol · \(thinking) thinking"
        }
    }
}
