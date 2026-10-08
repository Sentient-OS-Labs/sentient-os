#!/usr/bin/env python3
"""Exercise production onboarding continuation with isolated setup fixtures.

Compiles the real tab mapping, provider enum, connector links, and the view's exact
readiness/continuation methods. Fake setup services control asynchronous completion;
no app preferences, credentials, provider services, or SwiftUI windows are touched.
This checks controller behavior, not rendered UI or the real CLI installer.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def declaration(source, signature):
    """Copy a complete production declaration, preserving its executable body."""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


view = (APP / "Views/Onboarding/OnboardingFrontierModelView.swift").read_text()
picker = (APP / "Views/FrontierEnginePicker.swift").read_text()
for event in ("backendRaw", "presetRaw", "tab"):
    assert f".onChange(of: {event}) {{ cancelContinue() }}" in view, event
assert ".onDisappear { cancelContinue() }" in view
assert "FrontierEnginePicker(tab: $tab" in view
assert "@Binding private var tab: Tab" in picker
for filename, slug in (("GmailConnect.swift", "gmail"), ("CalendarConnect.swift", "google-calendar")):
    getter = declaration((APP / "Sources" / filename).read_text(), "static var connectorURL: URL")
    assert f'ConnectorLinks.page(for: "{slug}")' in getter, filename

production = "\n".join([
    declaration((APP / "Cloud/ModelBackend.swift").read_text(), "nonisolated enum ModelBackend"),
    (APP / "Views/FrontierEngineTab.swift").read_text(),
    (APP / "Cloud/ConnectorLinks.swift").read_text(),
])
methods = "\n".join(declaration(view, signature) for signature in (
    "private var continuing: Bool",
    "private var activeTab: FrontierEngineTab",
    "private var engineReady: Bool",
    "private func continueWithEngine()",
    "private func cancelContinue()",
))

fixture = r'''
import Foundation

// The production custom-provider implementation reads UserDefaults and Keychain.
// Its readiness result is injected here; tab/preset identity uses its actual cases.
@MainActor struct CustomProvider {
    nonisolated enum Preset: String { case openRouter = "openrouter", lmStudio = "lmstudio", custom }
    static var usable = true
    static var current: Self { Self() }
    var isUsable: Bool { Self.usable }
}

@MainActor final class SetupFixture {
    var loggedIn = true
    var installStatus: String?
    var prepare: () async -> Bool = { true }
    var refresh: () async -> Void = {}
    var preparationCalls = 0
    var loginChecks = 0
    func ensureCurrent() async -> Bool { preparationCalls += 1; return await prepare() }
    func refreshLoginStatus() async { loginChecks += 1; await refresh() }
}

@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class OnboardingFixture {
    let codex = SetupFixture()
    let claude = SetupFixture()
    var observesChanges = true
    var backendRaw = "chatgpt" { didSet { if observesChanges { cancelContinue() } } }
    var presetRaw = "openrouter" { didSet { if observesChanges { cancelContinue() } } }
    var tab: FrontierEngineTab = .chatgpt { didSet { if observesChanges { cancelContinue() } } }
    var visionVerified = true
    var continueAttempt: UUID?
    var continueTask: Task<Void, Never>?
    var continueStatus: String?
    var advances = 0
    var advancedBackend: String?
    var ready: Bool { engineReady }
    func tapContinue() { continueWithEngine() }
    func disappear() { cancelContinue() }
    func onContinue() { advances += 1; advancedBackend = backendRaw }
__METHODS__
}

@main struct ProviderSelectionTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    @MainActor static func waitFor(_ gate: Gate) async {
        for _ in 0..<1_000 {
            if gate.entered { return }
            await Task.yield()
        }
        preconditionFailure("Fixture never reached its async boundary")
    }

    @MainActor static func main() async {
        let initial = OnboardingFixture()
        check(initial.ready, "Default ChatGPT login was not ready")
        initial.tapContinue(); initial.tapContinue()
        await initial.continueTask?.value
        check(initial.advances == 1 && initial.codex.preparationCalls == 1, "Default Continue did not advance exactly once")

        // Claude can be committed by Continue once signed in. Other choices
        // still require their own active identity, including custom presets.
        let states: [(ModelBackend, CustomProvider.Preset, FrontierEngineTab)] = [
            (.chatgpt, .openRouter, .chatgpt), (.claude, .openRouter, .claude),
            (.custom, .openRouter, .openRouter), (.custom, .lmStudio, .lmStudio),
            (.custom, .custom, .custom)
        ]
        for (backend, preset, expected) in states {
            check(FrontierEngineTab(backend: backend, preset: preset) == expected, "Wrong active tab")
            for visible in FrontierEngineTab.allCases {
                let flow = OnboardingFixture()
                flow.backendRaw = backend.rawValue; flow.presetRaw = preset.rawValue; flow.tab = visible
                check(flow.ready == (visible == .claude || visible == expected), "Wrong readiness for visible provider")
            }
        }

        // The reported workaround: commit Claude, return to the ChatGPT panel,
        // then press Continue without successfully committing ChatGPT.
        let flow = OnboardingFixture()
        flow.tab = .claude; flow.backendRaw = "claude"
        flow.tab = .chatgpt
        flow.tapContinue()
        check(flow.continueTask == nil && flow.advances == 0, "Continue advanced under hidden Claude")
        check(flow.claude.preparationCalls == 0, "Wrong provider was prepared")
        flow.backendRaw = "chatgpt"
        flow.tapContinue()
        await flow.continueTask?.value
        check(flow.advances == 1 && flow.codex.preparationCalls == 1, "Committed ChatGPT did not advance")
        check(flow.codex.loginChecks == 1 && flow.claude.loginChecks == 0, "Wrong login checked")

        let claudeFlow = OnboardingFixture()
        claudeFlow.tab = .claude; claudeFlow.backendRaw = "claude"
        claudeFlow.tapContinue(); await claudeFlow.continueTask?.value
        check(claudeFlow.advances == 1 && claudeFlow.claude.preparationCalls == 1, "Committed Claude did not advance")
        check(claudeFlow.claude.loginChecks == 1 && claudeFlow.codex.preparationCalls == 0, "Claude prepared the wrong login")

        // Existing Claude login: browsing preserves the saved engine; one Continue
        // prepares Claude, verifies its login, then commits it before navigation.
        for (backend, preset, _) in states {
            let selection = OnboardingFixture()
            selection.backendRaw = backend.rawValue; selection.presetRaw = preset.rawValue
            selection.codex.loggedIn = false
            selection.tab = .claude
            check(selection.ready && selection.backendRaw == backend.rawValue, "Browsing Claude changed the engine or required Use Claude")
            let prepareGate = Gate(); let loginGate = Gate()
            selection.claude.prepare = { await prepareGate.wait(); return true }
            selection.claude.refresh = { await loginGate.wait() }
            selection.tapContinue(); selection.tapContinue()
            let pending = selection.continueTask!
            await waitFor(prepareGate)
            check(selection.backendRaw == backend.rawValue && selection.advances == 0, "Claude committed before preparation")
            prepareGate.release(); await waitFor(loginGate)
            check(selection.backendRaw == backend.rawValue && selection.advances == 0, "Claude committed before login validation")
            loginGate.release(); await pending.value
            check(selection.advances == 1 && selection.advancedBackend == "claude", "Continue did not commit Claude before advancing once")
            check(selection.claude.preparationCalls == 1 && selection.claude.loginChecks == 1 && selection.codex.preparationCalls == 0,
                  "Claude Continue prepared the wrong provider or ran twice")
        }

        for expires in [false, true] {
            let selection = OnboardingFixture()
            selection.tab = .claude
            selection.claude.prepare = { expires }
            selection.claude.refresh = { selection.claude.loggedIn = false }
            selection.tapContinue(); await selection.continueTask?.value
            check(selection.backendRaw == "chatgpt" && selection.advances == 0 && selection.continueAttempt == nil,
                  "Failed Claude selection changed the engine or advanced")
            check(selection.continueStatus != nil, "Claude selection failed silently")
            selection.claude.prepare = { true }
            selection.claude.refresh = {}
            selection.claude.loggedIn = true
            selection.tapContinue(); await selection.continueTask?.value
            check(selection.advances == 1 && selection.advancedBackend == "claude", "Claude selection retry did not recover")
        }

        let loggedOutClaude = OnboardingFixture()
        loggedOutClaude.tab = .claude; loggedOutClaude.claude.loggedIn = false
        loggedOutClaude.tapContinue()
        check(!loggedOutClaude.ready && loggedOutClaude.continueTask == nil, "Saved ChatGPT login authorized logged-out Claude")

        // A stale Claude continuation must never overwrite a newer choice, even
        // before SwiftUI delivers the change callback, or after leaving the step.
        for duringLogin in [false, true] {
            for observe in [false, true] {
                for change in ["tab", "backend", "leave"] {
                    let selection = OnboardingFixture()
                    selection.tab = .claude; selection.observesChanges = observe
                    let gate = Gate()
                    if duringLogin { selection.claude.refresh = { await gate.wait() } }
                    else { selection.claude.prepare = { await gate.wait(); return true } }
                    selection.tapContinue(); let pending = selection.continueTask!
                    await waitFor(gate)
                    switch change {
                    case "tab": selection.tab = .chatgpt
                    case "backend": selection.backendRaw = "custom"
                    default: selection.disappear()
                    }
                    let savedBackend = selection.backendRaw
                    gate.release(); await pending.value
                    check(selection.advances == 0 && selection.backendRaw == savedBackend, "Stale Claude Continue committed or navigated")
                }
            }
        }
        for backend in [ModelBackend.chatgpt, .claude] {
            let loggedOut = OnboardingFixture()
            loggedOut.backendRaw = backend.rawValue
            loggedOut.tab = backend == .claude ? .claude : .chatgpt
            loggedOut.codex.loggedIn = false; loggedOut.claude.loggedIn = false
            loggedOut.tapContinue()
            check(!loggedOut.ready && loggedOut.continueTask == nil, "Logged-out provider started Continue")
        }

        // Readiness and setup failures remain retryable and explain the failure.
        let failure = OnboardingFixture()
        failure.codex.prepare = { false }
        failure.tapContinue(); await failure.continueTask?.value
        check(failure.advances == 0 && failure.continueAttempt == nil, "Failed preparation advanced or stuck")
        check(failure.continueStatus?.contains("couldn't be prepared") == true, "Preparation failed silently")
        failure.codex.prepare = { true }
        failure.tapContinue(); await failure.continueTask?.value
        check(failure.advances == 1 && failure.continueStatus == nil, "Retry did not recover")

        let expired = OnboardingFixture()
        expired.codex.refresh = { expired.codex.loggedIn = false }
        expired.tapContinue(); await expired.continueTask?.value
        check(expired.advances == 0 && !expired.ready, "Expired login advanced")
        check(expired.continueStatus?.contains("Sign in") == true, "Expired login failed silently")

        CustomProvider.usable = false
        let unverified = OnboardingFixture()
        unverified.backendRaw = "custom"; unverified.tab = .openRouter
        check(!unverified.ready, "Unverified custom model advanced")
        CustomProvider.usable = true

        // Check both onChange cancellation and the completion guard, including a
        // UI render that has not delivered its observation callback yet.
        for observe in [true, false] {
            let changing = OnboardingFixture()
            changing.observesChanges = observe
            let gate = Gate()
            changing.codex.prepare = { await gate.wait(); return true }
            changing.tapContinue()
            let pending = changing.continueTask!
            await waitFor(gate)
            changing.tab = .claude
            gate.release(); await pending.value
            check(changing.advances == 0, "Tab change during preparation advanced")
        }

        let signing = OnboardingFixture()
        let loginGate = Gate()
        signing.codex.refresh = { await loginGate.wait() }
        signing.tapContinue(); let signingTask = signing.continueTask!
        await waitFor(loginGate)
        signing.tab = .claude; signing.backendRaw = "claude"
        loginGate.release(); await signingTask.value
        check(signing.advances == 0, "Provider change during login refresh advanced")

        for observe in [true, false] {
            let custom = OnboardingFixture()
            custom.backendRaw = "custom"; custom.tab = .openRouter
            custom.observesChanges = observe
            let gate = Gate()
            custom.codex.prepare = { await gate.wait(); return true }
            custom.tapContinue(); let pending = custom.continueTask!
            await waitFor(gate)
            custom.presetRaw = "lmstudio"
            gate.release(); await pending.value
            check(custom.advances == 0, "Changing the saved custom preset during preparation advanced")
        }

        let leaving = OnboardingFixture()
        let leaveGate = Gate()
        leaving.codex.prepare = { await leaveGate.wait(); return true }
        leaving.tapContinue(); let leavingTask = leaving.continueTask!
        await waitFor(leaveGate)
        leaving.disappear(); leaveGate.release(); await leavingTask.value
        check(leaving.advances == 0 && leaving.continueAttempt == nil, "Leaving onboarding advanced later")

        // A canceled attempt can finish after a retry starts. Its defer must not
        // retire the retry or permit the old attempt to navigate.
        let retry = OnboardingFixture()
        let firstGate = Gate(); let secondGate = Gate()
        retry.codex.prepare = { await firstGate.wait(); return true }
        retry.tapContinue(); let firstTask = retry.continueTask!
        await waitFor(firstGate)
        retry.tab = .claude; retry.tab = .chatgpt
        retry.codex.prepare = { await secondGate.wait(); return true }
        retry.tapContinue(); let secondTask = retry.continueTask!; let secondID = retry.continueAttempt
        await waitFor(secondGate)
        firstGate.release(); await firstTask.value
        check(retry.continueAttempt == secondID && retry.advances == 0, "Old attempt retired the retry")
        secondGate.release(); await secondTask.value
        check(retry.advances == 1 && retry.continueAttempt == nil, "Retry did not advance exactly once")

        // Default provider lookup uses the real TaskLocal override, never a
        // write to the developer's persisted model.backend preference.
        for backend in [ModelBackend.chatgpt, .claude] {
            ModelBackend.$runOverride.withValue(backend) {
                let expectedHost = backend == .claude ? "claude.ai" : "chatgpt.com"
                for slug in ["gmail", "google-calendar", "google-drive", "slack", "outlook-mail", "outlook-email", "outlook-calendar", "unknown-app"] {
                    let url = ConnectorLinks.page(for: slug)
                    check(url.host == expectedHost, "Connector routed to the wrong provider: \(slug)")
                    check(url == ConnectorLinks.page(for: slug, backend: backend), "Default and explicit routing diverged")
                }
                check(ConnectorLinks.directory().host == expectedHost, "Directory routed to the wrong provider")
            }
        }
        print("PASS: \(checks) onboarding selection, cancellation, retry, and connector routing checks")
    }
}
'''.replace("__METHODS__", methods)

with tempfile.TemporaryDirectory(prefix="sentient-onboarding-provider-tests-") as directory:
    directory = Path(directory)
    source = directory / "ProviderSelectionTests.swift"
    source.write_text("import Foundation\n" + production + fixture)
    executable = directory / "tests"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
