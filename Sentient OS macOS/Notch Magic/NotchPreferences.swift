// Persisted notch interaction and processing appearance preferences.
// Doc: Documentation - Sidekick - General.md
import Foundation

nonisolated enum NotchPreferences {
    static let clickEnabledKey = "sidekick.notchClickEnabled"
    static let externalBarEnabledKey = "sidekick.externalBarEnabled"
    static let compactModeKey = "sidekick.compactNotchMode"
    static let physicalTapEnabledKey = "sidekick.physicalTapEnabled"
    static let secondPhysicalTapKey = "sidekick.secondPhysicalTap"
    static let physicalTapSensitivityKey = "sidekick.physicalTapSensitivity"
    static let physicalTapCalibrationKey = "sidekick.physicalTapCalibration.v1"
    static func calibration(in defaults: UserDefaults = .standard) -> PhysicalTapCalibrationProfile? {
        guard let data = defaults.data(forKey: physicalTapCalibrationKey),
              let profile = try? JSONDecoder().decode(PhysicalTapCalibrationProfile.self, from: data),
              profile.isValid else { return nil }
        return profile
    }
    static func physicalTapEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: physicalTapEnabledKey) as? Bool ?? true
    }
    static func secondPhysicalTap(in defaults: UserDefaults = .standard) -> PhysicalTapAction {
        PhysicalTapAction(rawValue: defaults.string(forKey: secondPhysicalTapKey) ?? "") ?? .close
    }
    static func physicalTapThreshold(in defaults: UserDefaults = .standard) -> Double {
        threshold(for: defaults.string(forKey: physicalTapSensitivityKey) ?? "standard")
    }
    static func threshold(for sensitivity: String) -> Double {
        switch sensitivity {
        case "gentle": 0.7
        case "firm": 2.0
        default: 1.1
        }
    }
    static func clickEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: clickEnabledKey) as? Bool ?? true
    }

    static func externalBarEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: externalBarEnabledKey) as? Bool ?? true
    }

    static func compactModeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactModeKey)
    }
}

nonisolated enum PhysicalTapAction: String, CaseIterable {
    case close, takeOver, magicReply, summarize, proofread
    var label: String {
        switch self {
        case .close: "Close notch"
        case .takeOver: "Take Over"
        case .magicReply: "Magic Reply"
        case .summarize: "Summarize"
        case .proofread: "Proofread"
        }
    }
}

extension Notification.Name {
    static let notchInteractionChanged = Notification.Name("sidekick.notchInteractionChanged")
    static let notchAppearanceChanged = Notification.Name("sidekick.notchAppearanceChanged")
    static let physicalNotchTapChanged = Notification.Name("sidekick.physicalNotchTapChanged")
}

nonisolated struct PhysicalTapCalibrationProfile: Codable, Sendable {
    let version: Int
    let date: Date
    let sensitivities: [String]
    let baselineLux: Double

    var isValid: Bool {
        version == 1 && !sensitivities.isEmpty && baselineLux.isFinite && baselineLux > 0.25
            && sensitivities.allSatisfy { ["gentle", "standard", "firm"].contains($0) }
    }
}
