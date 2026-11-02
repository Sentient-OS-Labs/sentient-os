#!/usr/bin/env python3
"""Check production notch geometry and cursor hit testing with synthetic display state."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
view = (APP / "Notch Magic/NotchView.swift").read_text()
metrics = view[view.index("struct NotchMetrics:"):view.index("// MARK: - The reactive binder")]
glow_start = view.index("    private var glowStrength:")
glow_end = view.index("\n    ///", glow_start)
glow_strength = view[glow_start:glow_end].replace("private var", "var", 1)
settle_start = view.index("    private func settleReadingGlow()")
settle_end = view.index("\n    private var glowStrength:", settle_start)
settle_glow = view[settle_start:settle_end].replace("private func", "func", 1)
controller = (APP / "Notch Magic/NotchWindowController.swift").read_text()
start = controller.index("    private func cursorOverSilhouette(")
end = controller.index("\n    // MARK:", start)
hit_test = controller[start:end].replace("private func", "func", 1)

FIXTURE = r'''
import AppKit
import SwiftUI

enum NotchPhase: Equatable {
    enum Outcome { case success, failed, stopped }
    case hidden, opening, typing, listening, transcribing, running, recovery, message
    case finishing(Outcome), notice(String)
}
struct SidekickRecoveryContent {}
struct SidekickRecoveryLayout {
    var size = CGSize(width: 520, height: 240)
    init(content: SidekickRecoveryContent, metrics: NotchMetrics) {}
}
enum SidekickConversationStore { struct Record { var event = Event() }; struct Event { var text = "" } }
struct SidekickNotchMessageLayout {
    static let maximumHeight: CGFloat = 300
    var size: CGSize
    init(markdown: String, maximumSize: CGSize, cameraHeight: CGFloat, outerTopPad: CGFloat,
         outerBottomPad: CGFloat, horizontalPad: CGFloat) { size = maximumSize }
}
struct Recovery { var content: SidekickRecoveryContent? }
struct Run { var remembering: String?; var isPersonalizing = false; var recovery = Recovery() }
struct Coordinator {
    var phase = NotchPhase.running
    var readBack: String?
    var run = Run()
    var notchMessage: SidekickConversationStore.Record?
}
struct Screen { var frame = CGRect(x: 100, y: 50, width: 1440, height: 900) }
struct HitTest {
    var metrics: NotchMetrics
    var coordinator = Coordinator()
    var hovering = false
    func activeScreen() -> Screen? { Screen() }
    // HIT_TEST
}
final class GlowTest {
    let phase: NotchPhase
    var readingGlowID: String? = "message:fixture"
    var settledGlowID: String?
    var reduceMotion = false
    var lowPowerMode = false
    init(phase: NotchPhase) { self.phase = phase }
    // GLOW_STRENGTH
    // SETTLE_GLOW
}

@main struct Tests {
    static func main() async {
        var checks = 0
        func check(_ value: Bool, _ text: String) { precondition(value, text); checks += 1 }
        for phase in [NotchPhase.message, .recovery] {
            let glow = GlowTest(phase: phase)
            let arrivalStrength = glow.glowStrength
            await glow.settleReadingGlow()
            let readingStrength = glow.glowStrength
            check(readingStrength < arrivalStrength, "arrival glow settles for reading")
            await glow.settleReadingGlow()
            check(glow.glowStrength == readingStrength, "the same content does not replay its arrival")
            glow.readingGlowID = "message:next"
            check(glow.glowStrength == arrivalStrength, "new content has its own arrival glow")
            let pending = Task { await glow.settleReadingGlow() }
            await Task.yield()
            pending.cancel()
            await pending.value
            check(glow.settledGlowID == "message:fixture", "cancelled settling cannot modify a later presentation")
            glow.reduceMotion = true
            check(glow.glowStrength == readingStrength, "Reduce Motion uses steady reading glow")
            await glow.settleReadingGlow()
            glow.reduceMotion = false
            check(glow.glowStrength == readingStrength, "disabling Reduce Motion does not replay an old arrival")
            glow.readingGlowID = "message:low-power"
            glow.lowPowerMode = true
            check(glow.glowStrength == readingStrength, "Low Power Mode uses steady reading glow")
            await glow.settleReadingGlow()
            glow.lowPowerMode = false
            check(glow.glowStrength == readingStrength, "leaving Low Power Mode does not replay an old arrival")
            glow.readingGlowID = nil
            check(glow.glowStrength == readingStrength, "missing content identity does not glow indefinitely")
        }
        check(GlowTest(phase: .hidden).glowStrength == 0, "hidden notch has no glow")
        let regular = NotchMetrics(hardwareNotch: CGSize(width: 200, height: 32))
        var compact = regular; compact.compactMode = true
        check(compact.size(for: .running).height < regular.size(for: .running).height,
              "compact processing reduces vertical overlap")
        for phase in [NotchPhase.finishing(.success), .finishing(.stopped)] {
            check(compact.size(for: phase) == compact.size(for: .running), "completion keeps compact processing dimensions")
            check(compact.radii(for: phase) == compact.radii(for: .running)
                && compact.horizontalOffset(for: phase) == compact.horizontalOffset(for: .running),
                  "completion preserves the compact outline and camera alignment")
            check(compact.glowScale(for: phase) == compact.glowScale(for: .running)
                && compact.glowRotationPeriod(for: phase) == compact.glowRotationPeriod(for: .running),
                  "completion preserves the compact glow and color speed")
            check(!regular.isCompact(for: phase), "regular completion uses the regular layout")
        }
        check(compact.size(for: .running, readBack: String(repeating: "Readback ", count: 100),
                           remembering: "fixture", personalizing: true) == compact.size(for: .running),
              "processing labels never change compact geometry")
        for phase in [NotchPhase.hidden, .opening, .typing, .listening, .transcribing, .recovery,
                      .message, .notice("fixture"), .finishing(.failed)] {
            check(compact.size(for: phase) == regular.size(for: phase), "compact mode only changes processing")
            check(compact.horizontalOffset(for: phase) == 0, "other phases remain centered")
            check(compact.radii(for: phase) == regular.radii(for: phase)
                && compact.glowScale(for: phase) == regular.glowScale(for: phase)
                && compact.glowRotationPeriod(for: phase) == regular.glowRotationPeriod(for: phase),
                  "expanded panels and input retain their existing corners and glow thickness")
        }
        for hardware in [CGSize(width: 170, height: 30), CGSize(width: 200, height: 32), CGSize(width: 230, height: 37)] {
            let m = NotchMetrics(hardwareNotch: hardware, compactMode: true)
            let size = m.size(for: .running)
            let left = m.horizontalOffset(for: .running) - size.width / 2
            check(abs(left + m.compactLeadingWidth + m.compactCameraWidth / 2) < 0.01,
                  "camera exclusion remains centered with unequal wings")
            check(m.compactCameraWidth >= hardware.width && size.height >= hardware.height,
                  "actual camera is fully covered")
            let hit = HitTest(metrics: m)
            let screen = Screen().frame
            let origin = screen.midX + left
            check(hit.cursorOverSilhouette(at: CGPoint(x: origin + 14, y: screen.maxY - 15)), "leading wing receives pointer")
            check(hit.cursorOverSilhouette(at: CGPoint(x: origin + size.width - m.hPad - m.controlSlot / 2,
                                                      y: screen.maxY - 15)), "Stop receives pointer")
            check(!hit.cursorOverSilhouette(at: CGPoint(x: screen.midX, y: screen.maxY - size.height - 2)),
                  "tabs below compact silhouette remain click-through")
            check(!hit.cursorOverSilhouette(at: CGPoint(x: origin - 2, y: screen.maxY - 15)), "outside leading wing remains click-through")
            check(!hit.cursorOverSilhouette(at: CGPoint(x: origin + size.width + 2, y: screen.maxY - 15)),
                  "outside trailing wing remains click-through")
            check(hit.cursorOverSilhouette(at: CGPoint(x: origin + 14, y: screen.maxY)), "top-edge target stays clickable")
        }
        let setup = compact.showingSetup(true)
        check(!setup.isCompact(for: .running), "permission setup expands compact mode for its full instruction")
        check(setup.size(for: .running, readBack: String(repeating: "Long instruction ", count: 30)).height
            == setup.runningHeight(caption: setup.captionHeight), "setup caption uses one line even during voice readback")
        check(setup.showingSetup(false).isCompact(for: .running), "compact mode returns when setup closes")
        let external = NotchMetrics(hardwareNotch: nil, compactMode: true)
        check(external.size(for: .running).width == external.compactLeadingWidth + external.compactTrailingWidth
            && external.horizontalOffset(for: .running) == 0,
              "notchless display uses a centered strip with no phantom camera gap")
        check(regular.readBackCaptionHeight(String(repeating: "Long spoken instruction ", count: 25)) > regular.captionHeight,
              "regular voice readback still expands for readable text")
        print("PASS: \(checks) compact notch geometry and pointer checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-compact-notch-") as directory:
    path = Path(directory)
    source = path / "test.swift"
    source.write_text(FIXTURE.replace("// HIT_TEST", hit_test).replace("// GLOW_STRENGTH", glow_strength)
                      .replace("// SETTLE_GLOW", settle_glow) + "\n" + metrics)
    binary = path / "test"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-parse-as-library", str(APP / "Notch Magic/NotchShape.swift"), str(source),
                    "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
