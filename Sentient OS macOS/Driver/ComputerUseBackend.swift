// Chooses the computer-use runtime independently of the CLI harness.
// ChatGPT uses OpenAI's native helper; Claude and custom endpoints keep the CUA driver.
// Doc: Driver/Documentation - Driver (cua-driver).md

import Foundation

nonisolated enum ComputerUseBackend: String, CaseIterable, Sendable {
    case openAI, cua

    static func selected(for model: ModelBackend) -> Self {
        model == .chatgpt ? .openAI : .cua
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
