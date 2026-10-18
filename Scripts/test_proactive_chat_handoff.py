#!/usr/bin/env python3
"""Exercise production card handoff methods without providers, permissions or real actions.

Compiles the real run/runReal/stopRun paths against deterministic in-memory collaborators.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import Foundation
import SwiftUI

func Log(_ value: String) {}
func ErrorLabel(_ error: Error) -> String { "test error" }
struct PreparedAction {
    var id = "card"; var title = "Reply to the planning email"
    var preparedContent = "Original draft"; var recipient = "original@example.test"
    var fireable = true
}
enum BriefingPhase: Equatable { case offer, working(Int), done }
struct Briefing {
    var id = "card"; var offer: String? = "Send this reply"
    var workLog: [String] = []
}
enum SidekickCardContext {
    static func taskSnapshot(_ action: PreparedAction) -> String { action.recipient + "\n" + action.preparedContent }
}
enum SidekickInteraction { @TaskLocal static var current: UUID? }
enum InviteProgram {
    enum Kind { case proactive }
    static let shared = Service()
    final class Service { func record(_ value: Kind) {} }
}
final class ComputerUseGate {
    struct SetupCancelled: Error {}
    static let shared = ComputerUseGate()
    var waiting = false
    var held = true
    var cancelSetup = false
    func waitUntilReady() async throws {
        waiting = true
        defer { waiting = false }
        while held { try await Task.sleep(for: .milliseconds(10)) }
        if cancelSetup { throw SetupCancelled() }
    }
}
final class ProactiveExecutor {
    enum Outcome { case fired(String), notFireable(String), failed(String) }
    static let shared = ProactiveExecutor()
    static func isFireable(_ action: PreparedAction) -> Bool { action.fireable }
    static var evidenceIssue: String?
    static func mailEvidenceIssue(_ action: PreparedAction) async -> String? { evidenceIssue }
    var outcome = Outcome.fired("The exact prepared reply was sent.")
    var calls: [PreparedAction] = []
    var interactionSeen: UUID?
    var held = false
    func fire(_ action: PreparedAction, progress: @escaping @Sendable (String) -> Void) async -> Outcome {
        calls.append(action); interactionSeen = SidekickInteraction.current
        progress("Working through your email…")
        while held && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        return outcome
    }
}
final class Conversation {
    var navigationRequests = 0
    var draft = "An unrelated draft stays here"
    func requestNavigation() { navigationRequests += 1 }
}
final class Run {
    enum Outcome: Equatable { case success, failed, stopped }
    var isRunning = false
    var isExternal = false
    var runID = UUID()
    var externalCardID: String?
    let conversation = Conversation()
    var interaction: UUID? = UUID()
    var task: Task<Void, Never>?
    var statuses: [String] = []
    var completions: [Outcome] = []
    var answer = ""
    var history: [(String, String)] = []
    func externalPush(_ line: String, runID: UUID?) {
        if self.runID == runID && isRunning { statuses.append(line) }
    }
    func completeExternal(_ outcome: Outcome, line: String, finalText: String = "", runID: UUID?) {
        guard isRunning, self.runID == runID else { return }
        completions.append(outcome); answer = finalText; isRunning = false
    }
    func ownExternalTask(_ task: Task<Void, Never>, cardID: String) { self.task = task; externalCardID = cardID }
    func stop() { task?.cancel() }
}
final class CommandCoordinator {
    let run = Run()
    var refuse = false
    var retry: ((String) -> Void)?
    func beginExternalRun(caption: String, request: String?, retryContext: String,
                          onRetry: ((String) -> Void)?, onStopRequest: @escaping () -> Void) -> Bool {
        guard !run.isRunning, !refuse else { return false }
        run.runID = UUID(); run.isRunning = true; run.isExternal = true
        run.history.append((caption, request ?? "")); retry = onRetry
        return true
    }
}
final class ForYouModel {
    struct Entry {
        let b: Briefing
        var action: PreparedAction?
        var phase: BriefingPhase = .offer
        var liveLines: [String] = []
        var id: String { b.id }
    }
    var coordinator: CommandCoordinator? = CommandCoordinator()
    var entries = [Entry(b: Briefing(), action: PreparedAction())]
    var visit = 0
    var removedFromLatest: [String] = []
    var draftPreviews: [String: (content: String, recipient: String)] = [:]
    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    func update(_ id: String, _ mutate: (inout Entry) -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) { mutate(&entries[index]) }
    }
    func removeFromLatest(_ id: String) { removedFromLatest.append(id) }
    func dismiss(_ id: String, toward: CGSize) {}
    // PRODUCTION_METHODS
}

@main enum Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }
        checks += 1
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out")
    }
    static func fresh() -> ForYouModel {
        ComputerUseGate.shared.held = true; ComputerUseGate.shared.cancelSetup = false
        ProactiveExecutor.shared.calls = []; ProactiveExecutor.shared.held = false
        ProactiveExecutor.shared.outcome = .fired("The exact prepared reply was sent.")
        ProactiveExecutor.evidenceIssue = nil
        return ForYouModel()
    }
    static func main() async throws {
        let model = fresh(), run = model.coordinator!.run
        model.draftPreviews["card"] = ("My reviewed edit", "reviewed@example.test")
        model.run("card")
        check(run.isRunning && run.history.count == 1, "request accepted synchronously before any setup")
        check(run.conversation.navigationRequests == 1, "card immediately opens chat")
        check(run.history[0].0 == "Reply to the planning email", "human-readable request in transcript")
        check(run.history[0].1.contains("My reviewed edit") && run.history[0].1.contains("reviewed@example.test"), "exact live draft captured in history")
        check(run.conversation.draft == "An unrelated draft stays here", "card does not overwrite a typed draft")
        model.run("card")
        check(run.history.count == 1, "double-click cannot start another task")
        try await until { ComputerUseGate.shared.waiting }
        check(ProactiveExecutor.shared.calls.isEmpty && run.task != nil, "permission wait belongs to shared run")
        ComputerUseGate.shared.held = false; ProactiveExecutor.shared.held = true
        try await until { !run.statuses.isEmpty }
        check(model.entry("card")?.liveLines.isEmpty == true, "live progress is chat-only")
        check(ProactiveExecutor.shared.calls[0].preparedContent == "My reviewed edit", "executor receives reviewed draft verbatim")
        check(ProactiveExecutor.shared.calls[0].recipient == "reviewed@example.test", "executor receives reviewed recipient")
        check(ProactiveExecutor.shared.interactionSeen == run.interaction, "same chat interaction reaches executor")
        ProactiveExecutor.shared.held = false
        await run.task?.value
        check(run.completions == [.success] && !run.answer.isEmpty, "one chat result on success")
        check(model.entries.isEmpty && model.removedFromLatest == ["card"], "successful suggestion retires from deck and disk")

        let stopped = fresh(), stopRun = stopped.coordinator!.run
        stopped.run("card"); try await until { ComputerUseGate.shared.waiting }
        stopped.stopRun("card"); await stopRun.task?.value
        check(stopRun.completions == [.stopped], "Stop cancels permission wait and ends in chat")
        check(ProactiveExecutor.shared.calls.isEmpty, "cancelled setup never fires action")
        check(stopped.entry("card")?.phase == .offer && stopped.removedFromLatest.isEmpty, "cancelled suggestion remains available")

        let cancelled = fresh(), cancelledRun = cancelled.coordinator!.run
        ComputerUseGate.shared.cancelSetup = true; ComputerUseGate.shared.held = false
        cancelled.run("card"); await cancelledRun.task?.value
        check(cancelledRun.completions == [.stopped] && ProactiveExecutor.shared.calls.isEmpty, "closing required setup cancels without firing")

        let stale = fresh(), staleRun = stale.coordinator!.run
        ProactiveExecutor.evidenceIssue = "This email changed; analyze again."
        stale.run("card"); await staleRun.task?.value
        check(staleRun.completions == [.failed] && staleRun.conversation.navigationRequests == 1, "stale evidence is reported in the same chat")
        check(ProactiveExecutor.shared.calls.isEmpty && stale.removedFromLatest.isEmpty, "stale evidence cannot execute or retire suggestion")

        let failure = fresh(), failedRun = failure.coordinator!.run
        ComputerUseGate.shared.held = false; ProactiveExecutor.shared.outcome = .failed("Could not finish")
        failure.run("card"); await failedRun.task?.value
        check(failedRun.completions == [.failed] && failure.entry("card")?.phase == .offer, "failure stays in chat and allows retry")
        check(failure.removedFromLatest.isEmpty, "failed suggestion is preserved")

        let background = fresh(), backgroundRun = background.coordinator!.run
        background.run("card"); try await until { ComputerUseGate.shared.waiting }
        background.visit += 1; background.entries = []
        ComputerUseGate.shared.held = false
        await backgroundRun.task?.value
        check(backgroundRun.completions == [.success], "leaving the card view does not cancel app-owned work")
        check(background.removedFromLatest == ["card"], "background completion still retires saved suggestion")

        let activeStop = fresh(), activeRun = activeStop.coordinator!.run
        ComputerUseGate.shared.held = false; ProactiveExecutor.shared.held = true
        activeStop.run("card"); try await until { !ProactiveExecutor.shared.calls.isEmpty }
        activeStop.stopRun("card"); await activeRun.task?.value
        check(activeRun.completions == [.stopped] && activeStop.removedFromLatest.isEmpty, "Stop during execution cannot record late success")

        let busy = fresh(); busy.coordinator!.run.isRunning = true
        busy.run("card")
        check(busy.coordinator!.run.history.isEmpty, "existing task prevents card launch")
        let refused = fresh(); refused.coordinator!.refuse = true
        refused.run("card")
        check(refused.coordinator!.run.conversation.navigationRequests == 0 && refused.entry("card")?.phase == .offer, "admission failure leaves suggestion intact")
        let info = fresh(); info.entries[0].action!.fireable = false
        info.run("card")
        check(info.coordinator!.run.history.isEmpty, "informational card is not an executable prompt")
        print("PASS: \(checks) proactive-to-chat lifecycle checks")
    }
}
'''


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    source = (APP / "Views/HomeView.swift").read_text()
    methods = "\n".join(method(source, signature) for signature in [
        "    func run(_ id: String)", "    private func runReal(",
        "    func stopRun(", "    private static func replacing("])
    with tempfile.TemporaryDirectory(prefix="sentient-card-chat-") as temporary:
        root = Path(temporary)
        fixture = root / "CardChat.swift"
        fixture.write_text(FIXTURE.replace("// PRODUCTION_METHODS", methods))
        executable = root / "card-chat-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-parse-as-library", str(fixture), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
