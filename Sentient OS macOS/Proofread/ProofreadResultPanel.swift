// A quiet, ephemeral corrected-copy fallback when automatic replacement cannot be verified.
// Reuses the native reader; closing releases text storage. No history or automatic insertion.
// Doc: Documentation - Proofread.md
import AppKit
import SwiftUI

@MainActor final class ProofreadResultPanel: NSObject, NSWindowDelegate {
    private var panel: ReadingPanel?
    private var observers: [NSObjectProtocol] = []
    override init() {
        super.init()
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func show(text: String?, explanation: String, permission: Bool) {
        close()
        let preferredSize = NSSize(width: permission ? 480 : 560, height: permission ? 360 : text == nil ? 280 : 440)
        let panel = ReadingPanel(title: "Proofread", identifier: "sentient.proofread", size: preferredSize)
        panel.onDismiss = { [weak self] in self?.close() }; panel.delegate = self
        panel.install(ProofreadResultView(text: text, explanation: explanation, permission: permission, close: { [weak self] in self?.close() }))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            let size = NSSize(width: min(preferredSize.width, visible.width), height: min(preferredSize.height, visible.height))
            panel.contentMaxSize = visible.size
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        self.panel = panel; panel.makeKeyAndOrderFront(nil)
    }
    func close() { panel?.orderOut(nil); panel?.contentView = nil; panel?.delegate = nil; panel = nil }
    #if DEBUG
    var panelForTesting: NSPanel? { panel }
    #endif
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

struct ProofreadResultView: View {
    let text: String?
    let explanation: String
    let permission: Bool
    let close: () -> Void
    @State private var copied = false
    @State private var generation = UUID()
    var body: some View {
        if permission {
            QuickActionPermissionView(feature: .proofread, onDone: close)
        } else {
            result
        }
    }
    private var result: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Proofread").font(.system(size: 17, weight: .medium))
                Spacer()
                if let text {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.accessibilityIdentifier("proofread.copy")
                }
                Button(action: close) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .accessibilityLabel("Close proofreading result")
            }
            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 24).frame(height: 64)
            Divider()
            Text(explanation).font(.system(size: 14)).lineSpacing(4).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            if let text {
                SummaryReader(text: text, generation: generation, plainText: true, accessibilityLabel: "Corrected text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            } else { Spacer(minLength: 0) }
        }
        .background(.black).ignoresSafeArea()
    }
}
