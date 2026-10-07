// Detects sustained user input overlapping one unfinished Chromium tool call.
// observe(_:) tracks calls; watch() throws through the task's normal cancellation path.
// Reads input metadata only, without requesting Accessibility or Input Monitoring access.
// Doc: Documentation - Native Computer Use.md

import AppKit
import os

nonisolated final class BrowserInteractionMonitor: Sendable {
    struct Browser: Sendable, Equatable {
        let bundleID: String
        let path: String?

        init?(target: String) {
            let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = ((target as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            guard let entry = Self.names.first(where: { $0.key == target.lowercased() || $0.value.contains(name) }) else { return nil }
            bundleID = entry.key
            path = target.hasPrefix("/") ? URL(fileURLWithPath: target).standardizedFileURL.path : nil
        }

        // The silent same-app wait was reproduced in Chromium. Other browsers retain the
        // helper's explicit-error handling without assuming they share that limitation.
        var isChromium: Bool {
            !["com.apple.safari", "com.apple.safaritechnologypreview", "org.mozilla.firefox"].contains(bundleID)
        }

        func matches(bundleID: String?, path: String?) -> Bool {
            guard self.bundleID == bundleID?.lowercased() else { return false }
            return self.path == nil || self.path == path
        }

        private static let names: [String: Set<String>] = [
            "com.google.chrome": ["google chrome", "chrome"],
            "com.google.chrome.beta": ["google chrome beta"],
            "com.google.chrome.dev": ["google chrome dev"],
            "com.google.chrome.canary": ["google chrome canary"],
            "org.chromium.chromium": ["chromium"],
            "com.microsoft.edgemac": ["microsoft edge", "edge"],
            "com.microsoft.edgemac.beta": ["microsoft edge beta"],
            "com.microsoft.edgemac.dev": ["microsoft edge dev"],
            "com.microsoft.edgemac.canary": ["microsoft edge canary"],
            "com.brave.browser": ["brave browser", "brave"],
            "com.brave.browser.beta": ["brave browser beta"],
            "com.brave.browser.nightly": ["brave browser nightly"],
            "company.thebrowser.browser": ["arc"],
            "com.vivaldi.vivaldi": ["vivaldi"],
            "com.operasoftware.opera": ["opera"],
            "com.operasoftware.operagx": ["opera gx"],
            "com.operasoftware.operanext": ["opera beta"],
            "com.operasoftware.operadeveloper": ["opera developer"],
            "com.apple.safari": ["safari"],
            "com.apple.safaritechnologypreview": ["safari technology preview"],
            "org.mozilla.firefox": ["firefox"]
        ]
    }

    enum InputKind: String, Sendable { case mouse, scroll, keyboard }

    // A silent helper cannot confirm why it is waiting. Require a continuous input
    // interval, not a slow call, a single click, or a brief burst of activity.
    private static let inputDuration: TimeInterval = 10
    private static let maximumInputGap: TimeInterval = 2

    private struct Activity: Sendable {
        let first: TimeInterval
        var last: TimeInterval
        var samples: Int
        var kind: InputKind
        var window: Int?
    }

    private struct Call: Sendable {
        let browser: Browser
        let tool: String
        let started: TimeInterval
        var activity: Activity?
    }

    private struct Pending: Sendable {
        var calls: [String: Call] = [:]
        var interrupted = false
    }
    private let pending = OSAllocatedUnfairLock(initialState: Pending())

    func observe(_ call: ComputerUseStream.NativeCall, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let message: String? = pending.withLock { state in
            switch call {
            case .started(let id, let app, let tool):
                guard state.calls[id] == nil, let browser = Browser(target: app), browser.isChromium else { return nil }
                state.calls[id] = Call(browser: browser, tool: tool, started: time)
            case .completed(let id):
                if let ended = state.calls.removeValue(forKey: id), ended.activity != nil {
                    return "computer use: browser input cleared reason=tool_completed call=\(id) tool=\(ended.tool)"
                }
            }
            return nil
        }
        if let message { Log(message) }
    }

    /// Recording input never cancels a task. Completion can clear the evidence before
    /// watch() evaluates it. Delayed or out-of-order events cannot extend an interval.
    func recordInput(bundleID: String?, path: String?, kind: InputKind, window: Int? = nil,
                     at time: TimeInterval, observedAt now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard time.isFinite, now.isFinite, time <= now, now - time <= 1 else { return }
        let messages: [String] = pending.withLock { state in
            guard !state.interrupted else { return [] }
            var messages: [String] = []
            for (id, var call) in state.calls {
                guard time >= call.started else { continue }
                guard call.browser.matches(bundleID: bundleID, path: path) else {
                    if call.activity != nil {
                        call.activity = nil
                        state.calls[id] = call
                        messages.append("computer use: browser input cleared reason=other_app call=\(id)")
                    }
                    continue
                }
                if let previous = call.activity, time <= previous.last { continue }
                if var activity = call.activity, time - activity.last <= Self.maximumInputGap {
                    activity.last = time
                    activity.samples += 1
                    activity.kind = kind
                    activity.window = window
                    call.activity = activity
                } else {
                    call.activity = Activity(first: time, last: time, samples: 1, kind: kind, window: window)
                    messages.append("computer use: browser input observed call=\(id) tool=\(call.tool) browser=\(call.browser.bundleID) source=\(kind.rawValue) window=\(window ?? 0)")
                }
                state.calls[id] = call
            }
            return messages
        }
        messages.forEach { Log($0) }
    }

    /// Require fresh input spanning the full grace period on the same unfinished call.
    /// A latch preserves a confirmed decision through process cancellation and stream drain.
    @discardableResult
    func checkForInterruption(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let messages: [String] = pending.withLock { state in
            guard !state.interrupted else { return [] }
            var messages: [String] = []
            for (id, var call) in state.calls {
                guard let activity = call.activity else { continue }
                if now - activity.last > Self.maximumInputGap {
                    call.activity = nil
                    state.calls[id] = call
                    messages.append("computer use: browser input cleared reason=quiet call=\(id)")
                } else if now >= activity.last, activity.last - activity.first >= Self.inputDuration {
                    state.interrupted = true
                    messages.append("computer use: browser interruption source=sustained_input call=\(id) tool=\(call.tool) browser=\(call.browser.bundleID) input=\(activity.kind.rawValue) window=\(activity.window ?? 0) samples=\(activity.samples) input_ms=\(Int((activity.last - activity.first) * 1000)) pending_ms=\(Int((now - call.started) * 1000))")
                    break
                }
            }
            return messages
        }
        messages.forEach { Log($0) }
        return isInterrupted
    }

    var isInterrupted: Bool { pending.withLock { $0.interrupted } }
    private var hasPendingCalls: Bool { pending.withLock { !$0.calls.isEmpty } }

    @MainActor func watch() async throws {
        // Mouse monitoring needs no key-event permission. Use the receiving window;
        // scrolling another app's background window must not blame frontmost Chrome.
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [self] event in
            guard hasPendingCalls, let cg = event.cgEvent,
                  cg.getIntegerValueField(.eventSourceUnixProcessID) == 0,
                  cg.getIntegerValueField(.eventSourceStateID) == CGEventSourceStateID.hidSystemState.rawValue,
                  let pid = Self.mouseTarget(event), let app = NSRunningApplication(processIdentifier: pid) else { return }
            // Trackpad momentum can continue after the user has stopped touching it.
            guard event.type != .scrollWheel || event.momentumPhase.isEmpty else { return }
            recordInput(bundleID: app.bundleIdentifier, path: app.bundleURL?.standardizedFileURL.path,
                        kind: event.type == .scrollWheel ? .scroll : .mouse, window: event.windowNumber, at: event.timestamp)
        }
        defer { if let mouse { NSEvent.removeMonitor(mouse) } }

        // Counters expose activity without receiving key events or inspecting characters.
        // The tested native actions did not advance this count. It is an activity signal,
        // not proof of who typed; never use one sample to interrupt a task.
        var keys = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        var front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var sampled = ProcessInfo.processInfo.systemUptime
        let activations = OSAllocatedUnfairLock(initialState: 0)
        let activated = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in activations.withLock { $0 += 1 } }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(activated) }
        var lastActivation = activations.withLock { $0 }
        while true {
            try Task.checkCancellation()
            if checkForInterruption() { throw ComputerUseStream.Interruption.browserChanged }
            try await Task.sleep(for: .milliseconds(100))
            let now = ProcessInfo.processInfo.systemUptime
            let nextKeys = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
            let app = NSWorkspace.shared.frontmostApplication
            let activation = activations.withLock { $0 }
            if nextKeys != keys, activation == lastActivation, front == app?.processIdentifier, let app, hasPendingCalls {
                let occurred = now - CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                if occurred >= sampled {
                    recordInput(bundleID: app.bundleIdentifier, path: app.bundleURL?.standardizedFileURL.path,
                                kind: .keyboard, at: occurred)
                }
            }
            keys = nextKeys; front = app?.processIdentifier; sampled = now
            lastActivation = activation
        }
    }

    @MainActor private static func mouseTarget(_ event: NSEvent) -> pid_t? {
        // Global monitor copies do not preserve eventTargetUnixProcessID; it names the
        // observing process. Window metadata contains the owner without reading UI content.
        if event.windowNumber > 0,
           let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(event.windowNumber)) as? [[String: Any]],
           let pid = rows.first?[kCGWindowOwnerPID as String] as? Int32 { return pid }
        // Do not guess from the frontmost app or pointer position when the receiving window
        // is unknown. Screen-recording and cursor overlays can cover a different app's input.
        return nil
    }
}
