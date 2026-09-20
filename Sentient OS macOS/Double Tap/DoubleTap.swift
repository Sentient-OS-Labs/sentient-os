//
//  DoubleTap.swift
//  Sentient OS macOS
//
//  The run behind a DOUBLE TAP of its own key (`key`, right ⌥ for now): the cursor sits in a reply
//  box, the user taps the key twice, and a reply written in their voice lands in the box. One
//  screenshot of the display under the cursor → one cold call with the ENTIRE knowledge base in
//  context (DoubleTapInference) → the reply is pasted into the focused field (pasteboard + ⌘V, the
//  user's clipboard put back after). A screenshot that isn't an email or message reply box gets a
//  short notch aside instead.
//
//  Manual-test harness for now: the enable switch and the OpenAI key live in Dev Tools. The key
//  listener and the two-presses-in-a-window test live in CommandCoordinator (a second
//  SidekickHotkeyMonitor beside Sidekick's own; Sidekick's hotkey setting is untouched, and if it
//  is set to the same key Sidekick keeps it). The run rides the coordinator's one-task lock, so the
//  notch shows "Drafting your reply" and a Sidekick hotkey press is STOP.
//
//  Key methods: start(completion:) · cancel() · key · isEnabled · lastReport.
//

import AppKit

@MainActor @Observable
final class DoubleTap {
    static let shared = DoubleTap()

    /// Double Tap's own key, separate from Sidekick's hotkey setting. Hardcoded for the test build.
    static let key: SidekickHotkey = .rightOption

    /// Two presses within this many seconds (press to press) count as a double tap.
    static let window: TimeInterval = 0.35

    /// The notch aside for a screenshot that isn't a reply box (the notch truncates past ~45 chars).
    static let notice = "double tap in an email or message reply box"

    /// Dev switch (UserDefaults). Off = the key does nothing.
    static let enabledKey = "doubletap.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Screenshots are shrunk to this long edge before upload; a model downscales past ~2000 px
    /// anyway, so a full Retina frame only costs upload time.
    static let screenshotLongEdge = 2000

    /// Hard ceiling on one run (capture + call + paste); STOP is the user's way out before it.
    static let deadline: TimeInterval = 30

    /// The last run's one-line timing report, for the Dev Tools pane.
    private(set) var lastReport: String?

    enum Result { case pasted, notAMessage, stopped, failed(String) }

    private var task: Task<Void, Never>?

    /// Run once; `completion` arrives on the main actor exactly once.
    func start(completion: @escaping @MainActor (Result) -> Void) {
        task?.cancel()
        let work = Task { [weak self] in
            guard let self else { return }
            let result = await self.perform()
            self.task = nil
            completion(result)
        }
        task = work
        Task {
            try? await Task.sleep(for: .seconds(Self.deadline))
            if !work.isCancelled { work.cancel() }
        }
    }

    func cancel() { task?.cancel() }

    private func perform() async -> Result {
        guard DoubleTapInference.apiKey != nil else {
            return .failed(DoubleTapInference.Failure.noKey(DoubleTapInference.provider).label)
        }
        guard Permissions.hasAccessibility() else { return .failed("needs Accessibility to paste") }
        let started = Date()
        guard let shot = await ScreenCapture.grabDisplayUnderCursor() else {
            return .failed("no screenshot (Screen Recording?)")
        }
        defer { ScreenCapture.discard([shot]) }
        guard let jpeg = ScreenCapture.downscaledJPEG(shot, maxLongEdge: Self.screenshotLongEdge) else {
            return .failed("screenshot encode failed")
        }
        let captureMs = Int(Date().timeIntervalSince(started) * 1000)
        if Task.isCancelled { return .stopped }
        do {
            let outcome = try await DoubleTapInference.draft(screenshot: jpeg, vault: VaultGenerator.vaultRoot)
            let t = outcome.timing
            lastReport = "\(DoubleTapInference.provider.model) · capture \(captureMs) ms"
                + " · first text \(t.firstToken.map { "\(Int($0 * 1000)) ms" } ?? "—")"
                + " · total \(Int(t.total * 1000)) ms · in \(t.inputTokens ?? 0) (cached \(t.cachedTokens ?? 0))"
                + " · out \(t.outputTokens ?? 0) · thinking \(t.thinkingTokens ?? 0)"
                + " · \(outcome.verdict == .notAMessage ? "not a reply box" : "reply pasted")"
            switch outcome.verdict {
            case .notAMessage:
                return .notAMessage
            case .reply(let reply):
                if Task.isCancelled { return .stopped }
                ReplyPaste.insert(reply)
                return .pasted
            }
        } catch DoubleTapInference.Failure.cancelled {
            return .stopped
        } catch let failure as DoubleTapInference.Failure {
            lastReport = "✗ \(failure.label)"
            return .failed(failure.label)
        } catch {
            return .failed(ErrorLabel(error))
        }
    }
}

/// Paste `text` into the focused field of the frontmost app: pasteboard + one ⌘V, then the user's
/// previous clipboard text is put back. Paste (not keystrokes) on purpose: in iMessage, WhatsApp,
/// and Slack a typed Return SENDS, while a pasted newline is just a line break. Posting the key
/// event rides Sentient's own Accessibility grant.
private enum ReplyPaste {
    @MainActor static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        Log("⌘⌘ reply pasted (\(text.count) chars)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard let previous else { return }
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }
}
