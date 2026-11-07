// One calm, slightly playful line per startup. Never implies an external action completed.
import Foundation

nonisolated enum SidekickStartupCopy {
    static let phrases = [
        "Thinking it through…",
        "Finding a good starting point…",
        "Getting things ready…",
        "Putting the pieces together…",
        "Working out the next step…",
        "Getting oriented…",
        "Lining up the next steps…",
        "Finding a way forward…",
        "Gathering the threads…",
        "A little thinking first…",
        "Setting things in motion…",
        "Looking at the task ahead…",
        "Getting Sidekick ready…",
        "Warming up the gears…",
        "Bringing the task into focus…",
        "Taking a moment to plan…",
        "Checking the starting point…",
        "Finding the right approach…",
        "Getting a plan together…",
        "Starting with the essentials…",
        "Making room for a good idea…",
        "Following the thread…",
        "Considering the possibilities…",
        "Turning the task over…",
        "Finding the next move…",
        "Preparing to get started…",
        "Taking the first step…",
        "Sorting out the details…",
        "Let’s see what this needs…",
        "Sidekick is thinking…",
    ]

    static func choose(excluding previous: String?) -> String {
        phrases.filter { $0 != previous }.randomElement() ?? phrases[0]
    }
}
