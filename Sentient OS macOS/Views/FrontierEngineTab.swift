// The visible frontier-model choices shared by Settings and onboarding.
// Keeps custom presets distinct when matching a displayed panel to the saved engine.
// Doc: Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md

import Foundation

nonisolated enum FrontierEngineTab: String, CaseIterable, Identifiable {
    case sentient, chatgpt, claude, openRouter, lmStudio, custom
    var id: Self { self }

    /// Temporary presentation gate. Runtime support and saved provider choices stay intact.
    static let hostedUsageVisible = false
    static var visibleCases: [Self] { allCases.filter { $0 != .sentient || hostedUsageVisible } }
    var visibleTab: Self { self == .sentient && !Self.hostedUsageVisible ? .chatgpt : self }

    init(backend: ModelBackend, preset: CustomProvider.Preset) {
        switch backend {
        case .sentient: self = .sentient
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
        case .sentient: return "Sentient"
        case .chatgpt: return "ChatGPT Subscription"
        case .claude: return "Claude Subscription"
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "LM Studio"
        case .custom: return "Custom"
        }
    }

    var badge: String? {
        switch self {
        case .sentient: return "free"
        case .chatgpt: return nil
        case .claude: return "beta"
        case .lmStudio, .custom: return "local"
        case .openRouter: return nil
        }
    }
}
