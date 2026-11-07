#if DEBUG
// Actual summary panel and notch rendering with synthetic pixels/text in the isolated app lab.
// Exercises streaming, retry, selection, resize and close without credentials, mic or provider calls.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import SwiftUI

@MainActor enum SummarizeLab {
    static func run(root: URL) async throws -> [String: Bool] {
        let directory = root.appendingPathComponent("summary-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:], captures: [[String: Any]] = []
        var inference: CheckedContinuation<String, Error>?
        var update: (@MainActor (String) -> Void)?
        var captureCount = 0
        let summary = Summarize(capture: { _ in captureCount += 1; return Data([1, 2, 3]) }, infer: { _, _, onText in
            update = onText
            return try await withCheckedThrowingContinuation { inference = $0 }
        })
        defer { summary.dismiss(); inference?.resume(throwing: CancellationError()) }
        guard let screen = NSScreen.main else { throw Failure.noWindow }
        summary.start(displayID: screen.displayID)
        try await Task.sleep(for: .milliseconds(300))
        guard let panel = summary.fixtureWindow, let host = panel.contentView else { throw Failure.noWindow }
        let initial = panel.frame
        checks["panel-stays-auxiliary"] = !panel.isMainWindow
        checks["capture-before-inference"] = captureCount == 1 && summary.phase == .loading
        captures.append(try await SidekickPolishLab.capture(host, name: "01-loading", directory: directory))
        let short = """
        **TL;DR:** The team is preparing a **Friday product walkthrough**, with the final review due at **3 PM Thursday**.

        ---

        - **Design:** finalize the three onboarding screens before the review.
        - **Engineering:** confirm that the screen capture and voice flows work on external displays.
        - **Next step:** share the revised checklist in the project channel so everyone can review it.

        The bottom of the conversation is cut off, so later replies aren’t visible.
        """
        update?(String(short.prefix(160)))
        try await Task.sleep(for: .milliseconds(200))
        checks["streaming-keeps-window-frame"] = panel.frame == initial
        captures.append(try await SidekickPolishLab.capture(host, name: "02-streaming", directory: directory))
        if let reader = descendants(host).compactMap({ $0 as? SummaryTextView }).first {
            let previous = reader.string
            reader.setSelectedRange(NSRange(location: 0, length: min(20, reader.string.utf16.count)))
            update?(short)
            try await Task.sleep(for: .milliseconds(100))
            checks["stream-preserves-active-selection"] = reader.string == previous && reader.selectedRange().length > 0
            reader.setSelectedRange(NSRange(location: 0, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            checks["selection-release-catches-up"] = reader.string.contains("later replies")
        }
        update?(short); inference?.resume(returning: short); inference = nil
        try await Task.sleep(for: .milliseconds(300))
        checks["completion-keeps-window-frame"] = panel.frame == initial && summary.phase == .complete
        captures.append(try await SidekickPolishLab.capture(host, name: "03-complete", directory: directory))
        let nativeText = descendants(host).compactMap { $0 as? NSTextView }.first { $0.string.contains("Friday") }
        checks["native-selectable-text"] = nativeText?.isSelectable == true && nativeText?.isEditable == false
        if let nativeText {
            var dividers = 0
            nativeText.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: nativeText.textStorage?.length ?? 0)) { value, _, _ in
                if value is NSTextAttachment { dividers += 1 }
            }
            checks["markdown-divider-rendered"] = dividers == 1
            nativeText.setSelectedRange((nativeText.string as NSString).range(of: "Friday"))
            checks["exact-text-selection"] = (nativeText.string as NSString).substring(with: nativeText.selectedRange()) == "Friday"
        }
        panel.setContentSize(NSSize(width: 380, height: 330))
        try await Task.sleep(for: .milliseconds(250))
        let narrowFrame = panel.frame
        captures.append(try await SidekickPolishLab.capture(host, name: "04-narrow", directory: directory))
        if let reader = nativeText {
            checks["narrow-lines-fit-without-overlap"] = linesFit(reader)
            checks["narrow-container-follows-width"] = abs((reader.textContainer?.containerSize.width ?? 0) - (reader.bounds.width - 56)) < 2
        }
        checks["resizable-reader"] = panel.contentView!.bounds.width >= 360 && panel.frame.height < initial.height
        summary.start(displayID: screen.displayID)
        try await Task.sleep(for: .milliseconds(100))
        let long = short + "\n\n" + (1...12).map { "- Detail \($0): the synthetic project note explains dependencies, deadlines and owners. Every sentence must remain readable as the panel scrolls." }.joined(separator: "\n")
        update?(long); inference?.resume(returning: long); inference = nil
        try await Task.sleep(for: .milliseconds(250))
        captures.append(try await SidekickPolishLab.capture(host, name: "05-long", directory: directory))
        let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first { $0.documentView?.bounds.height ?? 0 > $0.contentView.bounds.height }
        checks["long-summary-scrolls"] = scroll != nil
        scroll?.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll?.documentView?.bounds.height ?? 0) - (scroll?.contentView.bounds.height ?? 0))))
        if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
        try await Task.sleep(for: .milliseconds(100))
        captures.append(try await SidekickPolishLab.capture(host, name: "06-long-bottom", directory: directory))
        summary.start(displayID: screen.displayID); try await Task.sleep(for: .milliseconds(100))
        update?("The visible note describes the upcoming launch.")
        inference?.resume(throwing: SummarizeInference.Failure.incomplete); inference = nil
        try await Task.sleep(for: .milliseconds(200))
        captures.append(try await SidekickPolishLab.capture(host, name: "07-interrupted", directory: directory))
        checks["failure-and-long-content-never-resize-window"] = panel.frame == narrowFrame
        let holdURL = root.appendingPathComponent("summary-hold-seconds")
        if let raw = try? String(contentsOf: holdURL, encoding: .utf8), let seconds = Int(raw), (1...300).contains(seconds) {
            try await Task.sleep(for: .seconds(seconds))
        }
        let beforeRetry = captureCount
        summary.retry(); try await Task.sleep(for: .milliseconds(100))
        checks["retry-preserves-snapshot"] = captureCount == beforeRetry
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        checks["escape-closes-and-cancels"] = panel.performKeyEquivalent(with: escape) && summary.phase == .idle
        inference?.resume(returning: "stale completion"); inference = nil
        try await Task.sleep(for: .milliseconds(100))
        checks["close-releases-window-and-text"] = summary.fixtureWindow == nil && summary.phase == .idle && summary.text.isEmpty

        let permission = Summarize(capture: { _ in throw ScreenCapture.SummaryFailure.permission }, infer: { _, _, _ in throw Failure.provider })
        permission.start(displayID: screen.displayID)
        try await Task.sleep(for: .milliseconds(200))
        if let view = permission.fixtureWindow?.contentView {
            captures.append(try await SidekickPolishLab.capture(view, name: "08-permission", directory: directory))
        }
        checks["permission-recovery"] = permission.needsScreenPermission && permission.phase == .failed
        if let permissionPanel = permission.fixtureWindow {
            let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: permissionPanel.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
            checks["command-w-closes"] = permissionPanel.performKeyEquivalent(with: commandW) && permission.phase == .idle
        }
        permission.dismiss()

        let source = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; source.title = "Synthetic summary source"
        let sourceText = NSTextView(); sourceText.string = "Use this window to switch between synthetic tabs."
        source.contentView = sourceText; NSApp.activate(ignoringOtherApps: true); source.makeKeyAndOrderFront(nil); source.makeFirstResponder(sourceText)
        defer { source.close() }
        for _ in 0..<30 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(100)); NSApp.activate(ignoringOtherApps: true) }
        source.makeKeyAndOrderFront(nil); source.makeFirstResponder(sourceText)
        checks["source-was-key-before-summaries"] = source.isKeyWindow
        checks["source-responder-set-before-summaries"] = source.firstResponder === sourceText
        var tab = 0
        let sessions = SummarySessions(makeSummary: {
            tab += 1
            let number = tab
            return Summarize(capture: { _ in Data([UInt8(number)]) }, infer: { _, _, update in
                let result = "Tab \(number) summary\n\nThis is independent content for synthetic tab \(number)."
                update(result); return result
            })
        })
        defer { sessions.dismiss() }
        let one = sessions.start(displayID: screen.displayID)
        let two = sessions.start(displayID: screen.displayID)
        try await Task.sleep(for: .milliseconds(250))
        guard let onePanel = one.fixtureWindow, let twoPanel = two.fixtureWindow,
              let oneHost = onePanel.contentView, let twoHost = twoPanel.contentView else { throw Failure.noWindow }
        checks["two-real-summary-windows"] = onePanel !== twoPanel && onePanel.isVisible && twoPanel.isVisible
        checks["multiple-summaries-preserve-source-focus"] = source.isKeyWindow && source.firstResponder === sourceText
        checks["summary-one-does-not-take-focus"] = !onePanel.isKeyWindow
        checks["summary-two-does-not-take-focus"] = !twoPanel.isKeyWindow
        checks["summary-windows-cascade"] = onePanel.frame.origin != twoPanel.frame.origin
            && screen.visibleFrame.contains(onePanel.frame) && screen.visibleFrame.contains(twoPanel.frame)
        checks["independent-native-summary-text"] = descendants(oneHost).compactMap { $0 as? NSTextView }.contains { $0.string.contains("Tab 1 summary") }
            && descendants(twoHost).compactMap { $0 as? NSTextView }.contains { $0.string.contains("Tab 2 summary") }
        captures.append(try await SidekickPolishLab.capture(oneHost, name: "10-first-summary", directory: directory))
        captures.append(try await SidekickPolishLab.capture(twoHost, name: "11-second-summary", directory: directory))
        onePanel.makeKeyAndOrderFront(nil)
        let closeOne = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: onePanel.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        checks["command-w-closes-only-one-summary"] = onePanel.performKeyEquivalent(with: closeOne)
            && sessions.sessions.count == 1 && twoPanel.isVisible && two.text.contains("Tab 2")
        let three = sessions.start(displayID: screen.displayID)
        try await Task.sleep(for: .milliseconds(150))
        checks["third-summary-keeps-second-result"] = sessions.sessions.count == 2 && twoPanel.isVisible
            && two.text.contains("Tab 2") && three.text.contains("Tab 3")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        checks["sleep-closes-all-summary-windows"] = sessions.sessions.isEmpty && two.fixtureWindow == nil && three.fixtureWindow == nil

        let notchView = NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: .preview)
            .frame(width: 700, height: 210).background(Color(white: 0.12)).preferredColorScheme(.dark)
        let notchHost = NSHostingView(rootView: notchView)
        let notchWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
        notchWindow.isReleasedWhenClosed = false; notchWindow.contentView = notchHost; notchWindow.orderFrontRegardless()
        defer { notchWindow.close() }
        try await Task.sleep(for: .milliseconds(350))
        captures.append(try await SidekickPolishLab.capture(notchHost, name: "09-notch", directory: directory))
        checks["notch-height-includes-action"] = NotchMetrics.preview.size(for: .typing).height == 99
        let video = Summarize(captureSource: { _,_ in SummarySource(text: "Video fixture", url: "https://youtu.be/jNQXAC9IVRw") }, inferWithSource: { _,_, metadata, update in
            try await Task.sleep(for: .seconds(1))
            metadata(.init(kind: .youtube, truncated: true))
            let text = "A month with Tesla’s **Full Self-Driving** leaves the presenter impressed by its navigation, but concerned about unexpected maneuvers.\n\n- **Cost:** the subscription is quoted at $100 per month.\n- **Main concern:** the presenter intervenes when the car signals right but continues straight through an intersection."
            update(text); return text
        })
        defer { video.dismiss() }
        video.start(displayID: screen.displayID); try await Task.sleep(for: .milliseconds(150))
        if let host = video.fixtureWindow?.contentView {
            checks["pending-video-header"] = video.sourceLabel == "Fetching video transcript…" && video.sourceInfo == nil
            captures.append(try await SidekickPolishLab.capture(host, name: "12a-video-fetching", directory: directory))
        }
        try await Task.sleep(for: .milliseconds(1100))
        if let panel = video.fixtureWindow, let host = panel.contentView {
            checks["verified-transcript-header"] = video.sourceLabel == "Fetched video transcript"
            captures.append(try await SidekickPolishLab.capture(host, name: "12-video-header", directory: directory))
            panel.setContentSize(NSSize(width: 360, height: 400)); try await Task.sleep(for: .milliseconds(250))
            captures.append(try await SidekickPolishLab.capture(host, name: "13-video-header-narrow", directory: directory))
        }
        let document = Summarize(captureSource: { _,_ in SummarySource(text: "Visible and offscreen fixture text", offscreenTextElements: 12) },
            inferWithSource: { _,_, metadata,_ in
                metadata(.init(kind: .accessibility, truncated: false))
                return "The rollout is ready. **Testing is complete**, and the team plans to launch on Friday."
            })
        defer { document.dismiss() }
        document.start(displayID: screen.displayID); try await Task.sleep(for: .milliseconds(250))
        if let host = document.fixtureWindow?.contentView {
            checks["offscreen-text-header"] = document.sourceLabel == "Read offscreen text too"
            captures.append(try await SidekickPolishLab.capture(host, name: "14-offscreen-text-header", directory: directory))
        }
        for index in captures.indices { captures[index]["file"] = "summary-snapshots/" + (captures[index]["name"] as! String) + ".png" }
        let manifest: [String: Any] = ["checks": checks, "captures": captures, "provider_calls": 0, "microphone_used": false, "live_screen_uploaded": false]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("summary-manifest.json"), options: .atomic)
        guard checks.values.allSatisfy({ $0 }) else { throw Failure.checks }
        return checks
    }
    private static func linesFit(_ view: NSTextView) -> Bool {
        guard let layout = view.layoutManager, let container = view.textContainer else { return false }
        layout.ensureLayout(for: container)
        var fits = true, previousBottom: CGFloat = -1
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, used, _, _, _ in
            if used.minY < previousBottom - 0.5 || used.maxX > container.containerSize.width + 1 { fits = false }
            previousBottom = used.maxY
        }
        return fits
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    enum Failure: Error { case noWindow, provider, checks }
}
#endif
