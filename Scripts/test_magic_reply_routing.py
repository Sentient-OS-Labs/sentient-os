#!/usr/bin/env python3
"""Exercise production Magic Reply routing and drafting with inert capture, API and paste."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def method(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


FIXTURE = r'''
import Foundation
typealias CGDirectDisplayID = UInt32
enum TriggerSource { case notchTyped, voice; var rawValue: String { String(describing: self) } }
enum NotchPhase { case hidden, typing }
struct ShortcutActivity: Equatable { var revision = 0; static var current = Self() }
struct Application { var processIdentifier: pid_t = 42 }
final class NSWorkspace { static let shared = NSWorkspace(); var frontmostApplication: Application? = Application() }
enum Permissions { static func hasAccessibility() -> Bool { true } }
enum SidekickDiscovery { static func recordNotchUse() {} }
struct Pair { mutating func reset() {} }
final class Recovery { var isPending = false }
final class Run { var isRunning = false, isClearingChat = false; let recovery = Recovery() }
final class Proofread { var isRunning = false; func clearPreparedSelection() {} }
enum ScreenCapture {
    static func summaryDisplay() -> CGDirectDisplayID? { 42 }
    static var captures = 0
    static var beforeCapture: (() -> Void)?
    static var lastDisplay: CGDirectDisplayID?
    static func grabDisplayUnderCursor(displayID: CGDirectDisplayID?) async -> Int? { beforeCapture?(); lastDisplay = displayID; captures += 1; return 1 }
    static func discard(_ shots: [Int]) {}
    static func downscaledJPEG(_ shot: Int, maxLongEdge: Int) -> Data? { Data() }
}
enum CaretLocator {
    enum Source: String { case fixture }
    struct Target { let source = Source.fixture }
    static func locate() -> Target { Target() }
}
final class CaretSwirl {
    static let landingDelay = Duration.milliseconds(1)
    var starts = 0, lands = 0
    func begin(at target: CaretLocator.Target) { starts += 1 }
    func land() { lands += 1 }
}
enum ReplyPaste {
    static var texts: [String] = []
    static func insert(_ text: String) async -> Bool { texts.append(text); return true }
}
enum VaultGenerator { static let vaultRoot = URL(fileURLWithPath: "/fixture") }
enum Diagnostics {
    enum Phase: String { case capture, encode, request, paste, stream }
    enum Event { case doubleTapFailed }
    static func step(_ phase: Phase) {}
    static func report(_ event: Event, phase: Phase, reason: String, source: String) {}
    static func report(_ event: Event, phase: Phase, error: Error, source: String, terminal: Bool) {}
    static func errorFields(_ error: Error) -> [String: String] { [:] }
}
enum DiagnosticHistory {
    static func doubleTapTiming(id: UUID, model: String, measurements: [String: Int]) {}
}
func Log(_ text: String) {}
func ErrorLabel(_ error: Error) -> String { String(describing: error) }
enum DoubleTapInference {
    static var configurationProblem: String?
    enum Failure: Error {
        case cancelled, noKey, invalidModel, invalidEndpoint, instructionsTooLarge, noVault
        case noWritingStyle, writingStyleTooLarge, relay, http(Int, Int), api(String)
        var diagnosticReason: String { "fixture" }; var label: String { "fixture failure" }
    }
    enum Verdict: Equatable { case notAMessage, reply(String) }
    struct Timing {
        var total = 0.01, firstToken: Double? = 0.001
        var inputTokens: Int? = 1, cachedTokens: Int? = 0, cacheWriteTokens: Int? = 0
        var outputTokens: Int? = 1, reasoningTokens: Int? = 0
    }
    struct Outcome { let timing = Timing(); let model = "fixture"; var verdict: Verdict }
    static var verdict = Verdict.reply("A personal reply")
    static var requests = 0
    static var lastPreference = ""
    static var duringRequest: (() -> Void)?
    static func draft(screenshot: Data, vault: URL, preference: String = "") async throws -> Outcome {
        requests += 1; lastPreference = preference; duringRequest?(); return Outcome(verdict: verdict)
    }
}
final class DoubleTap {
    static let shared = DoubleTap(), screenshotLongEdge = 2000
    enum Result { case pasted, notAMessage, stopped, failed(String) }
    var isDrafting = false, starts = 0
    var lastReport: String?, diagnosticReason: String?, activeRunID: UUID?
    var phase = Diagnostics.Phase.capture
    let swirl = CaretSwirl()
    var task: Task<Void, Never>?
    func start(displayID: CGDirectDisplayID? = nil, preference: String = "",
               completion: @escaping @MainActor (Result) -> Void) {
        starts += 1; isDrafting = true
        task = Task {
            let result = await perform(displayID: displayID, preference: preference)
            isDrafting = false; completion(result)
        }
    }
    // PERFORM
}
final class Coordinator {
    let run = Run(), proofread = Proofread()
    var quickActionsAvailable = true, notchInputReady = true, voiceSessionID: UUID?
    var pendingSingleTap: Task<Void, Never>?
    var relinquishNotchFocus: (() -> Void)?
    var summaryDisplayID: CGDirectDisplayID? = 7
    var hotkeyPair = Pair(), phase = NotchPhase.typing, phaseToken = UUID()
    var notices: [String] = []
    func clearReadBack() {}
    func setPhase(_ value: NotchPhase) { phase = value; phaseToken = UUID() }
    func flash(_ value: String, for duration: Double) { notices.append(value) }
    // No agent-launch API is available to this route.
    // MAGIC_REPLY
}
@main enum Tests {
    static func main() async {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let engine = DoubleTap.shared
        var notchOwnsKeyboard = false
        var releases = 0
        ScreenCapture.beforeCapture = { check(!notchOwnsKeyboard, "focus returns before screenshot") }
        for source in [TriggerSource.notchTyped, .voice] {
            for _ in 0..<10 {
                let coordinator = Coordinator()
                coordinator.notchInputReady = false // Proofread capture must not block Magic Reply.
                notchOwnsKeyboard = true
                coordinator.relinquishNotchFocus = {
                    check(coordinator.phase == .hidden, "notch retracts before focus release")
                    notchOwnsKeyboard = false
                    releases += 1
                    ShortcutActivity.current.revision += 1
                }
                DoubleTapInference.duringRequest = {
                    // Input counters and macOS activation can change during the handoff.
                    ShortcutActivity.current.revision += 1
                    NSWorkspace.shared.frontmostApplication = Application(processIdentifier: 99)
                }
                let pastes = ReplyPaste.texts.count, swirls = engine.swirl.starts
                check(coordinator.magicReply(source: source), "Magic Reply admits immediate click")
                await engine.task?.value
                check(ReplyPaste.texts.count == pastes + 1, "every notch action pastes exactly once")
                check(engine.swirl.starts == swirls + 1 && engine.swirl.lands == swirls + 1,
                      "every notch action gathers and lands")
                check(ScreenCapture.lastDisplay == 7, "notch uses the originating display")
                check(coordinator.notices.isEmpty, "successful action has no failure notice")
                let requests = DoubleTapInference.requests
                engine.start { _ in }
                await engine.task?.value
                check(DoubleTapInference.requests == requests + 1 && ReplyPaste.texts.count == pastes + 2,
                      "keyboard and notch share behavior under identical input changes")
            }
        }
        check(releases == 20, "each notch invocation releases focus exactly once")
        DoubleTapInference.duringRequest = nil
        let pastes = ReplyPaste.texts.count
        DoubleTapInference.verdict = .notAMessage
        let nonMessage = Coordinator()
        check(nonMessage.magicReply(), "non-message enters direct classifier")
        await engine.task?.value
        check(nonMessage.notices.isEmpty, "non-message uses shared pointer feedback without a second notch notice")
        check(ReplyPaste.texts.count == pastes, "non-message has no paste")
        DoubleTapInference.verdict = .reply("A personal reply")
        let directed = Coordinator()
        let preference = "Reply saying I’m available tomorrow at 3 PM."
        check(directed.magicReply(preference: preference), "directed reply is admitted")
        await engine.task?.value
        check(DoubleTapInference.lastPreference == preference, "specific wording reaches inference intact")
        check(directed.magicReply(), "ordinary reply after a directed reply is admitted")
        await engine.task?.value
        check(DoubleTapInference.lastPreference.isEmpty, "reply guidance never leaks into the next request")
        let busy = Coordinator(); busy.run.isRunning = true
        check(!busy.magicReply(), "button preserves active-task admission")
        DoubleTapInference.configurationProblem = "Provider setup required"
        let unconfigured = Coordinator()
        check(unconfigured.magicReply(), "configuration failure stays in direct flow")
        await engine.task?.value
        check(unconfigured.notices == ["Provider setup required"], "configuration error uses local feedback")
        print("PASS: \(checks) Magic Reply direct-routing, swirl, inference and focus checks")
    }
}
'''

coordinator = (APP / "Notch Magic/CommandCoordinator.swift").read_text()
double_tap = (APP / "Double Tap/DoubleTap.swift").read_text()
fixture = FIXTURE.replace("// MAGIC_REPLY", method(coordinator, "    func magicReply("))
fixture = fixture.replace("// PERFORM", method(double_tap, "    private func perform("))
with tempfile.TemporaryDirectory(prefix="sentient-magic-reply-") as directory:
    root = Path(directory)
    source = root / "Routing.swift"
    source.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-parse-as-library", str(source), "-o", str(root / "test")], check=True, timeout=60)
    subprocess.run([str(root / "test")], check=True, timeout=15)
