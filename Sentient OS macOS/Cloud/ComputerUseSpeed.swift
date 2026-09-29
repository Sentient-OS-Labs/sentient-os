//
//  ComputerUseSpeed.swift
//  Sentient OS macOS
//
//  The speed-vs-intelligence dial for EVERY computer-use run — Sidekick, the command bar, and a
//  card's fire all ride the same runAgentCommand spine, so one knob governs them all. Each engine
//  maps the tier to a model and effort: codexModelAndEffort / claudeModelAndEffort.
//  Codex runs Sol low → Astra low → Astra medium. Read fresh at fire time, so the
//  Settings slider is live with no restart. Default = .faster (low thinking — the shipped behavior
//  before the slider existed).
//  Producer: ProactivePane's slider · Consumers: CodexCLI.runAgentCommand, ClaudeCLI.agentTuned.
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

    /// The Codex model and effort, ordered from fastest to most intelligent.
    var codexModelAndEffort: (model: CodexCLI.Model, effort: CodexCLI.Effort) {
        switch self {
        case .faster: (.gpt6sol, .low)
        case .medium: (.gpt6astra, .low)
        case .smarter: (.gpt6astra, .medium)
        }
    }

    /// The Claude-engine pair each tier buys (decision 2026-08-23): the slider picks BOTH the
    /// model and how hard it thinks — sonnet·low / sonnet·medium / opus·medium, fastest to most
    /// intelligent. (ClaudeCLI applies the Pro-plan opus → sonnet downshift on top.)
    var claudeModelAndEffort: (model: ClaudeCLI.Model, effort: CodexCLI.Effort) {
        switch self {
        case .faster: (.sonnet, .low)
        case .medium: (.sonnet, .medium)
        case .smarter: (.opus, .medium)
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
        switch ModelBackend.current {
        case .custom:
            // The slider doesn't drive custom models — the pane's reasoning level does, so the
            // readout under the (dimmed) slider tells the truth about what actually runs.
            let name = CustomProvider.current.modelName
            return "\(name.isEmpty ? "Your model" : name) · \(CustomProvider.reasoning) thinking"
        case .claude:
            let (model, effort) = claudeModelAndEffort
            let name = (model == .opus && ClaudeAuth.isPro) ? ClaudeCLI.Model.sonnet : model
            let display = name == .opus ? "Opus 5.5" : "Sonnet"
            let level = switch effort {
            case .low: "low"
            case .medium: "med"
            default: "high"
            }
            return "Claude \(display) · \(level) thinking"
        case .chatgpt:
            let (model, effort) = codexModelAndEffort
            let name = model == .gpt6astra ? "GPT-6 Astra" : "GPT-6 Sol"
            let thinking = effort == .medium ? "med" : effort.rawValue
            return "\(name) · \(thinking) thinking"
        }
    }
}
