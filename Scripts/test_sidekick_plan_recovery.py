#!/usr/bin/env python3
"""Verify actual provider-error upgrade policy with synthetic plans/errors and inert recovery.
Compiles the real recovery owner, typed policy and shared provider text classifier. No account
lookup, provider execution, app launch, pricing navigation or billing mutation occurs.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'


def member(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


recovery = (APP / 'Notch Magic/SidekickRecovery.swift').read_text()
end = (APP / 'Notch Magic/SidekickTaskEnd.swift').read_text()
classifier = (APP / 'Cloud/CodexDiagnostics.swift').read_text()
fixture = r'''
import Foundation
import Observation
nonisolated enum ModelBackend: String, CaseIterable { case chatgpt, claude, custom }
nonisolated enum CodexCLI {
    enum Availability { case notInstalled, notWorking(String) }
    enum CLIError: Error {
        case usageLimit(message: String, sessionID: String?)
        case exitFailure(code: Int32, message: String)
        case notAvailable(Availability), launchFailed(String), timedOut(after: TimeInterval)
        case badEnvelope(String), inputTooLarge(chars: Int), staleClient
    }
}
nonisolated enum DirectMCPError: Error { case http(Int) }
nonisolated enum CodexFailureReason {
    case notLoggedIn, tokenExpired, refreshFailed, usageLimit, planDenied, modelNotFound, dns, tls, streamDisconnect
    case connectTimeout, http403, sandboxDenied, http5xx, timeoutOurs, staleClient, spawnFailed, screenCapture, noWindows, notInstalled, unknown
// CLASSIFY
}
'''.replace('// CLASSIFY', member(classifier, 'static func classify(text:'))

checks = r'''
@main struct Checks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS " + message)
        }
        let quota = CodexCLI.CLIError.usageLimit(message: "Usage limit reached", sessionID: "fixture-session")
        let denied = CodexCLI.CLIError.exitFailure(code: 1, message: "This request is not available for your plan")
        for backend in ModelBackend.allCases {
            for plan in [nil, "free", "go", "Free", "Go", "plus", "pro", "business", "edu", "enterprise", "future"] as [String?] {
                let eligible = backend == .chatgpt && ["free", "go"].contains(plan?.lowercased() ?? "")
                for error in [quota, denied] {
                    let offer = SidekickUpgradeOffer.forProviderFailure(error, backend: backend, planRaw: plan, assertedPlus: false)
                    check((offer != nil) == eligible, "\(backend.rawValue)/\(plan ?? "unknown") admits only known Free/Go provider limits")
                }
            }
        }
        check(SidekickUpgradeOffer.forProviderFailure(quota, backend: .chatgpt, planRaw: "free", assertedPlus: true) == nil,
              "a declared upgrade suppresses a stale Free plan claim")
        let otherErrors: [Error] = [
            DirectMCPError.http(429), DirectMCPError.http(403), URLError(.notConnectedToInternet),
            CodexCLI.CLIError.timedOut(after: 30), CodexCLI.CLIError.badEnvelope("You need to upgrade to Plus"),
            CodexCLI.CLIError.notAvailable(.notWorking("requires ChatGPT Plus")),
            CodexCLI.CLIError.exitFailure(code: 1, message: "model_not_found: not available for your plan"),
            CodexCLI.CLIError.exitFailure(code: 1, message: "model_not_available: requires ChatGPT Plus"),
            CodexCLI.CLIError.exitFailure(code: 1, message: "HTTP 403 requires ChatGPT Plus"),
            CodexCLI.CLIError.exitFailure(code: 1, message: "Permission denied: not entitled"),
            CodexCLI.CLIError.exitFailure(code: 1, message: "DNS error while checking entitlement"),
            CodexCLI.CLIError.exitFailure(code: 1, message: "Upgrade to Plus might help")
        ]
        for (index, error) in otherErrors.enumerated() {
            check(SidekickUpgradeOffer.forProviderFailure(error, backend: .chatgpt, planRaw: "free", assertedPlus: false) == nil,
                  "non-provider quota, permission, network, model or speculative error \(index) has no billing action")
        }
        let owner = SidekickRecovery()
        var answers: [SidekickAnswer] = []
        let ordinary = SidekickRecoveryContent.failure(id: UUID(), error: "The model says upgrade to Plus")
        check(ordinary.upgradeOffer == nil, "displayed model text cannot create an upgrade offer")
        let offer = SidekickRecoveryContent.failure(id: UUID(), error: "Provider failure", upgradeOffer: .usageLimit)
        owner.present(offer) { resolution in if case .answered(let answer) = resolution { answers.append(answer) } }
        owner.draft = "Keep the same task context"
        owner.dismiss()
        check(owner.isPending && !owner.isVisible && owner.draft == "Keep the same task context",
              "opening pricing/settings can hide recovery without discarding retry guidance")
        check(owner.reopen(), "provider-limit recovery can reopen after external navigation")
        owner.answer(id: offer.id, text: "Try this task again.")
        check(answers.count == 1 && answers[0].text == "Try this task again." && !owner.isPending,
              "retry uses the existing recovery continuation exactly once")
        owner.answer(id: offer.id, text: "stale retry")
        check(answers.count == 1, "stale retry action cannot start another task")
        owner.present(offer) { _ in }
        owner.cancel(id: offer.id)
        check(!owner.isPending, "Stop remains available for provider-limit recovery")
        print("Sidekick plan recovery: \(checks) checks passed")
    }
}
'''

# The UI must use the same component in Home and notch. This asserts the actual wiring, while
# behavior tests above execute the owner/policy without attempting an external action.
view = (APP / 'Notch Magic/SidekickRecoveryView.swift').read_text()
composer = (APP / 'Views/Sidekick/SidekickComposer.swift').read_text()
command = (APP / 'Notch Magic/CommandRunModel.swift').read_text()
assert 'SidekickUpgradeActions(recovery: recovery, content: content)' in view
assert 'SidekickUpgradeActions(recovery: recovery, content: content)' in composer
assert 'ModelBackend(rawValue: recording.backend)' in command
assert 'planRaw: CodexAuth.currentPlan()?.raw' in command
assert 'NSWorkspace.shared.open(CodexAuth.upgradeURL)' in view
assert 'HomeWindowOpening.open(.settings, settingsPane: .frontierModel)' in view
assert 'content.question == nil && content.upgradeOffer == nil' in recovery
source = '\n'.join((fixture, recovery, member(end, 'extension SidekickUpgradeOffer'), checks))
with tempfile.TemporaryDirectory(prefix='sentient-plan-recovery-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
