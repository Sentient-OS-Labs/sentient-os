#!/usr/bin/env python3
"""Inspect the production AppKit proof field without showing a window or activating an app.
Also exercise the bounded presentation wait, cancellation and cleanup against an unshown window.
No helper, TCC access, model, real-app capture, customer storage or focus changes.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
TESTS = r'''
@main struct Tests {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let window = NativePermissionCheckWindow()
        check(!NativePermissionCheckWindow.isPresenting && !window.isCurrent, "Construction never presents the proof window")
        window.inspectProof()
        do { try await window.waitUntilCurrent(); fatalError("Unshown window accepted") }
        catch let failure as NativeComputerUseFailure {
            check(failure.detail == .testWindowNotCurrentBeforeRead, "No admitted presentation fails before reading")
        }
        window.fixturePendingPresentation()
        check(NativePermissionCheckWindow.isPresenting, "The migration guard can see an admitted presentation")
        let clock = ContinuousClock(), start = ContinuousClock.now
        do { try await window.waitUntilCurrent(); fatalError("Unsettled window accepted") }
        catch let failure as NativeComputerUseFailure {
            check(failure.detail == .testWindowNotCurrentBeforeRead, "Unsettled presentation preserves a specific failure")
        }
        let elapsed = start.duration(to: clock.now)
        check(elapsed >= .milliseconds(900) && elapsed < .seconds(3), "Presentation waits are bounded")
        let cancelled = Task { try await window.waitUntilCurrent() }
        try await Task.sleep(for: .milliseconds(50)); cancelled.cancel()
        do { try await cancelled.value; fatalError("Presentation cancellation ignored") }
        catch is CancellationError { count += 1 }
        window.close()
        check(!NativePermissionCheckWindow.isPresenting, "Closing releases presentation ownership")
        check(!window.isCurrent, "An unshown window never becomes current during waits or cleanup")
        print("PASS \(count) AppKit proof surface assertions; no window shown or app activated")
    }
}
extension NativePermissionCheckWindow {
    // Test-only access is appended to a temporary copy of production source. No test API ships.
    func fixturePendingPresentation() { Self.presentedWindow = panel }
    func inspectProof() {
        Tests.check(!panel.isVisible, "Real AppKit window starts hidden")
        let labels = (panel.contentView?.subviews ?? []).compactMap { $0 as? NSTextField }
        let proof = labels.filter { $0.stringValue == marker }
        Tests.check(proof.count == 1, "A unique visible field contains the complete nonce")
        Tests.check(proof[0].accessibilityLabel() == marker, "AX label carries the same nonce")
        Tests.check(proof[0].accessibilityValue() == marker, "AX static-text value carries the same nonce")
        Tests.check(!proof[0].isEditable, "The proof requires no typing or focusable editor")
        let size = (marker as NSString).size(withAttributes: [.font: proof[0].font!])
        Tests.check(size.width < proof[0].frame.width && size.height <= proof[0].frame.height,
                    "The complete visible nonce fits without clipping")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-permission-window-') as directory:
    root = Path(directory)
    source = root / 'Window.swift'
    source.write_text((APP / 'Views/Permissions/NativePermissionCheckWindow.swift').read_text() + TESTS)
    binary = root / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-target', f'{platform.machine()}-apple-macos15.0', str(source),
                    str(APP / 'Diagnostics/NativeComputerUseFailure.swift'), '-o', str(binary)],
                   check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=10)
