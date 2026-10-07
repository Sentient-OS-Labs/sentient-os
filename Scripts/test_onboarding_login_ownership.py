#!/usr/bin/env python3
"""Exercise the onboarding panel's actual login ownership methods without SwiftUI or accounts."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
source = (APP / "Views/Onboarding/OnboardingCodexSteps.swift").read_text()
assert ".onDisappear { cancelOwnedLogin() }" in source


def declaration(signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


methods = "\n".join(declaration(signature) for signature in (
    "private func prepareAndLogin()", "private func cancelOwnedLogin()",
))
fixture = r'''
import Foundation

@MainActor enum ModelBackend {
    case chatgpt, claude
    static var current: Self = .chatgpt
}
@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class Setup {
    var loggedIn = false
    var activeAttempt: UUID?
    var cancelled: [UUID] = []
    var refreshes = 0
    var starts = 0
    var prepared = true
    var prepareGate: Gate?
    var startGate: Gate?
    func ensureCurrent() async -> Bool {
        if let prepareGate { await prepareGate.wait() }
        return prepared
    }
    func startLogin() async -> UUID? {
        starts += 1
        let attempt = UUID()
        activeAttempt = attempt
        if let startGate { await startGate.wait() }
        return attempt
    }
    func cancelLogin(ifAttempt attempt: UUID) async {
        guard activeAttempt == attempt else { return }
        cancelled.append(attempt)
        activeAttempt = nil
    }
    func refreshLoginStatus() async { refreshes += 1 }
}
@MainActor final class Panel {
    let codex = Setup()
    var preparationTask: Task<Void, Never>?
    var loginRequestID = UUID()
    var ownedLoginAttempt: UUID?
    func tapSignIn() { prepareAndLogin() }
    func disappear() { cancelOwnedLogin() }
__METHODS__
}
@main struct Tests {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1; print("PASS: \(message)")
    }
    @MainActor static func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Fixture never reached expected state")
    }
    @MainActor static func main() async {
        let pendingPreparation = Panel()
        let prepareGate = Gate()
        pendingPreparation.codex.prepareGate = prepareGate
        pendingPreparation.tapSignIn()
        let prepareTask = pendingPreparation.preparationTask
        await wait { prepareGate.entered }
        pendingPreparation.disappear()
        prepareGate.release(); await prepareTask?.value
        check(pendingPreparation.codex.starts == 0, "Tab disappearance during preparation never opens a browser")

        let active = Panel()
        active.tapSignIn(); await active.preparationTask?.value
        let owned = active.codex.activeAttempt
        active.disappear()
        await wait { active.codex.activeAttempt == nil }
        check(active.codex.cancelled == [owned!], "Tab disappearance cancels its owned pending callback")
        await wait { active.codex.refreshes == 1 }
        check(active.ownedLoginAttempt == nil && active.preparationTask == nil,
              "Cancelled tab releases ownership and refreshes private status")

        let replacement = Panel()
        replacement.tapSignIn(); await replacement.preparationTask?.value
        let laterSettingsLogin = UUID()
        replacement.codex.activeAttempt = laterSettingsLogin
        replacement.disappear()
        await wait { replacement.codex.refreshes == 1 }
        check(replacement.codex.activeAttempt == laterSettingsLogin && replacement.codex.cancelled.isEmpty,
              "Old tab cannot cancel a later Settings login")

        let completed = Panel()
        completed.tapSignIn(); await completed.preparationTask?.value
        completed.codex.loggedIn = true
        completed.disappear()
        for _ in 0..<100 { await Task.yield() }
        check(completed.codex.loggedIn && completed.codex.cancelled.isEmpty,
              "Tab disappearance preserves completed private authentication")

        let starting = Panel()
        let startGate = Gate()
        starting.codex.startGate = startGate
        starting.tapSignIn()
        let startTask = starting.preparationTask
        await wait { startGate.entered }
        starting.disappear()
        startGate.release(); await startTask?.value
        check(starting.codex.activeAttempt == nil && starting.codex.cancelled.count == 1,
              "A callback returned after tab disappearance is cancelled by its token")

        let browsingChatGPT = Panel()
        ModelBackend.current = .claude
        browsingChatGPT.tapSignIn(); await browsingChatGPT.preparationTask?.value
        check(browsingChatGPT.codex.starts == 1 && ModelBackend.current == .claude,
              "Browsing ChatGPT may sign in without changing selected provider")
        browsingChatGPT.disappear()
        await wait { browsingChatGPT.codex.activeAttempt == nil }
        check(browsingChatGPT.codex.cancelled.count == 1 && browsingChatGPT.codex.refreshes == 0,
              "Provider tab change releases own callback without probing inactive ChatGPT")

        let failed = Panel()
        failed.codex.prepared = false
        failed.tapSignIn(); await failed.preparationTask?.value
        check(failed.codex.starts == 0 && failed.preparationTask == nil,
              "Preparation failure remains retryable without starting callback")
        print("RESULT: \(count) onboarding login ownership checks passed")
    }
}
'''.replace("__METHODS__", methods)

with tempfile.TemporaryDirectory(prefix="sentient-onboarding-login-") as tmp:
    directory = Path(tmp)
    swift = directory / "Fixture.swift"
    swift.write_text(fixture)
    binary = directory / "fixture"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
