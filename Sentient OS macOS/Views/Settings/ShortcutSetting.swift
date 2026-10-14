// ShortcutSetting.swift
// Shared shortcut row and local single-key recorder for Sidekick and Double Tap.
// Other opens a recording sheet; nothing is saved until Use key, and Cancel preserves the binding.
// Doc: Documentation - Settings.md

import AppKit
import SwiftUI

struct ShortcutSetting: View {
    @AppStorage(ShortcutPreferences.storageKey) private var keyRaw = "rightCommand"
    @State private var recording = false

    private var key: ShortcutKey { ShortcutKey(rawValue: keyRaw) ?? .rightCommand }
    private var selection: Binding<String> {
        Binding(get: { key.rawValue }, set: { value in
            if value == "other" {
                ShortcutPreferences.setRecording(true)
                recording = true
            } else if let key = ShortcutKey(rawValue: value) {
                ShortcutPreferences.save(key)
            }
        })
    }

    var body: some View {
        SettingsRow(title: "Shortcut key", subtitle: "Tap to open Sidekick. Double tap to draft a reply.") {
            SettingsMenu(title: "Sidekick shortcut", value: key.label, selection: selection) {
                Text("Right ⌘").tag(ShortcutKey.rightCommand.rawValue)
                Text("Right ⌥").tag(ShortcutKey.rightOption.rawValue)
                if key != .rightCommand && key != .rightOption {
                    Text(key.label).tag(key.rawValue)
                }
                Divider()
                Text("Other…").tag("other")
            }
            .frame(width: 150)
        }
        .sheet(isPresented: $recording, onDismiss: { ShortcutPreferences.setRecording(false) }) {
            ShortcutRecorderSheet()
        }
        .onDisappear {
            if recording { ShortcutPreferences.setRecording(false) }
        }
    }
}

private struct ShortcutRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: ShortcutKey?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sidekick shortcut").display(24).foregroundStyle(.white)
            SettingsProse("The same key is used for Sidekick and Double Tap. Press and release Command, Option, or Control on either side of your keyboard.")
            Text(candidate?.label ?? "Press a key…")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(candidate == nil ? SettingsStyle.secondary : .white)
                .frame(maxWidth: .infinity).frame(height: 88)
                .background(SettingsStyle.control, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SettingsStyle.border, lineWidth: 1))
                .background {
                    ShortcutRecorderInput(onKey: { candidate = $0; error = nil },
                                          onError: { candidate = nil; error = $0 },
                                          onCancel: { dismiss() })
                }
                .accessibilityLabel("Recorded key")
                .accessibilityValue(candidate?.spokenLabel ?? "Waiting for a key")
            Text(error ?? "Press one modifier key by itself, without a key combination.")
                .font(.system(size: 13)).foregroundStyle(error == nil ? SettingsStyle.secondary : Theme.Ink.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SettingsActionStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use key") {
                    guard let candidate else { return }
                    ShortcutPreferences.save(candidate)
                    dismiss()
                }
                .buttonStyle(SettingsActionStyle(tint: Theme.Ink.green))
                .keyboardShortcut(.defaultAction)
                .disabled(candidate == nil)
            }
        }
        .padding(28).frame(width: 440)
        .background(Theme.bg).preferredColorScheme(.dark)
        .onDisappear { ShortcutPreferences.setRecording(false) }
    }
}

/// This responder only sees events in its own focused sheet. Global shortcuts are suspended.
private struct ShortcutRecorderInput: NSViewRepresentable {
    let onKey: (ShortcutKey) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onKey = onKey
        view.onError = onError
        view.onCancel = onCancel
    }

    final class KeyView: NSView {
        var onKey: ((ShortcutKey) -> Void)?
        var onError: ((String) -> Void)?
        var onCancel: (() -> Void)?
        private var pending: ShortcutKey?
        private var tap = ShortcutTap()
        private var focusObserver: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            focusObserver = nil
            pending = nil
            tap = ShortcutTap()
            guard let window else { return }
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.pending = nil
                        self?.tap = ShortcutTap()
                    }
                }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown,
                  !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return super.performKeyEquivalent(with: event)
            }
            // Reject combinations inside the recorder before an app menu can handle them.
            reject()
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            if let pending {
                let down = UInt64(event.modifierFlags.rawValue) & pending.deviceBit != 0
                let alone = down ? pending.isAlone(in: event.modifierFlags)
                    : event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty
                finish(pending, down: down, alone: alone)
                return
            }
            guard let key = ShortcutKey(keyCode: event.keyCode) else {
                reject()
                return
            }
            guard UInt64(event.modifierFlags.rawValue) & key.deviceBit != 0 else { return }
            begin(key, alone: key.isAlone(in: event.modifierFlags))
        }

        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { onCancel?(); return }
            reject()
        }

        private func begin(_ key: ShortcutKey, alone: Bool) {
            guard alone else { reject(); return }
            pending = key
            tap = ShortcutTap()
            _ = tap.update(down: true, alone: true, at: ProcessInfo.processInfo.systemUptime,
                           activity: .current)
        }

        private func finish(_ key: ShortcutKey, down: Bool, alone: Bool) {
            let valid = tap.update(down: down, alone: alone, at: ProcessInfo.processInfo.systemUptime,
                                   activity: .current, maximumDuration: .infinity)
            if !alone { onError?("Use one key by itself, without another modifier.") }
            if !down {
                pending = nil
                if valid { onKey?(key) }
                else { onError?("Press and release one key by itself.") }
            }
        }

        private func reject() {
            tap.cancel()
            onError?("Use a Command, Option, or Control key by itself.")
        }
    }
}

#if DEBUG
#Preview("Shortcut settings") {
    SettingsPane(title: "Shortcuts") {
        VStack(spacing: 24) {
            SettingsGroup(label: "Sidekick", inset: 0) { ShortcutSetting() }
        }
    }
    .frame(width: 680, height: 420).background(Theme.bg).preferredColorScheme(.dark)
}

#Preview("Record a shortcut") {
    ShortcutRecorderSheet()
}
#endif
