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
        })
    }
    private enum QuickActionFailure: LocalizedError {
        case app, summary(String)
        var errorDescription: String? {
            switch self {
            case .app: "Identify the document's running app and pass its observed application_id. No external document was selected."
            case .summary(let message): message
            }
        }
    }
}
