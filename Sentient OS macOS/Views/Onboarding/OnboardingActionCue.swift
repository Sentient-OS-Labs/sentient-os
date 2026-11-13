// Shared, presentation-only action selection and press beats for the onboarding notch.
// sequence times the highlight, press and release before the lesson continues.
// Doc: Documentation - Onboarding.md
import Foundation

enum OnboardingActionCue: Equatable {
    case idle, highlighted, pressed, released

    var isHighlighted: Bool { self != .idle }
    var isPressed: Bool { self == .pressed }

    static let sequence: [(state: Self, delay: Double)] = [
        (.highlighted, 0.65), (.pressed, 0.95), (.released, 0.20)
    ]
    static let handoffDelay = 0.38
}

/// The two real onboarding lessons share choreography, but have separate inert outcomes.
enum OnboardingNotchAction {
    case takeOver, magicReply
    var title: String { self == .takeOver ? "Take Over" : "Magic Reply" }
}
