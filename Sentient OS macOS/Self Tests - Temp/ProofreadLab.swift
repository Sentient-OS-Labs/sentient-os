#if DEBUG
// Proofread acceptance uses only an owned disposable editor and synthetic model output.
// Exercises the actual AX capture/paste/Undo path when the app already has Accessibility.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import SwiftUI
import WebKit

@MainActor enum ProofreadLab {
    enum Failure: Error { case failed, noWindow }
    static func run(root: URL) async throws -> [String: Bool] {
        let directory = root.appendingPathComponent("proofread-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:], captures: [[String: Any]] = []
        var liveNotch: NotchWindowController?
        defer { liveNotch?.shutdownForTesting() }
        func checkpoint(_ stage: String) {
            try? stage.write(to: root.appendingPathComponent("proofread-progress.txt"), atomically: true, encoding: .utf8)
        }
        checkpoint("editor-setup")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 680, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Proofread test editor"
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isEditable = true; editor.isSelectable = true; editor.isRichText = false; editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 18); editor.textContainerInset = NSSize(width: 24, height: 24)
        let original = "Unchanged prefix: café 👩🏽‍💻\n\nteh launch are ready.\nWe was testing it.\n\nUnchanged suffix."
        let selected = "teh launch are ready.\nWe was testing it."
        let corrected = "The launch is ready.\nWe were testing it."
        let range = (original as NSString).range(of: selected)
        editor.string = original
        window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(editor); editor.setSelectedRange(range)
        let menu = NSMenu(); let item = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        item.submenu = edit; menu.addItem(item); NSApp.mainMenu = menu
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor); editor.setSelectedRange(range)
        try await Task.sleep(for: .milliseconds(100))
        let accessibility = Permissions.hasAccessibility()
        var nativeError: String?
        if accessibility {
            do {
                let pid = getpid()
                checkpoint("native-capture")
                let snapshot = try await Task.detached { try ProofreadSelection.capture(pid: pid) }.value
                checks["exact-unicode-selection-captured"] = snapshot.text == selected
                checks["plain-editor-supports-replacement"] = snapshot.canReplace
                let valid = await Task.detached { ProofreadSelection.validate(snapshot) }.value
                checks["original-selection-validates"] = valid
                editor.setSelectedRange(NSRange(location: 0, length: 1))
                let changed = await ProofreadSelection.apply(corrected, to: snapshot, activity: .current)
                checks["changed-selection-is-not-edited"] = changed == .changed && editor.string == original
                editor.setSelectedRange(range); editor.breakUndoCoalescing(); editor.undoManager?.removeAllActions()
                let clipboard = ProofreadClipboard.capture()
                checkpoint("native-paste")
                let outcome = await ProofreadSelection.apply(corrected, to: snapshot, activity: .current)
                checks["actual-paste-replaces-only-selection"] = outcome == .applied && editor.string == (original as NSString).replacingCharacters(in: range, with: corrected)
                checks["ordinary-editor-undo-available"] = editor.undoManager?.canUndo == true
                editor.undoManager?.undo()
                checks["one-undo-restores-original"] = editor.string == original
                editor.setSelectedRange(range)
                let beforeWindows = Set(NSApp.windows.map(\.windowNumber))
                var status: String?
                let operation = Proofread(capture: { try await Task.detached { try ProofreadSelection.capture(pid: pid) }.value },
                                         correct: { _ in corrected })
                operation.prepareSelection(); await operation.waitForSelection()
                _ = operation.start { status = $0 }
                for _ in 0..<60 {
                    if !operation.isRunning { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                checks["operation-replaces-selection-without-popup"] = status == "" && !operation.isRunning
                    && editor.string == (original as NSString).replacingCharacters(in: range, with: corrected)
                    && Set(NSApp.windows.map(\.windowNumber)) == beforeWindows
                editor.undoManager?.undo()
                checks["operation-preserves-undo"] = editor.string == original
                if let clipboard, let current = ProofreadClipboard.capture() {
                    checks["native-paste-restores-clipboard-formats"] = current.items == clipboard.items
                } else { checks["native-paste-restores-clipboard-formats"] = false }
                editor.setSelectedRange(range); editor.isEditable = false
                let readOnly = try await Task.detached { try ProofreadSelection.capture(pid: pid) }.value
                checks["read-only-selection-cannot-auto-replace"] = !readOnly.canReplace
                editor.isEditable = true; editor.isRichText = true
                editor.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: range.location, length: 3))
                editor.setSelectedRange(range)
                let rich = try await Task.detached { try ProofreadSelection.capture(pid: pid) }.value
                checks["mixed-format-selection-allows-normal-replacement"] = rich.canReplace
                let richBefore = NSAttributedString(attributedString: editor.attributedString())
                editor.breakUndoCoalescing(); editor.undoManager?.removeAllActions()
                let richOutcome = await ProofreadSelection.apply(corrected, to: rich, activity: .current)
                checks["mixed-format-selection-replaced"] = richOutcome == .applied
                    && editor.string == (original as NSString).replacingCharacters(in: range, with: corrected)
                editor.undoManager?.undo()
                checks["rich-undo-restores-original-formatting"] = editor.attributedString().isEqual(to: richBefore)
                editor.isRichText = false
                let largePrefix = String(repeating: "unchanged ", count: 7_500)
                let large = largePrefix + selected + " unchanged suffix"
                editor.string = large
                editor.setSelectedRange(NSRange(location: largePrefix.utf16.count, length: selected.utf16.count))
                let bounded = try await Task.detached { try ProofreadSelection.capture(pid: pid) }.value
                checks["large-document-uses-bounded-context"] = bounded.canReplace && bounded.originalValue == nil
                    && (bounded.verificationText?.utf16.count ?? 0) < 1_000
                let largeOutcome = await ProofreadSelection.apply(corrected, to: bounded, activity: .current)
                checks["large-document-selection-replaced"] = largeOutcome == .applied
                    && editor.string == largePrefix + corrected + " unchanged suffix"
                editor.string = original; editor.setSelectedRange(range)
                captures.append(try await SidekickPolishLab.capture(scroll, name: "01-editor", directory: directory))
                // The real panel must wait until the external selection snapshot is complete.
                editor.isRichText = false; editor.string = original; editor.setSelectedRange(range)
                window.makeFirstResponder(editor)
                let coordinator = CommandCoordinator()
                coordinator.run.preventsTaskExecutionForUIFixture = true
                coordinator.run.conversation.isVisible = false
                let notch = NotchWindowController(coordinator: coordinator)
                liveNotch = notch // Match the production app-lifetime panel, including its retract.
                checkpoint("notch-focus")
                notch.start()
                try await Task.sleep(for: .milliseconds(100))
                coordinator.proofread.prepareSelection()
                coordinator.openNotchFromHome()
                checks["notch-waits-for-selection-before-key"] = coordinator.proofread.isCapturingSelection && notch.panelForTesting?.isKeyWindow != true
                await coordinator.proofread.waitForSelection()
                try await Task.sleep(for: .milliseconds(250))
                checks["bookmark-survives-notch-focus"] = coordinator.proofread.hasPreparedSelectionBookmark
                    && notch.panelForTesting?.isKeyWindow == true
                coordinator.dismissTyping()
                checks["dismiss-discards-selection-bookmark"] = !coordinator.proofread.hasPreparedSelectionBookmark

            } catch { nativeError = String(describing: error); checks["native-path-completed"] = false }
        }
        window.orderOut(nil)
        if accessibility, nativeError == nil {
            checkpoint("browser-field")
            let web = WKWebView()
            let browserWindow = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 680, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            browserWindow.isReleasedWhenClosed = false; browserWindow.title = "Proofread browser fixture"
            browserWindow.contentView = web; browserWindow.center(); browserWindow.makeKeyAndOrderFront(nil)
            defer { browserWindow.close() }
            web.loadHTMLString("<html><body style='background:#151516;color:white;font:18px -apple-system;padding:24px'>Browser text field<textarea id='target' style='display:block;width:100%;height:180px;font:18px -apple-system'>teh launch are ready.</textarea></body></html>", baseURL: nil)
            for _ in 0..<60 { if !web.isLoading { break }; try await Task.sleep(for: .milliseconds(50)) }
            browserWindow.makeFirstResponder(web)
            _ = try await web.evaluateJavaScript("document.getElementById('target').focus();document.getElementById('target').select();")
            try await Task.sleep(for: .milliseconds(200))
            let pid = getpid()
            let browserSelection = try await Task.detached { try ProofreadSelection.capture(pid: pid) }.value
            checks["browser-selection-captured"] = browserSelection.text == "teh launch are ready."
            checks["browser-field-supports-auto-replacement"] = browserSelection.canReplace
            let outcome = await ProofreadSelection.apply("The launch is ready.", to: browserSelection, activity: .current)
            let value = try await web.evaluateJavaScript("document.getElementById('target').value") as? String
            checks["browser-field-corrected-in-place"] = outcome == .applied && value == "The launch is ready."
            _ = try await web.evaluateJavaScript("document.execCommand('undo')")
            checks["browser-undo-restores-original"] = try await web.evaluateJavaScript("document.getElementById('target').value") as? String == "teh launch are ready."
            captures.append(try await SidekickPolishLab.capture(web, name: "06-browser", directory: directory))
            browserWindow.orderOut(nil)
        }
        let variants: [(String, AnyView)] = [
            ("02-split-notch", AnyView(NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: .preview)
                .frame(width: 700, height: 210).background(Color(white: 0.12)))),
            ("03-proofreading", AnyView(NotchContent(phase: .notice("Proofreading…"), readBack: nil, statusLine: "", metrics: .preview,
                isProofreading: true).frame(width: 700, height: 180).background(Color(white: 0.12)))),
        ]
        for (name, view) in variants {
            checkpoint("render-" + name)
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
            host.sizingOptions = []; host.wantsLayer = true
            let size: NSSize
            switch name {
            case "02-split-notch": size = NSSize(width: 700, height: 210)
            case "03-proofreading": size = NSSize(width: 700, height: 180)
            default: size = NSSize(width: 700, height: 180)
            }
            let frame = NSRect(origin: NSPoint(x: 100, y: 100), size: size)
            let panel = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host; panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(250))
            captures.append(try await SidekickPolishLab.capture(host, name: name, directory: directory))
            panel.close()
        }
        checks["no-proofread-popup"] = !NSApp.windows.contains { $0.identifier?.rawValue == "sentient.proofread" }
        let holdURL = root.appendingPathComponent("proofread-hold-seconds")
        if let raw = try? String(contentsOf: holdURL, encoding: .utf8), let seconds = Int(raw), (1...300).contains(seconds) {
            try await Task.sleep(for: .seconds(seconds))
        }
        for index in captures.indices { captures[index]["file"] = "proofread-snapshots/" + (captures[index]["name"] as! String) + ".png" }
        let manifest: [String: Any] = ["checks": checks, "captures": captures, "provider_calls": 0, "accessibility_available": accessibility,
            "native_error_type": nativeError ?? "none", "native_edit_tested": accessibility && nativeError == nil]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("proofread-manifest.json"), options: .atomic)
        checkpoint("finished")
        guard checks.values.allSatisfy({ $0 }) else { throw Failure.failed }
        return checks
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
