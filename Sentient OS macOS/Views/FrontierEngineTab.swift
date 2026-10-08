// The visible frontier-model choices shared by Settings and onboarding.
// Keeps custom presets distinct when matching a displayed panel to the saved engine.
// Doc: Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md

import Foundation

nonisolated enum FrontierEngineTab: String, CaseIterable, Identifiable {
    case chatgpt, claude, openRouter, lmStudio, custom
    var id: Self { self }

    init(backend: ModelBackend, preset: CustomProvider.Preset) {
        switch backend {
        case .chatgpt: self = .chatgpt
        case .claude: self = .claude
        case .custom:
            switch preset {
            case .openRouter: self = .openRouter
            case .lmStudio: self = .lmStudio
            case .custom: self = .custom
            }
        }
    }

    var label: String {
        switch self {
        case .chatgpt: return "ChatGPT Subscription"
        case .claude: return "Claude Subscription"
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "LM Studio"
        case .custom: return "Custom"
        }
    }

    var badge: String? {
        switch self {
        case .chatgpt: return "recommended"
        case .claude: return "beta"
        case .lmStudio, .custom: return "local"
        case .openRouter: return nil
        }
    }
}
