#!/usr/bin/env python3
"""Compile the production Home health ladder against in-memory synthetic capabilities.

No app launch, system grants, real preferences, source reads, helper or provider calls.
The local UserDefaults stand-in deliberately shadows Foundation's persistent store.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEALTH = ROOT / "Sentient OS macOS/System/HealthCaution.swift"

STUBS = r'''
import Foundation
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Bool] = [:]
    var plan = ProcessingPlan.Record()
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}
@MainActor enum ProtectedLocalSource: String {
    case whatsapp, imessage, notes, mail
    static var reads: [Self] = []
    static var readable: Set<Self> = []
    var title: String {
        switch self { case .whatsapp: "WhatsApp"; case .imessage: "iMessage"; case .notes: "Apple Notes"; case .mail: "Apple Mail" }
    }
    var isReadable: Bool { Self.reads.append(self); return Self.readable.contains(self) }
}
@MainActor enum SourceSelection { static var selectedProtectedSources: [ProtectedLocalSource] = [] }
@MainActor enum SourceHealth {
    static var statuses: [String: String] = [:]
    static func readStatuses() -> [String: String] { statuses }
}
@MainActor enum PersonalSetupProgress {
    static var complete = false
    static func isComplete() -> Bool { complete }
}
@MainActor enum OvernightScheduler {
    static let enabledKey = "test.scheduler.enabled"
    static let prodEnabledKey = "test.scheduler.production"
}
@MainActor enum ProcessingPlan {
    enum Status { case idle, scheduled, paused, completed }
    struct Record { var status: Status = .idle }
    static func read(_ defaults: UserDefaults) -> Record { defaults.plan }
}
@MainActor final class WakeHelperClient {
    static let shared = WakeHelperClient()
    var checks = 0
    func isReachable() async -> Bool { checks += 1; return false }
}
@MainActor enum LoginItem {
    static var checks = 0
    static var isEnabled: Bool { checks += 1; return false }
}
enum Permissions { enum AutomationState { case granted, notAsked, denied, unavailable } }
enum NativePermissionReadiness {
    enum State { case unknown, verified, denied }
    struct Snapshot { var accessibility: State = .unknown; var screenRecording: State = .unknown }
}
@MainActor enum CodexAuth { static var knowledgeBaseOnly = false }
enum ModelBackend { case chatgpt, claude, custom; static var current = Self.chatgpt }
@MainActor enum ComputerUseBackend {
    case openAI, cua
    static var current = Self.openAI
    var isInstalled: Bool { true }
}
@MainActor enum CodexCLI {
    static func locateBinary() -> String? { "/synthetic/codex" }
    static func loginStatus() async -> Bool { true }
}
@MainActor enum ClaudeCLI {
    static func locateBinary() -> String? { "/synthetic/claude" }
    static func loginStatus() async -> Bool { true }
}
@MainActor final class CodexSetup { static let shared = CodexSetup(); var outdated = false }
@MainActor final class ComputerUseSetup {
    enum Notice { case hidden, updating }
    static let current = ComputerUseSetup()
    var ready = true
    var isInstalling = false
    var updateNotice = Notice.hidden
}
@MainActor final class ComputerUseUpgrade { static let shared = ComputerUseUpgrade(); var isPresenting = false }
@MainActor final class ComputerUseGate {
    static let shared = ComputerUseGate()
    var allRequiredGranted = false
    var sentientScreen = true
    var sentientAccessibility = true
    var automation = Permissions.AutomationState.granted
    var helperPermissionState = NativePermissionReadiness.Snapshot()
    func refresh() {}
    func awaitAutomationRefresh() async {}
    // No method that can request a grant or launch a synthetic proof exists in this fixture.
}
'''

CHECKS = r'''
@main struct HealthRequirementsTest {
    @MainActor static func main() async {
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); print("PASS " + label) }
        func reset() {
            UserDefaults.standard.values = [:]
            UserDefaults.standard.plan = .init()
            SourceSelection.selectedProtectedSources = []
            SourceHealth.statuses = [:]
            PersonalSetupProgress.complete = false
            ProtectedLocalSource.reads = []; ProtectedLocalSource.readable = []
            WakeHelperClient.shared.checks = 0; LoginItem.checks = 0
            ComputerUseGate.shared.helperPermissionState = .init()
            ComputerUseGate.shared.sentientScreen = true
            ComputerUseGate.shared.automation = .granted
        }
        func permissionIssue(_ issue: HealthCaution.Issue?, equals expected: [HealthCaution.EssentialPermission]) -> Bool {
            guard case .permissions(let values) = issue else { return false }
            return values == expected
        }
        reset()
        let fresh = await HealthCaution.probe()
        check(fresh == nil && ProtectedLocalSource.reads.isEmpty && WakeHelperClient.shared.checks == 0 && LoginItem.checks == 0,
              "fresh Home never checks unchosen protected sources or overnight capabilities")
        SourceSelection.selectedProtectedSources = [.notes]
        check(await HealthCaution.probe() == nil && ProtectedLocalSource.reads.isEmpty,
              "unfinished source selection does not create a permission regression")
        reset(); PersonalSetupProgress.complete = true
        check(await HealthCaution.probe() == nil && ProtectedLocalSource.reads.isEmpty,
              "cloud-only completed setup never requires Full Disk Access")
        SourceSelection.selectedProtectedSources = [.notes]
        let lostNotes = await HealthCaution.probe()
        check(permissionIssue(lostNotes, equals: [.protectedSources(["Apple Notes"])]) && ProtectedLocalSource.reads == [.notes],
              "selected protected source loss checks only that source and names it")
        check(lostNotes?.message.contains("other sources remain available") == true,
              "source access failure never claims all reading is blocked")
        ProtectedLocalSource.readable = [.notes]
        check(await HealthCaution.probe() == nil, "selected readable source needs no broad FDA grant")
        reset(); SourceSelection.selectedProtectedSources = [.mail]; SourceHealth.statuses = ["apple_mail": "ok"]
        check(permissionIssue(await HealthCaution.probe(), equals: [.protectedSources(["Apple Mail"])]),
              "known working selected source reports drift before a setup milestone")
        SourceSelection.selectedProtectedSources = []; ProtectedLocalSource.reads = []
        check(await HealthCaution.probe() == nil && ProtectedLocalSource.reads.isEmpty,
              "deselected sources never produce stale warnings or reads")
        reset(); UserDefaults.standard.set(false, forKey: OvernightScheduler.prodEnabledKey)
        check(await HealthCaution.probe() == nil && WakeHelperClient.shared.checks == 0 && LoginItem.checks == 0,
              "explicit overnight off skips wake and launch-at-login checks")
        UserDefaults.standard.set(true, forKey: OvernightScheduler.prodEnabledKey)
        check(permissionIssue(await HealthCaution.probe(), equals: [.overnightWake, .launchAtLogin]),
              "explicit overnight on checks required background capabilities")
        reset(); UserDefaults.standard.plan.status = .scheduled
        check(permissionIssue(await HealthCaution.probe(), equals: [.overnightWake, .launchAtLogin]),
              "pending scheduled intent requires wake and launch at login")
        reset(); UserDefaults.standard.plan.status = .paused
        check(await HealthCaution.probe() == nil && WakeHelperClient.shared.checks == 0,
              "paused plan alone does not invent an active overnight schedule")
        reset(); UserDefaults.standard.set(true, forKey: HealthCaution.nativeComputerUseEverReadyKey)
        for automation in [Permissions.AutomationState.granted, .notAsked, .unavailable] {
            ComputerUseGate.shared.automation = automation
            check(await HealthCaution.probe() == nil, "unknown native proof remains unknown with \(automation)")
        }
        ComputerUseGate.shared.automation = .granted
        ComputerUseGate.shared.helperPermissionState.screenRecording = .denied
        if case .computerUseBroken(payloadGone: false) = await HealthCaution.probe() {
            check(true, "confirmed helper capture denial reports a real regression")
        } else { check(false, "confirmed helper capture denial must report") }
        ComputerUseGate.shared.helperPermissionState = .init()
        ComputerUseGate.shared.automation = .denied
        if case .computerUseBroken(payloadGone: false) = await HealthCaution.probe() {
            check(true, "confirmed Automation denial reports regression despite unknown helper proof")
        } else { check(false, "confirmed Automation denial must report") }
        ComputerUseGate.shared.automation = .granted
        ComputerUseGate.shared.sentientScreen = false
        if case .computerUseBroken(payloadGone: false) = await HealthCaution.probe() {
            check(true, "lost Sentient capture grant reports regression despite unknown helper proof")
        } else { check(false, "lost Sentient capture grant must report") }
        reset(); ComputerUseGate.shared.helperPermissionState.screenRecording = .denied
        check(await HealthCaution.probe() == nil, "never-ready computer use is first-use setup, not a Home regression")
        check(HealthCaution.Issue.codexSignedOut.message.contains("Sidekick")
              && HealthCaution.Issue.claudeSignedOut.message.contains("Sidekick"), "auth repair copy includes current Sidekick use")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-health-requirements-") as directory:
        root = Path(directory)
        (root / "Stubs.swift").write_text(STUBS)
        (root / "Checks.swift").write_text(CHECKS)
        binary = root / "health-tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(root / "Stubs.swift"),
                        str(HEALTH), str(root / "Checks.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
