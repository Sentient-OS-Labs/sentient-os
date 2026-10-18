#!/usr/bin/env python3
"""Exercise the actual notch message view in a brief synthetic nonactivating panel.

Checks native editing, focus reporting and Return submission. No model, real conversation,
computer-use helper, credentials or screen capture. Optional --output saves the rendered fixture.
Requires a macOS graphical session.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import AppKit
import SwiftUI
import Observation
extension EnvironmentValues { @Entry var sidekickReduceMotionOverride: Bool? = nil }

@MainActor @Observable final class State {
    var draft = ""
    var focused = false
    var submitted: String?
    var opened = false
}
@MainActor final class TestPanel: NSPanel { override var canBecomeKey: Bool { true } }
@main @MainActor enum Test {
    static func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
    static func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let state = State()
        let message = SidekickConversationStore.Record(sequence: 1, event: .init(taskID: UUID(), kind: .assistantMessage,
            text: "Which one should I add to your Spotify Liked Songs: **The Pretender** or **Everlong** by Foo Fighters? I haven’t added either yet.", messageKind: .answer, priority: .high))
        let layout = SidekickNotchMessageLayout(markdown: message.event.text, maximumSize: CGSize(width: 520, height: 286), cameraHeight: 37, outerTopPad: 0, outerBottomPad: 4, horizontalPad: 18)
        let contentHeight = layout.size.height - 41
        let view = SidekickNotchMessageView(message: message, isTaskRunning: false,
            onOpen: { state.opened = true }, onReply: { _ in }, onStop: {}, onSelecting: { _ in },
            draft: Binding(get: { state.draft }, set: { state.draft = $0 }),
            onReplyFocusChanged: { state.focused = $0 }, onSend: { text in state.submitted = text; return true })
            .padding(.horizontal, 18).frame(width: 520, height: contentHeight).background(.black)
        let host = NSHostingView(rootView: view)
        let panel = TestPanel(contentRect: NSRect(x: 240, y: 240, width: 520, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host; panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.close() }
        await settle(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        precondition(!state.focused, "Preview must not focus itself")
        guard let field = fields(host).first(where: { $0.isEditable }) else { fatalError("Reply text field missing") }
        precondition(field.placeholderString == "Reply to Sidekick…")
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render") }
        host.cacheDisplay(in: host.bounds, to: image)
        try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        await settle()
        guard let editor = field.currentEditor() as? NSTextView else { fatalError("Field editor unavailable") }
        editor.insertText("Everlong", replacementRange: NSRange(location: 0, length: 0))
        await settle()
        precondition(state.draft == "Everlong", "Typing must update shared draft")
        precondition(state.focused, "Typing must pause preview dismissal")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        panel.sendEvent(enter)
        await settle()
        precondition(state.submitted == "Everlong", "Return must submit exact reply")
        precondition(!state.opened, "Reply must not open Home")
        print("PASS native reply field, focus, shared draft, Return submission, inline-only send, and rendered preview")
    }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="sentient-notch-reply-") as temporary:
        root = Path(temporary)
        fixture = root / "Reply.swift"
        fixture.write_text(FIXTURE)
        executable = root / "reply-test"
        image = args.output.resolve() if args.output else root / "reply.png"
        sources = [
            "Notch Magic/SidekickConversationStore.swift",
            "Views/Sidekick/SidekickMarkdownDocument.swift",
            "Views/Sidekick/SidekickMarkdown.swift",
            "Notch Magic/SidekickNotchMessageLayout.swift",
            "Notch Magic/SidekickNotchMessageView.swift",
        ]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-parse-as-library",
            *[str(APP / name) for name in sources], str(fixture), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable), str(image)], check=True, timeout=15)

if __name__ == "__main__":
    main()
