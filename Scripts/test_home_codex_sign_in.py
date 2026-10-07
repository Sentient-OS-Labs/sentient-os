#!/usr/bin/env python3
"""Exercise exact Home/sheet decisions with controlled, memory-only setup services.

This checks the UI boundary, including delayed status/login completions. It never runs
Codex, opens a browser, reads an account, or writes UserDefaults. SwiftUI presentation
hooks are checked in source; rendering and the real setup engine are separate checks.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    index = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[start:index]


home = (ROOT / "Views/HomeView.swift").read_text()
sheet = (ROOT / "Views/ChatGPTSignInSheet.swift").read_text()
assert ".task(id: canCheckCodexSignIn)" in home
assert "Task { await refreshCodexSignIn() }" in home
assert ".sheet(isPresented: $showCodexSignIn, onDismiss:" in home
assert ".onChange(of: codex.loggedIn)" in sheet
assert ".onChange(of: backendRaw)" in sheet
assert ".onDisappear { cancelOwnedLogin() }" in sheet
assert ".task(id: codex.loggingIn)" in sheet
assert "NSWorkspace" not in sheet and "CodexCLI" not in sheet
home_members = "\n".join(declaration(home, item) for item in [
    "private var canCheckCodexSignIn:", "private var needsCodexSignIn:",
    "private var canOfferCodexSignIn:", "private func refreshCodexSignIn()",
    "private func offerCodexSignInIfNeeded()", "private func presentCodexSignIn()",
])
sheet_members = "\n".join(declaration(sheet, item) for item in [
    "private var busy:", "private func signIn()", "private func cancelOwnedLogin()",
])

source = r'''
import Foundation

enum ModelBackend: String { case chatgpt, claude, custom; @MainActor static var current: Self = .chatgpt }
enum Deck { case real, demo }
@MainActor final class AppState {
    var hasCompletedOnboarding = true
    var isUninstalling = false
    var hasOfferedCodexSignIn = false
}
@MainActor final class ComputerSetup { var isInstalling = false }
@MainActor final class NSApplication {
    static let shared = NSApplication()
    var isActive = true
}
@MainActor final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class Setup {
    var installed = true, preparing = false, installing = false
    var loggedIn = false, loggingIn = false, loginStatusChecked = false
    var refreshes = 0, starts = 0
    var refreshGate: Gate?, startGate: Gate?
    var returnsAttempt = true
    var currentAttempt: UUID?
    var cancelled: [UUID] = []
    func refreshLoginStatus() async {
        refreshes += 1
        if let refreshGate { await refreshGate.wait() }
        loginStatusChecked = true
    }
    func startLogin() async -> UUID? {
        starts += 1
        if let startGate { await startGate.wait() }
        guard returnsAttempt else { return nil }
        let token = UUID()
        currentAttempt = token
        loggingIn = true
        return token
    }
    func cancelLogin(ifAttempt attempt: UUID) async {
        guard attempt == currentAttempt else { return }
        cancelled.append(attempt)
        currentAttempt = nil
        loggingIn = false
        loginStatusChecked = false
    }
}
@MainActor final class HomeFixture {
    let appState: AppState
    let codex = Setup()
    let computerSetup = ComputerSetup()
    var isPresented = true, deck = Deck.real
    var backendRaw = ModelBackend.chatgpt.rawValue
    var letterShown = false, showAnalysis = false, showShareKnowledge = false
    var showWhatsAppPicker = false, showIMessagePicker = false
    var showGmailConnect = false, showCalendarConnect = false, showCodexSignIn = false
    init(_ appState: AppState = AppState()) { self.appState = appState }
    var canCheck: Bool { canCheckCodexSignIn }
    var needs: Bool { needsCodexSignIn }
    var canOffer: Bool { canOfferCodexSignIn }
    func refresh() async { await refreshCodexSignIn() }
    func offer() { offerCodexSignInIfNeeded() }
    func open() { presentCodexSignIn() }
    __HOME__
}
@MainActor final class SheetFixture {
    let codex = Setup()
    var startTask: Task<Void, Never>?
    var startID = UUID()
    var ownedLoginAttempt: UUID?
    var dismissals = 0
    func dismiss() { dismissals += 1 }
    func tap() { signIn() }
    func close() { cancelOwnedLogin() }
    __SHEET__
}
@main struct Checks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label); count += 1
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out waiting for fixture task")
    }
    @MainActor static func settle() async { for _ in 0..<10 { await Task.yield() } }
    @MainActor static func main() async {
        let home = HomeFixture()
        check(home.canCheck && !home.needs && !home.canOffer, "unknown private status never prompts")
        await home.refresh()
        check(home.needs && home.showCodexSignIn && home.appState.hasOfferedCodexSignIn,
              "checked signed-out private profile offers once")
        home.showCodexSignIn = false
        await home.refresh()
        home.offer()
        check(!home.showCodexSignIn, "dismissal survives reactivation and repeat checks")
        let reopened = HomeFixture(home.appState)
        await reopened.refresh()
        check(!reopened.showCodexSignIn, "session latch survives window remount")
        reopened.open()
        check(reopened.showCodexSignIn, "explicit Sign in can reopen")
        reopened.showCodexSignIn = false
        reopened.codex.loggedIn = true
        reopened.open()
        check(!reopened.needs && !reopened.showCodexSignIn, "signed-in account needs no offer")

        let unavailable: [(String, (HomeFixture) -> Void)] = [
            ("onboarding", { $0.appState.hasCompletedOnboarding = false }),
            ("teardown", { $0.appState.isUninstalling = true }),
            ("hidden home", { $0.isPresented = false }),
            ("demo", { $0.deck = .demo }),
            ("Claude", { $0.backendRaw = ModelBackend.claude.rawValue }),
            ("custom", { $0.backendRaw = ModelBackend.custom.rawValue }),
            ("missing CLI", { $0.codex.installed = false }),
            ("preparing CLI", { $0.codex.preparing = true }),
            ("installing CLI", { $0.codex.installing = true }),
        ]
        for (name, configure) in unavailable {
            let h = HomeFixture(); configure(h)
            await h.refresh(); h.offer(); h.open()
            check(!h.canCheck && h.codex.refreshes == 0, name + " does not probe")
            check(!h.showCodexSignIn && !h.appState.hasOfferedCodexSignIn, name + " does not prompt")
        }
        let helperInstalling = HomeFixture(); helperInstalling.computerSetup.isInstalling = true
        await helperInstalling.refresh()
        check(helperInstalling.showCodexSignIn, "independent helper download does not delay private sign-in")
        for flag in [\HomeFixture.letterShown, \.showAnalysis, \.showShareKnowledge,
                     \.showWhatsAppPicker, \.showIMessagePicker, \.showGmailConnect, \.showCalendarConnect] {
            let h = HomeFixture(); h[keyPath: flag] = true
            await h.refresh()
            check(!h.showCodexSignIn && !h.appState.hasOfferedCodexSignIn, "other sheet defers offer")
            h[keyPath: flag] = false; h.offer()
            check(h.showCodexSignIn, "offer resumes when home is free")
        }
        let inactive = HomeFixture(); NSApplication.shared.isActive = false
        await inactive.refresh()
        check(!inactive.showCodexSignIn && !inactive.appState.hasOfferedCodexSignIn, "inactive app stays quiet")
        NSApplication.shared.isActive = true; inactive.offer()
        check(inactive.showCodexSignIn, "activation can offer after prior quiet check")
        for change in [0, 1, 2] {
            let h = HomeFixture(), gate = Gate(); h.codex.refreshGate = gate
            let task = Task { await h.refresh() }
            await until { gate.continuation != nil }
            if change == 0 { h.backendRaw = ModelBackend.claude.rawValue }
            if change == 1 { h.appState.isUninstalling = true }
            if change == 2 { task.cancel() }
            gate.release(); await task.value
            check(!h.showCodexSignIn && !h.appState.hasOfferedCodexSignIn, "stale/cancelled status never presents")
        }

        let sheet = SheetFixture()
        sheet.tap(); await sheet.startTask?.value
        check(sheet.codex.starts == 1 && sheet.ownedLoginAttempt != nil, "button owns returned attempt")
        check(sheet.dismissals == 0, "starting browser login does not dismiss")
        sheet.close(); await until { sheet.codex.cancelled.count == 1 }
        await settle()
        check(sheet.ownedLoginAttempt == nil && !sheet.codex.loggingIn, "closing cancels owned callback")
        check(sheet.codex.loginStatusChecked, "closing refreshes private readiness")
        let elsewhere = SheetFixture(); let external = UUID()
        elsewhere.codex.currentAttempt = external; elsewhere.codex.loggingIn = true
        elsewhere.close(); await settle()
        check(elsewhere.codex.currentAttempt == external && elsewhere.codex.cancelled.isEmpty,
              "closing a passive sheet leaves Settings login alone")
        let replaced = SheetFixture(); replaced.tap(); await replaced.startTask?.value
        replaced.codex.currentAttempt = external; replaced.close(); await settle()
        check(replaced.codex.currentAttempt == external && replaced.codex.cancelled.isEmpty,
              "late cleanup cannot cancel replacement Settings login")
        let completed = SheetFixture(); completed.tap(); await completed.startTask?.value
        completed.codex.loggedIn = true; completed.close(); await settle()
        check(completed.codex.cancelled.isEmpty && completed.codex.loggedIn, "successful login survives dismissal")

        for mode in [0, 1] {
            ModelBackend.current = .chatgpt
            let s = SheetFixture(), gate = Gate(); s.codex.startGate = gate
            s.tap(); let task = s.startTask
            await until { gate.continuation != nil }
            if mode == 1 { ModelBackend.current = .claude }
            s.close(); gate.release(); await task?.value
            check(s.ownedLoginAttempt == nil && s.dismissals == 0, "late start cannot mutate dismissed sheet")
            check(s.codex.cancelled.count == 1, "late returned token cancels only its own callback")
        }
        ModelBackend.current = .claude
        let otherBackend = SheetFixture(); otherBackend.tap(); await settle()
        check(otherBackend.codex.starts == 0, "provider switch prevents starting login")
        ModelBackend.current = .chatgpt
        let busy = SheetFixture(); busy.codex.preparing = true; busy.tap(); await settle()
        check(busy.codex.starts == 0, "setup in progress prevents login start")
        let failed = SheetFixture(); failed.codex.returnsAttempt = false
        failed.tap(); await failed.startTask?.value; failed.close(); await settle()
        check(failed.ownedLoginAttempt == nil && failed.codex.cancelled.isEmpty, "no owned token after failure")
        let retry = SheetFixture(), oldGate = Gate(), newGate = Gate()
        retry.codex.startGate = oldGate; retry.tap(); let oldTask = retry.startTask
        await until { oldGate.continuation != nil }
        retry.close(); retry.codex.startGate = newGate; retry.tap()
        await until { newGate.continuation != nil }
        oldGate.release(); await oldTask?.value
        check(retry.startTask != nil && retry.ownedLoginAttempt == nil,
              "cancelled attempt cannot clear the replacement task handle")
        newGate.release(); await retry.startTask?.value
        check(retry.ownedLoginAttempt == retry.codex.currentAttempt && retry.ownedLoginAttempt != nil,
              "replacement request owns only its own returned token")
        print("PASS: \(count) home private-login readiness and ownership checks")
    }
}
'''.replace("__HOME__", home_members).replace("__SHEET__", sheet_members)

with tempfile.TemporaryDirectory(prefix="sentient-home-sign-in-tests-") as folder:
    path = Path(folder) / "Checks.swift"
    path.write_text(source)
    executable = Path(folder) / "checks"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
