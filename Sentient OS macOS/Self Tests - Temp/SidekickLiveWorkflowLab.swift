#if DEBUG
// Explicit live acceptance: real Home composer, providers and user-authorized app workflows.
// Uses SidekickAppLab's isolated conversation/defaults; no fake tools or model responses.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

@MainActor enum SidekickLiveWorkflowLab {
    enum Failure: Error { case configuration, locked, unavailable }
    private struct Command: Decodable {
        let id: String
        let kind: String
        var prompt: String?
    }

    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        let env = ProcessInfo.processInfo.environment
        guard env["SENTIENT_SELFTEST"] == "sidekickapp", env["LAB_SIDEKICK_STAGE"] == "live-workflows",
              env["LAB_SIDEKICK_LIVE"] == "1", let configured = env["LAB_SIDEKICK_ROOT"],
              root.standardizedFileURL == URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath(),
              try String(contentsOf: root.appendingPathComponent(".sidekick-app-fixture"), encoding: .utf8) == "1\n",
              let store = app.commandCoordinator.run.conversation.store else { throw Failure.configuration }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else { throw Failure.locked }
        let coordinator = app.commandCoordinator
        let run = coordinator.run
        let conversation = run.conversation
        let presentation = app.sidekickPresentation
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let captures = root.appendingPathComponent("home-captures", isDirectory: true)
        let receipts = root.appendingPathComponent("commands", isDirectory: true)
        for directory in [inbox, captures, receipts] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        MainNavigation.shared.reset()
        presentation.surface = .conversation
        let host = NSHostingView(rootView: HomeView(deck: .real).environment(app).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sentient · \(ModelBackend.current.rawValue) live workflow testing"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let notch = NotchWindowController(coordinator: coordinator)
        notch.start()
        let awake = Process()
        awake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        awake.arguments = ["-di", "-w", String(getpid())]
        try awake.run()
        defer { if awake.isRunning { awake.terminate() }; notch.shutdownForTesting(); window.close() }
        await CodexSetup.shared.refreshInstalled()
        ComputerUseGate.shared.refresh()
        await ComputerUseGate.shared.awaitAutomationRefresh()
        await presentation.load(.latest, conversation: conversation)
        // A relaunch must never repeat already-submitted real account mutations.
        var seen = Set(try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-accepted.json") }
            .map { String($0.lastPathComponent.dropLast("-accepted.json".count)) })
        var activeCommand: String?
        var activeTask: UUID?
        var started = Date()
        var nextCapture = Date()
        var captureCount = 0
        var captureErrors = 0
        var lastStatus = Date.distantPast
        var eventCursor: Int64 = 0
        var submitted = 0
        var completed = 0
        let eventsURL = root.appendingPathComponent("live-events.jsonl")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        let eventFile = try FileHandle(forWritingTo: eventsURL)
        defer { try? eventFile.close() }
        try write(["ready": true, "provider": ModelBackend.current.rawValue, "pid": getpid(),
                   "root": root.path, "runtime_ready": CodexSetup.shared.computerUseReady,
                   "permissions_ready": ComputerUseGate.shared.allRequiredGranted], to: root.appendingPathComponent("live-ready.json"))

        var finished = false
        while !finished && !Task.isCancelled {
            // This inbox is the lab driver's equivalent of typing into Home and hitting Send.
            for url in try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: url))
                guard !seen.contains(command.id), !command.id.isEmpty,
                      command.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
                if command.kind == "finish" {
                    guard !run.isRunning else { continue }
                    try write(["id": command.id, "kind": command.kind, "accepted": true],
                              to: receipts.appendingPathComponent(command.id + "-accepted.json"))
                    seen.insert(command.id); finished = true; break
                }
                if command.kind == "stop" {
                    coordinator.stop(); seen.insert(command.id)
                    try write(["id": command.id, "kind": command.kind, "accepted": true],
                              to: receipts.appendingPathComponent(command.id + "-accepted.json"))
                    continue
                }
                guard command.kind == "submit" || command.kind == "answer", let prompt = command.prompt else {
                    seen.insert(command.id); continue
                }
                if command.kind == "submit", run.isRunning || activeCommand != nil { continue }
                if command.kind == "answer", !run.recovery.isPending { continue }
                if command.kind == "submit", run.recovery.isPending { run.recovery.cancel() }
                if command.kind == "answer" { run.recovery.draft = prompt }
                else {
                    conversation.draft = prompt
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                }
                let accepted = SidekickComposer.sendDraft(coordinator: coordinator, presentation: presentation)
                seen.insert(command.id)
                try write(["id": command.id, "kind": command.kind, "accepted": accepted,
                    "task_id": run.runID.uuidString, "at": Date().timeIntervalSince1970],
                    to: receipts.appendingPathComponent(command.id + "-accepted.json"))
                if accepted && command.kind == "submit" {
                    activeCommand = command.id; activeTask = run.runID; started = Date()
                    nextCapture = Date().addingTimeInterval(2); submitted += 1
                }
            }
            let records = try store.records(after: eventCursor, limit: 500)
            for record in records {
                let data = try JSONEncoder().encode(record)
                try eventFile.write(contentsOf: data + Data([10]))
                eventCursor = record.sequence
            }
            if let id = activeCommand, Date() >= nextCapture {
                do {
                    let name = "\(id)-\(Int(Date().timeIntervalSince(started)))-\(captureCount).jpg"
                    try await capture(window, to: captures.appendingPathComponent(name))
                    captureCount += 1
                } catch { captureErrors += 1 }
                nextCapture = Date().addingTimeInterval(Date().timeIntervalSince(started) < 60 ? 5 : 20)
            }
            if let id = activeCommand, let taskID = activeTask, !run.isRunning {
                var records: [SidekickConversationStore.Record] = []
                while true {
                    let page = try store.records(taskID: taskID, after: records.last?.sequence ?? 0, limit: 500)
                    records += page
                    if page.count < 500 { break }
                }
                let outcome = records.last { $0.event.kind == .taskFinished }?.event.outcome?.rawValue ?? "unknown"
                let messages = records.filter { [.userMessage, .assistantMessage, .question, .answer, .taskFinished].contains($0.event.kind) }
                try write(["id": id, "task_id": taskID.uuidString, "outcome": outcome,
                    "elapsed_seconds": Date().timeIntervalSince(started),
                    "messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)),
                    "activity_records": records.filter { $0.event.kind == .activity }.count],
                    to: receipts.appendingPathComponent(id + "-finished.json"))
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                // The native helper may still be returning focus after its last action.
                // Wait for real Home presence rather than capturing an inactive viewport.
                for _ in 0..<30 where !conversation.isVisible {
                    try await Task.sleep(for: .milliseconds(100))
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                }
                try await Task.sleep(for: .milliseconds(650))
                do { try await capture(window, to: captures.appendingPathComponent(id + "-finished.jpg")); captureCount += 1 }
                catch { captureErrors += 1 }
                completed += 1; activeCommand = nil; activeTask = nil
            }
            if Date().timeIntervalSince(lastStatus) >= 2 {
                let recovery = run.recovery.content
                let recent = conversation.messages.suffix(8).map { ["kind": $0.event.kind.rawValue, "text": $0.event.text] }
                try write(["provider": ModelBackend.current.rawValue, "running": run.isRunning,
                    "active_command": activeCommand ?? "", "task_id": run.runID.uuidString,
                    "status": run.statusLine, "question": recovery?.question?.question ?? "",
                    "question_id": recovery?.id.uuidString ?? "", "recovery_error": recovery?.error ?? "",
                    "recent_messages": recent, "submitted": submitted, "completed": completed,
                    "captures": captureCount, "capture_errors": captureErrors,
                    "home_active": conversation.isVisible, "app_active": NSApp.isActive,
                    "follows_latest": presentation.followsLatest, "at_latest": presentation.atLatest,
                    "can_follow_latest": presentation.canFollowLatest,
                    "navigation_target": presentation.navigationTarget ?? "",
                    "scroll_request": presentation.scrollRequest,
                    "screen_locked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false,
                    "at": Date().timeIntervalSince1970], to: root.appendingPathComponent("live-status.json"))
                lastStatus = Date()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return ["real_home_composer_used": submitted > 0, "submitted_runs_finished": submitted == completed,
                "periodic_home_captures_saved": captureCount > 0, "private_test_history": true]
    }

    private static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func capture(_ window: NSWindow, to url: URL) async throws {
        guard window.isVisible else { throw Failure.unavailable }
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber)
            && $0.owningApplication?.processID == getpid() }) else { throw Failure.unavailable }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let config = SCStreamConfiguration()
        config.width = 1650; config.height = Int(1650 * own.frame.height / own.frame.width)
        config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
        config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
            properties: [.compressionFactor: 0.78]) else { throw Failure.unavailable }
        try data.write(to: url, options: .atomic)
    }
}
#endif
