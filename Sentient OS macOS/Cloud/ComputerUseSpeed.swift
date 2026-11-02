//
//  ComputerUseSpeed.swift
//  Sentient OS macOS
//
//  The speed-vs-intelligence dial for EVERY computer-use run — Sidekick, the command bar, and a
//  card's fire all ride the same runAgentCommand spine, so one knob governs them all. Each engine
//  maps the tier to a model and effort: codexModelAndEffort / claudeModelAndEffort.
//  ChatGPT Free/Go runs Luna 6 at low → medium → high effort. Other ChatGPT plans run
//  Terra 6.1 low → Sol 6.1 low → Astra 6 low. Read fresh at fire time, so plan changes and the
//  Settings slider are live with no restart. Default = .faster (low thinking).
//  Producer: ProactivePane's slider · Consumers: CodexCLI.runAgentCommand, ClaudeCLI.agentTuned.
//  Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
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

    /// The plan-aware Codex model and effort, shared by execution and the Settings readout.
    var codexModelAndEffort: (model: CodexCLI.Model, effort: CodexCLI.Effort) {
        if ModelBackend.current == .chatgpt, CodexAuth.usesLuna {
            let effort: CodexCLI.Effort = switch self {
            case .faster: .low
            case .medium: .medium
            case .smarter: .high
            }
            return (.gpt6luna, effort)
        }
        return switch self {
        case .faster: (.gpt61terra, .low)
        case .medium: (.gpt61sol, .low)
        case .smarter: (.gpt6astra, .low)
        }
    }

    /// The Claude-engine pair each tier buys, ordered from fastest to most intelligent.
    var claudeModelAndEffort: (model: ClaudeCLI.Model, effort: CodexCLI.Effort) {
        switch self {
        case .faster: (.sonnet, .low)
        case .medium: (.opus, .low)
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
        case .sentient:
            return "Sentient managed model"
        case .custom:
            // The slider doesn't drive custom models — the pane's reasoning level does, so the
            // readout under the (dimmed) slider tells the truth about what actually runs.
            let name = CustomProvider.current.modelName
            return "\(name.isEmpty ? "Your model" : name) · \(CustomProvider.reasoning) thinking"
        case .claude:
            let (model, effort) = claudeModelAndEffort
            let display = model == .opus ? "Opus 5.5" : "Sonnet 5.5"
            let level = switch effort {
            case .low: "low"
            case .medium: "med"
            default: "high"
            }
            return "Claude \(display) · \(level) thinking"
        case .chatgpt:
            let (model, effort) = codexModelAndEffort
            let name = switch model {
            case .gpt61terra: "GPT-6.1 Terra"
            case .gpt61sol: "GPT-6.1 Sol"
            case .gpt6astra: "GPT-6 Astra"
            case .gpt6luna: "GPT-6 Luna"
            default: model.rawValue
            }
            let thinking = effort == .medium ? "med" : effort.rawValue
            return "\(name) · \(thinking) thinking"
        }
    }
}
