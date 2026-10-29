// Versioned, presentation-only messages from the onboarding film. Nothing here
// invokes a provider, reads the vault, books a table or sends a real message.
import Foundation

enum OnboardingRestaurantStory {
    static let version = "restaurant-v2"
    static let command = "finish this for me"
    static let duration: Double = 20

    enum Beat: String, CaseIterable {
        case read, remember, open, date, time, reserve, confirmed, reply, done
        var index: Int { Self.allCases.firstIndex(of: self)! }
        var status: String {
            switch self {
            case .read: "Starting computer use…"
            case .remember: "Weekend plan"
            case .open: "Opening Juniper’s reservations"
            case .date: "Finding a table for Saturday"
            case .time: "Choosing 7 PM for two"
            case .reserve: "Completing your reservation"
            case .confirmed: "Your table is booked"
            case .reply: "Replying to James"
            case .done: "done"
            }
        }
    }

    static func beat(from body: Any) -> Beat? {
        guard let message = body as? [String: Any], message["story"] as? String == version,
              let name = message["beat"] as? String else { return nil }
        return Beat(rawValue: name)
    }
}
