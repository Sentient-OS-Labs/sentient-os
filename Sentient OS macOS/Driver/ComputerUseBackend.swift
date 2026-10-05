// Chooses the computer-use runtime independently of the CLI harness.
// All active engines use OpenAI's native helper. CUA remains an identity for legacy cleanup.
// Doc: Documentation - Native Computer Use.md

import Foundation

nonisolated enum ComputerUseBackend: String, CaseIterable, Sendable {
    case openAI, cua

    static func selected(for model: ModelBackend) -> Self {
        .openAI
    }

    static var current: Self { selected(for: ModelBackend.current) }

    var isInstalled: Bool {
        switch self {
        case .openAI: OpenAIComputerUse.isInstalled
        case .cua: CuaDriver.isInstalled
        }
    }

    var name: String { self == .openAI ? "OpenAI computer use" : "CUA driver" }

    var promptRules: String {
        switch self {
        case .openAI: OpenAIComputerUse.promptRules
        case .cua: CuaDriverSkill.rules
        }
    }
}
