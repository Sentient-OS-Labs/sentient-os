// Owns one ephemeral screen-summary request and reading panel. start/retry/dismiss fence every
// asynchronous callback, preserve a retry's snapshot, and cancel without affecting Sidekick.
// Doc: Documentation - Summarize.md
import AppKit
import Observation

@MainActor @Observable
final class Summarize {
    enum Phase: Equatable { case idle, capturing, loading, streaming, complete, failed }
    private(set) var phase: Phase = .idle
    private(set) var text = ""
    private(set) var error: String?
    private(set) var needsScreenPermission = false
    private(set) var needsAccessibilityPermission = false
    private(set) var sourceLabel = "Active document"
    private(set) var sourceInfo: SummarizeInference.SourceInfo?
    private(set) var expectsVideoTranscript = false
    private(set) var requestID = UUID()
    private(set) var capturedAt: Date?
    private(set) var displayID: CGDirectDisplayID?
    var isBusy: Bool { [.capturing, .loading, .streaming].contains(phase) }
    @ObservationIgnored var onDismiss: (() -> Void)?

    @ObservationIgnored private var source: SummarySource?
    @ObservationIgnored private var target: SummaryAccessibility.Target?
    @ObservationIgnored private var preference = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var window: SummaryWindowController?
    @ObservationIgnored private let capture: @MainActor (CGDirectDisplayID, SummaryAccessibility.Target?) async throws -> SummarySource
    @ObservationIgnored private let infer: @MainActor (SummarySource, String, @escaping @MainActor @Sendable (SummarizeInference.SourceInfo) -> Void, @escaping @MainActor @Sendable (String) -> Void) async throws -> String
    @ObservationIgnored private let deadline: Duration

    init(captureSource: @escaping @MainActor (CGDirectDisplayID, SummaryAccessibility.Target?) async throws -> SummarySource = SummaryCapture.capture,
         inferWithSource: @escaping @MainActor (SummarySource, String, @escaping @MainActor @Sendable (SummarizeInference.SourceInfo) -> Void, @escaping @MainActor @Sendable (String) -> Void) async throws -> String = SummarizeInference.streamWithSource,
         deadline: Duration = SummarizeInference.deadline) {
        self.capture = captureSource; self.infer = inferWithSource; self.deadline = deadline
    }

    convenience init(captureSource: @escaping @MainActor (CGDirectDisplayID, SummaryAccessibility.Target?) async throws -> SummarySource,
         inferSource: @escaping @MainActor (SummarySource, String, @escaping @MainActor @Sendable (String) -> Void) async throws -> String,
         deadline: Duration = SummarizeInference.deadline) {
        self.init(captureSource: captureSource, inferWithSource: { source, preference, _, update in
            try await inferSource(source, preference, update)
        }, deadline: deadline)
    }

    // Existing screenshot fixtures also exercise cancellation, retries and session ownership.
    convenience init(capture: @escaping @MainActor (CGDirectDisplayID) async throws -> Data,
         infer: @escaping @MainActor (Data, String, @escaping @MainActor @Sendable (String) -> Void) async throws -> String,
         deadline: Duration = SummarizeInference.deadline) {
        self.init(captureSource: { display, _ in SummarySource(image: try await capture(display), scope: "visible screen") },
                  inferSource: { source, preference, update in try await infer(source.image ?? Data(), preference, update) }, deadline: deadline)
    }

    func start(displayID: CGDirectDisplayID, preference: String = "", target: SummaryAccessibility.Target? = nil) {
        if isBusy { present(); return }
        source = nil
        self.target = target ?? SummaryAccessibility.target()
        self.displayID = displayID; self.preference = preference; capturedAt = nil
        begin()
    }

    func retry() {
        guard !isBusy, displayID != nil else { return }
        begin() // Keep the same document when a network request fails.
    }

    private func begin() {
        task?.cancel(); timeout?.cancel()
        requestID = UUID()
        let id = requestID
        text = ""; error = nil; needsScreenPermission = false; needsAccessibilityPermission = false
        sourceInfo = nil
        expectsVideoTranscript = source?.isYouTubeVideo ?? false
        sourceLabel = source.map(Self.label) ?? "Reading…"
        phase = source == nil ? .capturing : .loading
        present()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: self?.deadline ?? SummarizeInference.deadline) } catch { return }
            guard let self, self.requestID == id, self.isBusy else { return }
            // Invalidate before cancellation: a provider that returns late cannot replace this error.
            self.requestID = UUID(); self.task?.cancel(); self.task = nil
            self.phase = .failed; self.error = SummarizeInference.Failure.timedOut.localizedDescription
            if self.expectsVideoTranscript && self.sourceInfo == nil { self.sourceLabel = "Video transcript" }
        }
        task = Task { [weak self] in
            guard let self, let displayID = self.displayID else { return }
            let started = ContinuousClock.now
            do {
                let snapshot: SummarySource
                if let existing = self.source { snapshot = existing }
                else {
                    snapshot = try await self.capture(displayID, self.target)
                    guard self.requestID == id, !Task.isCancelled else { return }
                    self.source = snapshot; self.capturedAt = Date()
                    self.expectsVideoTranscript = snapshot.isYouTubeVideo
                    self.sourceLabel = Self.label(snapshot)
                }
                self.phase = .loading
                let result = try await self.infer(snapshot, self.preference, { [weak self] info in
                    guard let self, self.requestID == id, self.isBusy else { return }
                    self.sourceInfo = info
                    self.expectsVideoTranscript = info.kind == .youtube
                    self.sourceLabel = info.kind == .accessibility ? Self.textLabel(snapshot) : info.label
                }) { [weak self] update in
                    guard let self, self.requestID == id, self.isBusy else { return }
                    self.text = update; self.phase = .streaming
                }
                guard self.requestID == id, !Task.isCancelled else { return }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SummarizeInference.Failure.empty }
                self.text = result; self.phase = .complete
                if self.expectsVideoTranscript && self.sourceInfo == nil { self.sourceLabel = "Video summary" }
                Log("summarize completed duration=\(started.duration(to: .now)) bytes=\(snapshot.text.utf8.count)")
            } catch {
                guard self.requestID == id, !Task.isCancelled else { return }
                self.needsScreenPermission = (error as? ScreenCapture.SummaryFailure) == .permission
                self.needsAccessibilityPermission = (error as? SummaryAccessibility.Failure) == .permission
                self.phase = .failed
                if self.expectsVideoTranscript && self.sourceInfo == nil { self.sourceLabel = "Video transcript" }
                if let failure = error as? SummaryAccessibility.Failure { self.error = failure.localizedDescription }
                else if let failure = error as? ScreenCapture.SummaryFailure { self.error = failure.localizedDescription }
                else if let failure = error as? SummarizeInference.Failure { self.error = failure.localizedDescription }
                else if error is ScreenRelay.Failure { self.error = "Sentient couldn’t access its saved connection. Unlock your Mac and try again." }
                else { self.error = self.text.isEmpty ? "Couldn’t connect. Check your internet connection and try again." : SummarizeInference.Failure.incomplete.localizedDescription }
                Log("summarize failed permission=\(self.needsScreenPermission) partial=\(!self.text.isEmpty)")
            }
            guard self.requestID == id else { return }
            self.timeout?.cancel(); self.timeout = nil; self.task = nil
        }
    }

    private func present() {
        if window == nil { window = SummaryWindowController(summary: self) }
        window?.show(on: displayID)
    }

    private static func label(_ source: SummarySource) -> String {
        if source.isYouTubeVideo { return "Fetching video transcript…" }
        if source.text.isEmpty { return "Screen snapshot" }
        return textLabel(source)
    }

    private static func textLabel(_ source: SummarySource) -> String {
        source.offscreenTextElements > 0 ? "Read offscreen text too" : "Read text"
    }

    func dismiss() {
        requestID = UUID()
        task?.cancel(); task = nil; timeout?.cancel(); timeout = nil
        source = nil; target = nil; text = ""; error = nil; preference = ""; capturedAt = nil
        sourceInfo = nil; expectsVideoTranscript = false; sourceLabel = "Active document"
        needsScreenPermission = false; needsAccessibilityPermission = false; displayID = nil; phase = .idle
        window?.hide()
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }

    #if DEBUG
    var fixtureWindow: NSWindow? { window?.panel }
    #endif
}
