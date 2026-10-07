// Owns a clarification or final error, its editable guidance, and the visible/return-window timers.
// Answers and cancellation consume a presentation once; stale UI events cannot affect a new one.
// Doc: Documentation - Sidekick - General.md

import Foundation

nonisolated struct SidekickQuestion: Sendable, Equatable {
    let id: UUID
    let error: String?
    let question: String
    let answers: [String]

    init(id: UUID = UUID(), error: String?, question: String, answers: [String]) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.count <= 500, answers.count == 2,
              answers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 160 }),
              answers[0].trimmingCharacters(in: .whitespacesAndNewlines) != answers[1].trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ValidationError.invalidQuestion
        }
        self.id = id; self.error = error?.isEmpty == false ? error : nil
        self.question = question; self.answers = answers
    }

    enum ValidationError: Error { case invalidQuestion }
}

/// Model questions always have two answers. A final error offers only editable retry guidance.
nonisolated enum SidekickRecoveryContent: Sendable, Equatable {
    case clarification(SidekickQuestion)
    case failure(id: UUID, error: String)

    var id: UUID {
        switch self {
        case .clarification(let question): question.id
        case .failure(let id, _): id
        }
    }
    var error: String? {
        switch self {
        case .clarification(let question): question.error
        case .failure(_, let error): error
        }
    }
    var question: SidekickQuestion? {
        if case .clarification(let question) = self { return question }
        return nil
    }
}

nonisolated struct SidekickAnswer: Sendable, Codable, Equatable {
    let text: String
    let selectedAnswer: Int?
}

/// Pure timing rules use monotonic seconds so sleep/wake and wall-clock changes cannot revive old UI.
nonisolated struct SidekickRecoveryTiming {
    enum Visibility: Equatable { case visible, hidden, expired }
    private(set) var visibility: Visibility = .visible
    private(set) var deadline: TimeInterval?
    private var remaining: TimeInterval = 8
    private var interacting = false

    init(now: TimeInterval) { deadline = now + 8 }
    mutating func interact(_ active: Bool, now: TimeInterval) {
        guard visibility == .visible, active != interacting else { return }
        interacting = active
        if active { remaining = max(0, (deadline ?? now) - now); deadline = nil }
        else { deadline = now + max(remaining, 1) }
    }
    mutating func dismiss(now: TimeInterval) {
        guard visibility == .visible else { return }
        visibility = .hidden; interacting = false; deadline = now + 7
    }
    mutating func reopen(now: TimeInterval) -> Bool {
        advance(now: now)
        guard visibility == .hidden else { return false }
        visibility = .visible; remaining = 8; deadline = now + 8; interacting = false
        return true
    }
    mutating func advance(now: TimeInterval) {
        guard let deadline, now >= deadline else { return }
        if visibility == .visible { dismiss(now: deadline) }
        if let expiry = self.deadline, now >= expiry {
            visibility = .expired; self.deadline = nil
        }
    }
}

@MainActor @Observable
final class SidekickRecovery {
    private(set) var content: SidekickRecoveryContent?
    var draft = "Try again"
    private(set) var isVisible = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var resolve: ((SidekickAnswer?) -> Void)?
    @ObservationIgnored private var timing: SidekickRecoveryTiming?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var focused = false
    @ObservationIgnored private var timerGeneration = 0
    @ObservationIgnored private var taskAborted = false
    @ObservationIgnored private var interruptedDraft: String?

    var isPending: Bool { content != nil }

    func present(_ content: SidekickRecoveryContent,
                 resolve: @escaping (SidekickAnswer?) -> Void) {
        if let old = self.content { interrupt(id: old.id) }
        self.content = content
        draft = content.question == nil ? (interruptedDraft ?? "Try again") : "Try again"
        interruptedDraft = nil; isVisible = true
        hovering = false; focused = false; timing = .init(now: Self.now)
        self.resolve = resolve
        onChange?(); schedule()
    }

    func ask(_ question: SidekickQuestion, onCancel: @escaping () -> Void) async throws -> SidekickAnswer {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                present(.clarification(question)) { answer in
                    if let answer { continuation.resume(returning: answer) }
                    else {
                        if !self.taskAborted { onCancel() }
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.interrupt(id: question.id) }
        }
    }

    func answer(id: UUID, choice: Int? = nil, text: String? = nil) {
        expireIfNeeded()
        guard let content, content.id == id, isVisible else { return }
        let value: String
        if let choice {
            guard let question = content.question, question.answers.indices.contains(choice) else { return }
            value = question.answers[choice]
        } else { value = text ?? draft }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        consume(SidekickAnswer(text: value, selectedAnswer: choice))
    }

    func cancel(id: UUID? = nil) {
        if content == nil, id == nil { interruptedDraft = nil }
        guard let content, id == nil || content.id == id else { return }
        interruptedDraft = nil; consume(nil)
    }
    private func interrupt(id: UUID) {
        guard content?.id == id else { return }
        interruptedDraft = draft; taskAborted = true; consume(nil); taskAborted = false
    }

    private func consume(_ answer: SidekickAnswer?) {
        let callback = resolve
        resolve = nil; content = nil; timing = nil; draft = "Try again"
        isVisible = false; hovering = false; focused = false; timer?.cancel(); timer = nil
        timerGeneration &+= 1
        onChange?()
        callback?(answer)
    }

    func dismiss() {
        guard content != nil else { return }
        timing?.dismiss(now: Self.now); hovering = false; focused = false
        isVisible = false; onChange?(); schedule()
    }

    @discardableResult func reopen() -> Bool {
        guard content != nil else { return false }
        if timing?.reopen(now: Self.now) == true {
            isVisible = true; onChange?(); schedule(); return true
        }
        expireIfNeeded(); return false
    }

    func setHovering(_ value: Bool) { guard hovering != value else { return }; hovering = value; updateInteraction() }
    func setFocused(_ value: Bool) { guard focused != value else { return }; focused = value; updateInteraction() }
    private func updateInteraction() {
        timing?.interact(hovering || focused, now: Self.now); schedule()
    }
    private func expireIfNeeded() {
        timing?.advance(now: Self.now)
        if timing?.visibility == .expired { cancel() }
        else if isVisible && timing?.visibility == .hidden {
            isVisible = false; onChange?(); schedule()
        }
    }
    private func schedule() {
        timer?.cancel(); timerGeneration &+= 1
        let generation = timerGeneration
        guard let deadline = timing?.deadline else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - Self.now))) } catch { return }
            guard let self, self.timerGeneration == generation else { return }
            self.timing?.advance(now: Self.now)
            if self.timing?.visibility == .expired { self.cancel() }
            else {
                self.isVisible = self.timing?.visibility == .visible
                self.onChange?(); self.schedule()
            }
        }
    }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
