// A task-scoped, app-owned receipt. Model arguments can request a question, never approve it.
import Foundation
import Synchronization

nonisolated struct ComputerUseDiagnosticAuthorization: Sendable {
    let id: UUID
    fileprivate init(id: UUID) { self.id = id }
}

nonisolated final class ComputerUseDiagnosticConsent: Sendable {
    static let argument = "computer_use_check_id"
    static let question = "Computer use is still having trouble across apps. Run a quick check in a small Sentient test window? It will briefly take focus. No report will be sent."
    static let answers = ["Run check", "Not now"]
    struct Request: Sendable { let id: UUID; let owner: UUID }
    private enum Decision: Sendable { case pending, approved, declined, consumed }
    private struct State: Sendable {
        var request: Request?
        var decision: Decision = .pending
    }
    private let state = Mutex(State())

    func request(owner: UUID) -> Request? {
        state.withLock { state in
            if let request = state.request {
                return request.owner == owner && state.decision == .pending ? request : nil
            }
            let request = Request(id: UUID(), owner: owner)
            state.request = request
            return request
        }
    }
    func pending(id: UUID) -> Request? {
        state.withLock { $0.request?.id == id && $0.decision == .pending ? $0.request : nil }
    }
    /// Called only after the existing user-question UI returns an actual answer.
    func recordAnswer(id: UUID, selectedAnswer: Int?, text: String) {
        state.withLock { state in
            guard state.request?.id == id, state.decision == .pending else { return }
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let explicitTypedChoice = selectedAnswer == nil
                && ["run check", "yes", "yes please", "yeah", "yep", "sure", "go ahead"].contains(typed)
            state.decision = selectedAnswer == 0 || explicitTypedChoice ? .approved : .declined
        }
    }
    func decline(id: UUID) {
        state.withLock { state in
            guard state.request?.id == id, state.decision == .pending else { return }
            state.decision = .declined
        }
    }
    func invalidate(owner: UUID) {
        state.withLock { state in
            if state.request?.owner == owner { state.decision = .declined }
        }
    }
    func consume(id: UUID, owner: UUID) -> ComputerUseDiagnosticAuthorization? {
        state.withLock { state in
            guard state.request?.id == id, state.request?.owner == owner, state.decision == .approved else { return nil }
            state.decision = .consumed
            return .init(id: id)
        }
    }
}
