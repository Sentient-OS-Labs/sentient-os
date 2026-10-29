// Owns the temporary read-only capability surface and its bounded focus-settling wait.
// The visible nonce and AX label share one value; show/close never inspect another app.
// Doc: Documentation - Permission Gate & Guide.md
import AppKit

@MainActor final class NativePermissionCheckWindow {
    private static weak var presentedWindow: NSWindow?
    static var isPresenting: Bool { presentedWindow != nil }

    let marker = "Sentient check " + UUID().uuidString
    private let panel: NSWindow
    private weak var previous: NSWindow?

    init() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Checking computer use"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .black
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let title = NSTextField(labelWithString: "Checking computer use")
        title.font = .systemFont(ofSize: 17, weight: .medium)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 100, width: 372, height: 24)
        let explanation = NSTextField(wrappingLabelWithString:
            "Keep this window in front while Sidekick checks it.\nIt closes automatically.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 24, y: 51, width: 372, height: 36)
        let proof = NSTextField(labelWithString: marker)
        proof.setAccessibilityLabel(marker)
        proof.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        proof.textColor = .secondaryLabelColor
        proof.frame = NSRect(x: 24, y: 22, width: 372, height: 16)
        for field in [title, explanation, proof] { panel.contentView?.addSubview(field) }
    }

    var isCurrent: Bool {
        panel.isVisible && panel.isOnActiveSpace && !panel.isMiniaturized && NSApp.keyWindow === panel
    }

    func show() {
        previous = NSApp.keyWindow
        Self.presentedWindow = panel
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    /// Wait for AppKit activation/order delivery, without repeatedly taking focus from the user.
    func waitUntilCurrent() async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while true {
            try Task.checkCancellation()
            if isCurrent { return }
            guard Self.presentedWindow === panel, clock.now < deadline else {
                throw NativeComputerUseFailure(kind: .unknown, code: nil,
                    detail: .testWindowNotCurrentBeforeRead, stage: .probe)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func close() {
        let restore = NSApp.keyWindow === panel
        if Self.presentedWindow === panel { Self.presentedWindow = nil }
        panel.close()
        if restore, let previous, previous.isVisible { previous.makeKeyAndOrderFront(nil) }
    }
}
