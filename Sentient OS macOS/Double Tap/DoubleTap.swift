//
//  DoubleTap.swift
//  Sentient OS macOS
//
//  The run behind a DOUBLE TAP of Sidekick's key (right ⌘ by default; the Settings choice): the
//  cursor sits in a reply box, the user taps the key twice, and a reply written in their voice
//  lands in the box. One screenshot of the display under the cursor → one model call with the
//  ENTIRE knowledge base in context (DoubleTapInference) → the reply is pasted into the focused
//  field (pasteboard + ⌘V, the user's clipboard put back after). A screenshot that isn't an email
//  or message reply box pastes nothing. Nothing about a run ever shows on the notch: the feedback
//  is the light at the caret (CaretSwirl, placed by CaretLocator) that gathers while the reply is
//  drafted and blooms as the text lands, then the paste itself; the log plus Dev Tools' timing
//  readout carry the rest.
//
//  On by default: an unset `doubletap.enabled` means on, so a fresh install and a Release build
//  (which has no Dev Tools) ship with Double Tap live; Dev Tools keeps a dev-only off switch, the
//  route picker, and the timing readout. The key listener and the two-presses-in-a-window test
//  live in CommandCoordinator: one press opens the notch, a second inside `window` retracts it and
//  fires this instead of the type field (the notch waits out the window before becoming key, so
//  the ⌘V lands in the user's own box). The run stays outside the coordinator's one-task lock, so
//  a double tap works while computer use is running too.
//
//  Key methods: start(completion:) · cancel() · window · isEnabled · lastReport.
//  Doc: Documentation - Double Tap.md (this folder).
//

import AppKit

@MainActor @Observable
final class DoubleTap {
    static let shared = DoubleTap()

    /// Two presses of Sidekick's key within this many seconds (press to press) count as a double
    /// tap. Also how long a single press waits before the type field opens (CommandCoordinator).
    static let window: TimeInterval = 0.35

    /// On unless a developer switches it off in Dev Tools (UserDefaults; unset = on). Off, two
    /// taps just open Sidekick sooner.
    static let enabledKey = "doubletap.enabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil || UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Screenshots are shrunk to this long edge before upload; a model downscales past ~2000 px
    /// anyway, so a full Retina frame only costs upload time.
    static let screenshotLongEdge = 2000

    /// Hard ceiling on one run (capture + call + paste). There is no STOP surface (nothing shows),
    /// so this is the only way out of a call that never returns.
    static let deadline: TimeInterval = 30

    /// The last run's one-line timing report, for the Dev Tools pane.
    private(set) var lastReport: String?

    enum Result { case pasted, notAMessage, stopped, failed(String) }

    private var task: Task<Void, Never>?
    private let swirl = CaretSwirl()

    /// True from the second tap until the paste (or the fade). CommandCoordinator swallows every
    /// Sidekick press meanwhile: a stray third tap must never open the type field, which would take
    /// key focus and catch the ⌘V meant for the user's box.
    var isDrafting: Bool { task != nil }

    /// Run once; `completion` arrives on the main actor exactly once. A tap while a draft is in
    /// flight is ignored rather than restarted: cancelling the first run would fade the ring the
    /// second one just started, and the paste would arrive twice.
    func start(completion: @escaping @MainActor (Result) -> Void) {
        guard task == nil else { Log("⌘⌘ double tap ignored — a reply is already being drafted"); return }
        let work = Task { [weak self] in
            guard let self else { return }
            let result = await self.perform()
            self.task = nil
            if case .pasted = result { InviteProgram.shared.record(.doubleTap) }
            if case .pasted = result {} else { self.swirl.dissolve() }   // the light fades when nothing lands
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
        if let problem = DoubleTapInference.configurationProblem { return .failed(problem) }
        guard Permissions.hasAccessibility() else { return .failed("needs Accessibility to paste") }
        // The light first: the caret is read at the instant of the tap, and the ring is up before
        // the screenshot starts. The panel is capture-visible (recordings should show the light),
        // so the shot carries the ring around the caret; the model reads through it.
        let target = CaretLocator.locate()
        swirl.begin(at: target)
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
            lastReport = "\(outcome.model) · capture \(captureMs) ms"
                + " · first text \(t.firstToken.map { "\(Int($0 * 1000)) ms" } ?? "—")"
                + " · total \(Int(t.total * 1000)) ms · in \(t.inputTokens ?? 0) (cached \(t.cachedTokens ?? 0), cache writes \(t.cacheWriteTokens.map { String($0) } ?? "—"))"
                + " · out \(t.outputTokens ?? 0) · reasoning \(t.reasoningTokens ?? 0)"
                + " · \(outcome.verdict == .notAMessage ? "not a reply box" : "reply pasted")"
                + " · light at the \(target.source.rawValue)"
            switch outcome.verdict {
            case .notAMessage:
                return .notAMessage
            case .reply(let reply):
                if Task.isCancelled { return .stopped }
                // The ring dives into the caret; the paste fires on its bloom so the text arrives with the light.
                swirl.land()
                try? await Task.sleep(for: CaretSwirl.landingDelay)
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
