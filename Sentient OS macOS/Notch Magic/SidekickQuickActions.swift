import AppKit

extension CommandCoordinator {
    /// Captured once per foreground run. An explicit application ID can select another observed app.
    func quickActions(for source: String) -> SidekickQuickActions {
        let generation = run.runID
        let origin = quickActionOrigin(for: source)
        return SidekickQuickActions(summarize: { [weak self] preference, application in
            guard let self, self.run.runID == generation, self.run.isRunning else { throw SidekickQuickActionTools.Failure.unavailable }
            let target: SummaryAccessibility.Target?
            if let application {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:application).first,
                      app.processIdentifier != getpid() else { throw QuickActionFailure.app }
                target = SummaryAccessibility.target(for:app)
            } else { target = origin.target }
            guard let target else { throw QuickActionFailure.app }
            let display = origin.display ?? ScreenCapture.summaryDisplay() ?? CGMainDisplayID()
            let summary = self.summarize.start(displayID:display,preference:preference,target:target)
            do {
                while summary.isBusy {
                    try await Task.sleep(for:.milliseconds(50))
                    guard self.run.runID == generation, self.run.isRunning else { throw CancellationError() }
                }
                try Task.checkCancellation()
                guard summary.phase == .complete else { throw QuickActionFailure.summary(summary.error ?? "Summary was closed before completion.") }
                return .init(markdown:summary.text,source:summary.sourceLabel,
                             application:target.name,applicationID:target.bundleIdentifier ?? "",windowTitle:target.windowTitle ?? "")
            } catch is CancellationError { summary.dismiss(); throw CancellationError() }
        }, proofread: { [weak self] text in
            guard let self, self.run.runID == generation, self.run.isRunning else { throw SidekickQuickActionTools.Failure.unavailable }
            let corrected = try await ProofreadInference.correct(text)
            guard self.run.runID == generation, self.run.isRunning else { throw CancellationError() }
            return corrected
        }, magicReply: { [weak self] preference, application in
            guard let self, self.run.runID == generation, self.run.isRunning,
                  !DoubleTap.shared.isDrafting, !self.proofread.isRunning else { throw SidekickQuickActionTools.Failure.unavailable }
            guard DoubleTap.isReady else { throw QuickActionFailure.reply("Magic Reply needs your personal knowledge base. Finish setup first.") }
            let target: SummaryAccessibility.Target?
            if let application {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: application).first,
                      app.processIdentifier != getpid() else { throw QuickActionFailure.app }
                target = SummaryAccessibility.target(for: app)
            } else { target = origin.target }
            guard let target else { throw QuickActionFailure.app }
            guard target.windowTitle != nil || target.windowFrame != nil else {
                throw QuickActionFailure.reply("The conversation window could not be identified. Bring it into view and retry with its observed application_id.")
            }
            let display = origin.display ?? ScreenCapture.summaryDisplay() ?? CGMainDisplayID()
            let image = try await ScreenCapture.summaryImage(displayID: display, windowPID: target.pid,
                windowTitle: target.windowTitle, windowFrame: target.windowFrame, maxLongEdge: DoubleTap.screenshotLongEdge)
            try Task.checkCancellation()
            guard self.run.runID == generation, self.run.isRunning else { throw CancellationError() }
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { @MainActor in
                    do {
                        let outcome = try await DoubleTapInference.draft(screenshot: image, vault: VaultGenerator.vaultRoot,
                                                                         preference: preference)
                        switch outcome.verdict {
                        case .reply(let text): return text
                        case .notAMessage: throw QuickActionFailure.reply("No message reply field was visible. Open the intended conversation's reply field, preserve any existing draft, and try again.")
                        }
                    } catch DoubleTapInference.Failure.cancelled {
                        throw CancellationError()
                    } catch let failure as DoubleTapInference.Failure {
                        throw QuickActionFailure.reply(failure.label)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw QuickActionFailure.reply("Magic Reply took too long. The conversation has not been changed.")
                }
                defer { group.cancelAll() }
                guard let text = try await group.next() else { throw CancellationError() }
                return text
            }
            guard self.run.runID == generation, self.run.isRunning else { throw CancellationError() }
            return text
        })
    }
    private enum QuickActionFailure: LocalizedError {
        case app, summary(String), reply(String)
        var errorDescription: String? {
            switch self {
            case .app: "Identify the document's running app and pass its observed application_id. No external document was selected."
            case .summary(let message): message
            case .reply(let message): message
            }
        }
    }
}
