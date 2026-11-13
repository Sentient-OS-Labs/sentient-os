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
    private struct Draft {
        let text: String
        let replace: @MainActor (String) -> Bool
    }
    @ObservationIgnored private var preparedDraft: Draft?
    @ObservationIgnored private var prepared: ProofreadSelection.Snapshot?
    @ObservationIgnored private var captureFailure: ProofreadSelection.Failure = .noSelection
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var drainingTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var completion: ((String) -> Void)?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private let capture: (@MainActor () async throws -> ProofreadSelection.Snapshot)?
    @ObservationIgnored private let resolveSelection: @MainActor (ProofreadSelection.Snapshot, ShortcutActivity, Bool) async throws -> ProofreadSelection.Snapshot
    @ObservationIgnored private let correct: @MainActor (String) async throws -> String
    @ObservationIgnored private let apply: @MainActor (String, ProofreadSelection.Snapshot, ShortcutActivity) async -> ProofreadSelection.Outcome
    @ObservationIgnored private let deadline: Duration

    init(capture: (@MainActor () async throws -> ProofreadSelection.Snapshot)? = nil,
         resolveSelection: @escaping @MainActor (ProofreadSelection.Snapshot, ShortcutActivity, Bool) async throws -> ProofreadSelection.Snapshot = { snapshot, activity, restoringFocus in
             if restoringFocus, !(await ProofreadSelection.restoreFocus(snapshot, activity: activity)) { throw ProofreadSelection.Failure.noSelection }
             return try await ProofreadSelection.captureByCopy(pid: snapshot.pid)
         },
         correct: @escaping @MainActor (String) async throws -> String = ProofreadInference.correct,
         apply: @escaping @MainActor (String, ProofreadSelection.Snapshot, ShortcutActivity) async -> ProofreadSelection.Outcome = { await ProofreadSelection.apply($0, to: $1, activity: $2) },
         deadline: Duration = .seconds(35)) {
        self.resolveSelection = resolveSelection
        self.capture = capture; self.correct = correct; self.apply = apply; self.deadline = deadline
    }

    private static func captureSelection(pid: pid_t?) async throws -> ProofreadSelection.Snapshot {
        guard Permissions.hasAccessibility() else { throw ProofreadSelection.Failure.permission }
        guard let pid else { throw ProofreadSelection.Failure.noSelection }
        return try await Task.detached { try ProofreadSelection.bookmark(pid: pid) }.value
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
            if (prepared?.captureActivity ?? activity) != ShortcutActivity.current || (capture == nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid) {
                prepared = nil; captureFailure = .noSelection; captureWasInterrupted = true
            }
            isCapturingSelection = false; captureTask = nil
        }
    }

    /// An editor we own needs no AX capture or simulated paste.
    func prepareDraft(text: String, replace: @escaping @MainActor (String) -> Bool) {
        guard !isRunning else { return }
        clearPreparedSelection()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preparedDraft = Draft(text: text, replace: replace)
    }

    /// Identifies exactly one prepared editor snapshot across a mouse-down/up handoff.
    var preparedDraftToken: UUID? { preparedDraft == nil ? nil : captureID }

    var selectionActivity: ShortcutActivity? { prepared?.captureActivity }

    func waitForSelection() async { await captureTask?.value }
    #if DEBUG
    var hasPreparedSelectionBookmark: Bool { prepared != nil }
    #endif

    func clearPreparedSelection() {
        captureID = UUID(); captureTask?.cancel(); captureTask = nil
        prepared = nil; preparedDraft = nil; captureFailure = .noSelection; isCapturingSelection = false; captureWasInterrupted = false
    }

    @discardableResult
    func start(restoringFocus: Bool = false, completion: @escaping (String) -> Void) -> Bool {
        guard !isRunning, !DoubleTap.shared.isDrafting else { return false }
        isRunning = true; applying = false; runID = UUID()
        let id = runID, initialActivity = ShortcutActivity.current
        self.completion = completion
        task = Task { [weak self] in
            guard let self else { return }
            await waitForSelection()
            guard runID == id, !Task.isCancelled else { return }
            var snapshot = prepared
            var activity = initialActivity
            let draft = preparedDraft
            if draft == nil, let bookmark = snapshot, bookmark.requiresCopy {
                do {
                    snapshot = try await resolveSelection(bookmark, activity, restoringFocus)
                    guard runID == id, !Task.isCancelled else { return }
                    activity = snapshot?.captureActivity ?? ShortcutActivity.current
                } catch {
                    guard runID == id, !Task.isCancelled else { return }
                    let failure = (error as? ProofreadSelection.Failure) ?? .unsupported
                    finish(failure.localizedDescription, id: id); return
                }
            }
            guard let text = draft?.text ?? snapshot?.text else {
                let failure = captureFailure
                finish(failure.localizedDescription, id: id); return
            }
            // The running task now owns the captured selection until its result has settled.
            clearPreparedSelection()
            do {
                let corrected = try await correct(text)
                guard runID == id, !Task.isCancelled else { return }
                guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      corrected.utf8.count <= ProofreadInference.maximumOutputBytes else { throw ProofreadInference.Failure.incomplete }
                if corrected == text { finish("Looks good.", id: id); return }
                if let draft {
                    finish(draft.replace(corrected) ? "" : "Your draft changed. Try Proofread again.", id: id)
                    return
                }
                guard let snapshot else { finish("Select some text to proofread.", id: id); return }
                applying = true
                if restoringFocus, !(await ProofreadSelection.restoreFocus(snapshot, activity: activity)) {
                    finish("Selection changed. Select the text again.", id: id); return
                }
                let outcome = await apply(corrected, snapshot, activity)
                guard runID == id, !Task.isCancelled else { return }
                switch outcome {
                case .applied: finish("", id: id)
                case .changed:
                    finish("Selection changed. Select the text again.", id: id)
                case .unsupported:
                    finish("Couldn’t replace this selection. Try a plain-text field.", id: id)
                case .clipboardUnavailable:
                    finish("Couldn’t preserve the clipboard. Try again.", id: id)
                case .uncertain:
                    finish("Check the original text", id: id)
                }
            } catch {
                guard runID == id, !Task.isCancelled else { return }
                let message = (error as? ProofreadInference.Failure)?.localizedDescription ?? "Couldn’t connect. Your text hasn’t been changed. Select it again to retry."
                finish(message, id: id)
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
    func close() { cancel() }
    private func finish(_ caption: String, id: UUID) {
        guard runID == id else { return }
        let callback = completion; completion = nil
        deadlineTask?.cancel(); deadlineTask = nil; task = nil
        isRunning = false; applying = false; clearPreparedSelection()
        callback?(caption)
    }
}
