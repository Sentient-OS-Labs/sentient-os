// Keeps independent Summary requests alive until their own windows close.
// start() always captures anew; dismiss() drains all windows for reset/uninstall.
// Doc: Documentation - Summarize.md
import AppKit
import Observation

@MainActor @Observable final class SummarySessions {
    private(set) var sessions: [Summarize] = []
    var isBusy: Bool { sessions.contains { $0.isBusy } }
    @ObservationIgnored private let makeSummary: @MainActor () -> Summarize

    init(makeSummary: @escaping @MainActor () -> Summarize = { Summarize() }) {
        self.makeSummary = makeSummary
    }

    @discardableResult
    func start(displayID: CGDirectDisplayID, preference: String = "", target: SummaryAccessibility.Target? = nil) -> Summarize {
        let summary = makeSummary()
        summary.onDismiss = { [weak self, weak summary] in
            guard let summary else { return }
            self?.sessions.removeAll { $0 === summary }
        }
        sessions.append(summary)
        summary.start(displayID: displayID, preference: preference, target: target)
        return summary
    }

    func dismiss() {
        let closing = sessions
        sessions.removeAll()
        for summary in closing { summary.dismiss() }
    }
}
