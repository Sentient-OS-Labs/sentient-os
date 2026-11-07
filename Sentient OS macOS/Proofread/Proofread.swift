// Owns one proofreading operation and its short-lived selection. Capture precedes notch focus;
// only a complete result can reach guarded insertion. Cancellation fences every late callback.
// Doc: Documentation - Proofread.md
import AppKit
import Observation

@MainActor @Observable final class Proofread {
    static let shared = Proofread()
    private(set) var isRunning = false
    private(set) var isCapturingSelection = false
    private(set) var captureWasInterrupted = false
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var prepared: ProofreadSelection.Snapshot?
    @ObservationIgnored private var captureFailure: ProofreadSelection.Failure = .noSelection
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var drainingTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var completion: ((String) -> Void)?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var resultPanel: ProofreadResultPanel?
    @ObservationIgnored private let capture: (@MainActor () async throws -> ProofreadSelection.Snapshot)?
    @ObservationIgnored private let correct: @MainActor (String) async throws -> String
    @ObservationIgnored private let apply: @MainActor (String, ProofreadSelection.Snapshot, ShortcutActivity) async -> ProofreadSelection.Outcome
    @ObservationIgnored private let showResult: @MainActor (String?, String, Bool) -> Void
    @ObservationIgnored private let deadline: Duration

    init(capture: (@MainActor () async throws -> ProofreadSelection.Snapshot)? = nil,
         correct: @escaping @MainActor (String) async throws -> String = ProofreadInference.correct,
         apply: @escaping @MainActor (String, ProofreadSelection.Snapshot, ShortcutActivity) async -> ProofreadSelection.Outcome = { await ProofreadSelection.apply($0, to: $1, activity: $2) },
         showResult: (@MainActor (String?, String, Bool) -> Void)? = nil,
         deadline: Duration = .seconds(35)) {
        self.capture = capture; self.correct = correct; self.apply = apply; self.deadline = deadline
        self.showResult = showResult ?? { _, _, _ in }
        if showResult == nil { resultPanel = ProofreadResultPanel() }
    }

    private static func captureSelection(pid: pid_t?) async throws -> ProofreadSelection.Snapshot {
        guard Permissions.hasAccessibility() else { throw ProofreadSelection.Failure.permission }
        guard let pid else { throw ProofreadSelection.Failure.noSelection }
        return try await Task.detached(priority: .userInitiated) { try ProofreadSelection.capture(pid: pid) }.value
    }

    func prepareSelection() {
        guard !isRunning else { return }
        clearPreparedSelection()
        let id = captureID, activity = ShortcutActivity.current
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        isCapturingSelection = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value: ProofreadSelection.Snapshot
                if let capture { value = try await capture() }
                else { value = try await Self.captureSelection(pid: pid) }
                guard captureID == id, !Task.isCancelled else { return }
                prepared = value
            } catch {
                guard captureID == id, !Task.isCancelled else { return }
                captureFailure = (error as? ProofreadSelection.Failure) ?? .unsupported
            }
            guard captureID == id else { return }
            if activity != ShortcutActivity.current || (capture == nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid) {
                prepared = nil; captureFailure = .noSelection; captureWasInterrupted = true
            }
            isCapturingSelection = false; captureTask = nil
        }
    }

    func waitForSelection() async { await captureTask?.value }
    #if DEBUG
    func preparedSelectionMatches(_ text: String) -> Bool { prepared?.text == text }
    #endif

    func clearPreparedSelection() {
        captureID = UUID(); captureTask?.cancel(); captureTask = nil
        prepared = nil; captureFailure = .noSelection; isCapturingSelection = false; captureWasInterrupted = false
    }

    @discardableResult
    func start(completion: @escaping (String) -> Void) -> Bool {
        guard !isRunning, !DoubleTap.shared.isDrafting else { return false }
        isRunning = true; applying = false; runID = UUID()
        let id = runID, activity = ShortcutActivity.current
        self.completion = completion
        resultPanel?.close()
        task = Task { [weak self] in
            guard let self else { return }
            await waitForSelection()
            guard runID == id, !Task.isCancelled else { return }
            guard let snapshot = prepared else {
                let failure = captureFailure
                if case .permission = failure { present(nil, failure.localizedDescription, permission: true) }
                finish(failure.localizedDescription, id: id); return
            }
            // The running task now owns the captured selection until its result has settled.
            clearPreparedSelection()
            do {
                let corrected = try await correct(snapshot.text)
                guard runID == id, !Task.isCancelled else { return }
                guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      corrected.utf8.count <= ProofreadInference.maximumOutputBytes else { throw ProofreadInference.Failure.incomplete }
                if corrected == snapshot.text { finish("Looks good.", id: id); return }
                applying = true
                let outcome = await apply(corrected, snapshot, activity)
                guard runID == id, !Task.isCancelled else { return }
                switch outcome {
                case .applied: finish("", id: id)
                case .changed:
                    present(corrected, "Your selection or editing context changed. The correction is ready to copy.")
                    finish("Correction ready", id: id)
                case .unsupported:
                    present(corrected, "This selection can’t be replaced safely in its editor. The correction is ready to copy.")
                    finish("Correction ready", id: id)
                case .clipboardUnavailable:
                    present(corrected, ProofreadSelection.Failure.clipboard.localizedDescription)
                    finish("Correction ready", id: id)
                case .uncertain:
                    present(corrected, "Sentient couldn’t verify the replacement. Check your original text before using this correction.")
                    finish("Check the original text", id: id)
                }
            } catch {
                guard runID == id, !Task.isCancelled else { return }
                let message = (error as? ProofreadInference.Failure)?.localizedDescription ?? "Couldn’t connect. Your text hasn’t been changed. Select it again to retry."
                present(nil, message)
                finish("Couldn’t proofread", id: id)
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: self?.deadline ?? .seconds(35)) } catch { return }
            guard let self, self.runID == id, self.isRunning else { return }
            self.cancel(message: self.applying ? "Stopped. Check the original text." : "Proofreading took too long. Try again.")
        }
        return true
    }

    func cancel(message: String? = nil) {
        guard drainingTask == nil else { return }
        let callback = completion, wasRunning = isRunning, wasApplying = applying, work = task
        let caption = message ?? (applying ? "Stopped. Check the original text." : "Proofreading stopped")
        runID = UUID(); task?.cancel(); task = nil; deadlineTask?.cancel(); deadlineTask = nil
        completion = nil; applying = false; clearPreparedSelection()
        if wasApplying, let work {
            // A posted paste cannot be recalled. Keep every editing entry blocked until its
            // bounded verification and clipboard cleanup have drained, even after Cancel.
            drainingTask = Task { [weak self] in
                await work.value
                self?.isRunning = false; self?.drainingTask = nil
            }
        } else { isRunning = false }
        if wasRunning { callback?(caption) }
    }
    func close() { cancel(); resultPanel?.close() }
    private func finish(_ caption: String, id: UUID) {
        guard runID == id else { return }
        let callback = completion; completion = nil
        deadlineTask?.cancel(); deadlineTask = nil; task = nil
        isRunning = false; applying = false; clearPreparedSelection()
        callback?(caption)
    }
    private func present(_ text: String?, _ explanation: String, permission: Bool = false) {
        if let resultPanel { resultPanel.show(text: text, explanation: explanation, permission: permission) }
        else { showResult(text, explanation, permission) }
    }
}
