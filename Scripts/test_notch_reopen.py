#!/usr/bin/env python3
"""Exercise production phase application with late selection results and rapid reopens."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Sentient OS macOS/Notch Magic/NotchWindowController.swift').read_text()
start = source.index('    private func applyPhase()')
end = source.index('    /// Show the panel', start)
apply_phase = source[start:end].replace('private func applyPhase', 'func applyPhase', 1)
r_start = source.index('    private func reposition()')
r_end = source.index('    deinit {', r_start)
release_start = source.index('    private func relinquishKeyboardFocus()')
release_end = source.index('\n    #if DEBUG', release_start)
release_focus = source[release_start:release_end]
reposition = source[r_start:r_end].replace('private func reposition', 'func reposition', 1)

coordinator_source = (ROOT / 'Sentient OS macOS/Notch Magic/CommandCoordinator.swift').read_text()
summary_start = coordinator_source.index('    func summarizeScreen(')
summary_end = coordinator_source.index('{', summary_start) + 1
summary_depth = 1
while summary_depth:
    summary_depth += (coordinator_source[summary_end] == '{') - (coordinator_source[summary_end] == '}')
    summary_end += 1
summarize_screen = coordinator_source[summary_start:summary_end]
phase_start = coordinator_source.index('enum NotchPhase: Equatable {')
phase_end = coordinator_source.index('\n}', phase_start) + 2
phase_source = coordinator_source[phase_start:phase_end].replace('NotchPhase', 'Phase')
fixture = r'''
import AppKit

enum CommandRunModel { enum Outcome: Equatable { case success, stopped, failed } }
// PHASE
final class Proofread {
 var captureWasInterrupted = false; var isRunning = false
 func clearPreparedSelection() { captureWasInterrupted = false }
}
struct Pair { mutating func reset() {} }
enum ScreenCapture { static func summaryDisplay() -> UInt32? { 1 } }
enum SummaryAccessibility {
 enum Failure: LocalizedError { case ownApplication; var errorDescription: String? { "Switch to another app to summarize it." } }
 static func target() -> Int? { 1 }
}
extension Int { var pid: pid_t { pid_t(self) } }
final class Summaries {
 var starts = 0
 func start(displayID: UInt32, preference: String, target: Int?) { starts += 1 }
}
final class Coordinator {
 var homeWindowFocused = false
 var notchDismissalPreview = false
 var displayedNotchPhase: Phase { phase.displayed(homeFocused: homeWindowFocused) }
 var phase = Phase.hidden
 let proofread = Proofread()
 var dismissals = 0
 let run = Run()
 let summarize = Summaries()
 var quickActionsAvailable = true
 var voiceSessionID: UUID?
 var summaryDisplayID: UInt32? = 1
 var summaryTarget: Int? = 1
 var pendingSingleTap: Task<Void,Never>?
 var hotkeyPair = Pair()
 func clearReadBack() {}
 func setPhase(_ phase: Phase) { self.phase = phase }
 func flash(_ text: String, for seconds: Double = 1.5) {}
 // SUMMARIZE_SCREEN
 func dismissTyping() { dismissals += 1; phase = .hidden }
}
final class Run { let recovery = Recovery(); var isClearingChat = false, isRunning = false }
final class Recovery { func setFocused(_ value: Bool) {} }
final class Panel {
 var isVisible = true, isKeyWindow = true, ignoresMouseEvents = false
 var ordersOut = 0
 func resignKey() { isKeyWindow = false }
 func orderOut(_ sender: Any?) { isVisible = false; isKeyWindow = false; ordersOut += 1 }
 func orderFrontRegardless() { isVisible = true }
}
struct Metrics { var hasHardwareCutout = false }
struct Entry { var backdrop: Int? }
final class Host { func update(metrics: Metrics, islandBackdrop: Int?, displayID: Int) {} }
final class Controller {
 let coordinator = Coordinator()
 var panel: Panel? = Panel()
 var host: Host? = Host()
 var metrics = Metrics()
 var restingBarAllowed = true
 func allowsRestingBar(on displayID:Int)->Bool { restingBarAllowed }
 var metricsDisplayID = 1
 var entryHandles: [Int: Entry] = [:]
 var sizeToken = 0, reveals = 0
 var hovering = false, entriesAvailable = true, wantsKey = true
 static let settleDelay = 0.01
 static func isInteractive(_ phase: Phase) -> Bool { phase != .hidden }
 func refreshHoverEntryRect() {}
 func syncEntryHandles() {}
 func clearHover() { hovering = false }
 func startMouseTracking() {}
 func stopMouseTracking() {}
 func placeCanvas() {}
 func activeScreen() -> Int? { 1 }
 func applyMetrics(for screen: Int) {}
 func endHover() { hovering = false }
 // REPOSITION
 func hoverMouseMoved(at point: NSPoint) {}
 func reveal(makeKey: Bool = false) { reveals += 1; panel?.isVisible = true; panel?.isKeyWindow = makeKey }
 // RELEASE_FOCUS
 // APPLY_PHASE
}
@main struct ReopenTests {
 static func main() async {
  var checks = 0
  func check(_ pass: Bool, _ label: String) { if !pass { print("FAIL: " + label); exit(1) }; checks += 1 }
  for hardware in [false,true] {
   let controller = Controller()
   controller.metrics.hasHardwareCutout = hardware
   controller.coordinator.phase = .typing
   controller.applyPhase()
   controller.coordinator.proofread.captureWasInterrupted = true
   controller.applyPhase()
   check(controller.coordinator.phase == .typing && controller.coordinator.dismissals == 0,
         "late interrupted selection must not dismiss the prompt")
   check(controller.panel?.isVisible == true && controller.panel?.isKeyWindow == true,
         "prompt remains visible and editable")
   for _ in 0..<30 {
    check(controller.coordinator.summarizeScreen(), "real Summarize action starts a summary")
    controller.applyPhase()
    controller.coordinator.phase = .typing
    controller.applyPhase()
    try? await Task.sleep(for:.milliseconds(15))
    check(controller.coordinator.phase == .typing && controller.panel?.isVisible == true,
          "previous dismissal cannot close a reopened panel")
   }
   check(controller.panel?.ordersOut == 30,"each summary releases focus once and old callbacks cannot order out a new prompt")
   check(controller.coordinator.summarize.starts == 30, "rapid reopening does not duplicate summary requests")
  }
  let focused = Controller()
  focused.coordinator.phase = .running
  focused.applyPhase()
  focused.coordinator.homeWindowFocused = true
  focused.applyPhase()
  check(focused.coordinator.displayedNotchPhase == .hidden && focused.coordinator.phase == .running,
        "Home focus hides presentation without stopping work")
  let beforeReposition = focused.reveals
  focused.reposition()
  check(focused.reveals == beforeReposition, "Space/display callbacks cannot reshow a Home-suppressed panel")
  focused.coordinator.homeWindowFocused = false
  focused.reposition()
  check(focused.reveals == beforeReposition + 1, "Space/display callbacks restore visible work when Home is unfocused")
  focused.applyPhase()
  try? await Task.sleep(for: .milliseconds(15))
  check(focused.coordinator.displayedNotchPhase == .running && focused.panel?.isVisible == true,
        "focus loss restores status and invalidates a pending retract")
  for phase in [Phase.running,.finishing(.success),.message,.recovery] {
   check(phase.displayed(homeFocused:true) == .hidden, "automatic status stays out of focused Home")
   check(phase.displayed(homeFocused:false) == phase, "unfocused Home exposes current status")
  }
  for phase in [Phase.typing,.listening,.transcribing] {
   check(phase.displayed(homeFocused:true) == phase,"explicit notch input remains usable")
  }
  let hoveredReply = Controller()
  hoveredReply.coordinator.phase = .typing
  hoveredReply.applyPhase()
  hoveredReply.hovering = true
  hoveredReply.coordinator.phase = .hidden
  hoveredReply.applyPhase()
  check(hoveredReply.panel?.isKeyWindow == false,
        "Magic Reply returns keyboard focus while the pointer remains over the notch")
  let external = Controller()
  external.metrics.hasHardwareCutout = false
  external.restingBarAllowed = false
  external.coordinator.phase = .hidden
  external.applyPhase()
  check(external.panel?.isVisible == false, "external resting bar hides when disabled")
  external.coordinator.phase = .typing
  external.applyPhase()
  check(external.panel?.isVisible == true, "explicit shortcut input opens with external bar disabled")
  external.coordinator.phase = .hidden
  external.coordinator.notchDismissalPreview = true
  external.applyPhase()
  check(external.panel?.isVisible == false, "disabled external bar does not linger as a dismissal preview")
  external.coordinator.notchDismissalPreview = false
  external.coordinator.phase = .running
  external.applyPhase()
  check(external.panel?.isVisible == true, "active task feedback remains visible")
  external.coordinator.phase = .hidden
  external.restingBarAllowed = true
  external.applyPhase()
  check(external.panel?.isVisible == true, "enabling the external resting bar restores it")
  print("PASS: \(checks) focus handoff, interrupted-selection and rapid-reopen checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-notch-reopen-') as temporary:
    path = Path(temporary)
    swift = path / 'test.swift'
    swift.write_text(fixture.replace('// REPOSITION', reposition).replace('// PHASE', phase_source).replace('// RELEASE_FOCUS', release_focus).replace('// APPLY_PHASE', apply_phase).replace('// SUMMARIZE_SCREEN', summarize_screen))
    binary = path / 'test'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',
                    '-default-isolation','MainActor',str(swift),'-o',str(binary)],check=True,timeout=45)
    subprocess.run([str(binary)],check=True,timeout=15)
