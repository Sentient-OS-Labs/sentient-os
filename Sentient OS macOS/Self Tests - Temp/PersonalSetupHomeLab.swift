#if DEBUG
// Native Home interaction checks. Entry is reachable only through SidekickAppLab's isolated
// defaults/support bootstrap. No submit, provider, source permission or analysis is invoked.
import AppKit
import ApplicationServices
import SwiftUI

@MainActor enum PersonalSetupHomeLab {
    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        typealias Failure = SidekickPolishLab.Failure
        let environment = ProcessInfo.processInfo.environment
        guard environment["SENTIENT_SELFTEST"] == "sidekickapp",
              environment["LAB_SIDEKICK_STAGE"] == "ui-personal-setup",
              let configuredRoot = environment["LAB_SIDEKICK_ROOT"],
              root.standardizedFileURL == URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath(),
              UserDefaults.standard.string(forKey: "lab.fixture.nonce") != nil else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        let run = app.commandCoordinator.run
        let conversation = run.conversation
        let presentation = app.sidekickPresentation
        guard let store = conversation.store, !run.isRunning, !app.processing.initialComplete else { throw Failure.unavailable }
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        var geometry: [[String: Any]] = []
        var lastElements: [[String: Any]] = []
        var phase = "initializing"
        var accessibilityActivation: [Int] = []
        var completed = false
        var finishRequests = 0
        let memory = try SidekickInstructionStore.read().text
        let baseline = try store.latestSequence
        defer {
            let manifest: [String: Any] = ["schema": 1, "checks": checks, "captures": captures,
                "geometry": geometry, "completed": completed, "provider_calls": 0,
                "capture_scope": "current_process_windows_only", "baseline_sequence": baseline,
                "phase": phase, "last_accessibility_elements": lastElements,
                "accessibility_activation_results": accessibilityActivation]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("personal-setup-manifest.json"), options: .atomic)
            }
            run.preventsTaskExecutionForUIFixture = true
        }

        run.preventsTaskExecutionForUIFixture = true
        app.hasCompletedOnboarding = true
        app.hasCompletedPersonalSetup = false
        app.hasCompletedFirstSidekickTask = false
        if let generation = conversation.generation { conversation.markRead(through: baseline, generation: generation) }
        conversation.consumeDestination()
        presentation.surface = .suggestions
        conversation.draft = ""
        MainNavigation.shared.reset()
        let host = NSHostingView(rootView: AnyView(HomeView(deck: .real, onFinishSetup: { finishRequests += 1 })
            .environment(app)
            // Native fixture hosts have no SwiftUI App scene to activate this environment
            // when an assistive client attaches. Ask SwiftUI to expose its real semantics.
            .environment(\.accessibilityEnabled, true)
            .preferredColorScheme(.dark)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Personal setup Home · isolated fixture"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }

        func settle(_ milliseconds: Int = 300) async throws { try await SidekickPolishLab.settle(milliseconds) }
        func elements() -> [SidekickPolishLab.Element] {
            let values = SidekickPolishLab.elements(host, maximumDepth: 80)
            lastElements = values.map { ["id": $0.identifier, "role": $0.role, "label": $0.label,
                "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }
            return values
        }
        func find(_ identifier: String) -> SidekickPolishLab.Element? {
            elements().first { $0.identifier == identifier && $0.frame.width > 0 && $0.frame.height > 0 }
        }
        func click(_ identifier: String) async throws {
            phase = "click:" + identifier
            // These events enter this fixture's NSApplication queue with its exact window
            // number; they never become global desktop input. macOS can keep another app
            // active during desktop-independent capture, so global focus is not a prerequisite.
            // Retain strict ownership/visibility guards and assert each resulting UI change.
            guard window.isVisible, window.contentView === host,
                  NSApp.windows.contains(where: { $0 === window }),
                  let target = find(identifier) else { throw Failure.accessibility }
            window.makeKey()
            try SidekickPolishLab.postClick(window: window, screenPoint: CGPoint(x: target.frame.midX, y: target.frame.midY))
            try await settle()
        }
        func capture(_ name: String) async throws {
            captures.append(try await SidekickPolishLab.capture(host, name: name, directory: directory))
        }
        func escape() async throws {
            phase = "escape"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { throw Failure.accessibility }
            NSApp.postEvent(event, atStart: false)
            try await settle()
        }
        func recordLayout(_ name: String) {
            phase = "layout:" + name
            let nodes = elements()
            let content = window.convertToScreen(host.convert(host.bounds, to: nil))
            let ids = ["personalSetup.finish", "sidekick.composer"]
                + HomePersonalFeature.allCases.map { "personalSetup.feature." + $0.rawValue }
                + HomeSidekickSuggestions.suggestions.map { "sidekick.suggestion." + $0.id }
            checks[name + "_all_controls_fit"] = ids.allSatisfy { identifier in
                nodes.contains { $0.identifier == identifier && $0.frame.width > 0 && content.insetBy(dx: -1, dy: -1).contains($0.frame) }
            }
            if let finish = find("personalSetup.finish"), let composer = find("sidekick.composer"),
               let lastFeature = find("personalSetup.feature.sidekick") {
                checks[name + "_setup_below_rewards"] = finish.frame.maxY < lastFeature.frame.minY
                checks[name + "_workspace_left_of_setup"] = composer.frame.maxX < finish.frame.minX
                checks[name + "_suggestions_above_composer"] = HomeSidekickSuggestions.suggestions.allSatisfy {
                    find("sidekick.suggestion." + $0.id).map { $0.frame.minY > composer.frame.maxY } == true
                }
            }
            geometry.append(["name": name, "width": host.bounds.width, "height": host.bounds.height,
                "accessibility_element_count": nodes.count,
                "controls": nodes.filter { ids.contains($0.identifier) }.map {
                    ["id": $0.identifier, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]]
                }])
        }

        for _ in 0..<30 {
            if !window.isKeyWindow || !NSApp.isActive {
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
            try await settle(100)
            if window.isKeyWindow && NSApp.isActive { break }
        }
        try await settle(600)
        // SwiftUI builds its semantic accessibility tree lazily for an actual AX client.
        // Asking the current process through the public API is read-only; doing it off-main
        // lets AppKit answer the request instead of deadlocking this same process's server.
        accessibilityActivation.append(await SidekickPolishLab.activateOwnAccessibility())
        try await settle(300)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("personal-setup-manual-review").path) {
            phase = "awaiting_manual_accessibility_review"
            let checkpoint: [String: Any] = ["phase": phase, "pid": getpid(), "window_id": window.windowNumber,
                "title": window.title, "continue_file": "continue-personal-setup-review", "timeout_seconds": 90]
            try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("personal-setup-review-ready.json"), options: .atomic)
            let continueFile = root.appendingPathComponent("continue-personal-setup-review")
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while !FileManager.default.fileExists(atPath: continueFile.path), ContinuousClock.now < deadline {
                try await settle(250)
            }
            guard FileManager.default.fileExists(atPath: continueFile.path) else { throw Failure.accessibility }
            accessibilityActivation.append(await SidekickPolishLab.activateOwnAccessibility())
            try await settle(300)
        }
        checks["starts_with_all_examples_closed"] = !elements().contains { $0.identifier.hasPrefix("personalSetup.preview.") }
        checks["pending_setup_admits_sidekick"] = find("sidekick.composer") != nil && find("sidekick.readyInvitation") != nil
        checks["pending_setup_has_four_rewards"] = HomePersonalFeature.allCases.allSatisfy { find("personalSetup.feature." + $0.rawValue) != nil }
        recordLayout("standard")
        try await capture("personal-setup-01-standard")
        window.setContentSize(CGSize(width: 840, height: 680)); try await settle(450)
        recordLayout("minimum")
        try await capture("personal-setup-02-minimum")

        for feature in HomePersonalFeature.allCases {
            try await click("personalSetup.feature." + feature.rawValue)
            guard let preview = find("personalSetup.preview." + feature.rawValue),
                  let close = find("personalSetup.preview.close"), let composer = find("sidekick.composer") else { throw Failure.accessibility }
            checks[feature.rawValue + "_close_top_left"] = close.frame.midX < preview.frame.midX && close.frame.midY > preview.frame.midY
            checks[feature.rawValue + "_preview_above_composer"] = preview.frame.minY > composer.frame.maxY
            try await capture("personal-setup-example-" + feature.rawValue)
            try await click("personalSetup.preview.close")
            checks[feature.rawValue + "_close_dismisses"] = find("personalSetup.preview." + feature.rawValue) == nil
            try await click("personalSetup.feature." + feature.rawValue)
            try await escape()
            checks[feature.rawValue + "_escape_dismisses"] = find("personalSetup.preview." + feature.rawValue) == nil
        }

        for suggestion in HomeSidekickSuggestions.suggestions {
            try await click("sidekick.suggestion." + suggestion.id)
            let sequence = try store.latestSequence
            checks[suggestion.id + "_fills_existing_draft"] = conversation.draft == suggestion.prompt
            checks[suggestion.id + "_never_submits"] = !run.isRunning && run.interaction == nil && sequence == baseline
        }
        let draft = conversation.draft
        try await click("personalSetup.finish")
        checks["finish_setup_only_calls_flow"] = finishRequests == 1 && !app.processing.isBusy
            && conversation.draft == draft && !app.hasCompletedPersonalSetup

        // Open an example over stored history, then start an explicitly simulated local run.
        presentation.surface = .conversation
        await presentation.load(.latest, conversation: conversation)
        try await settle()
        try await click("personalSetup.feature.sidekick")
        let sequenceBeforeSimulation = try store.latestSequence
        checks["example_preserves_conversation_and_draft"] = presentation.surface == .conversation
            && conversation.draft == draft && sequenceBeforeSimulation == baseline
        run.preventsTaskExecutionForUIFixture = false
        run.adoptExternal(caption: "Preparing the fixture brief…", request: "Synthetic Home UI check", onStopRequest: {})
        run.preventsTaskExecutionForUIFixture = true
        try await settle(600)
        checks["running_task_closes_preview"] = run.isRunning && find("personalSetup.preview.sidekick") == nil
            && presentation.surface == .conversation && find("sidekick.stop") != nil
        try await click("personalSetup.feature.knowledge")
        checks["running_task_cannot_be_covered"] = find("personalSetup.preview.knowledge") == nil && run.isRunning
        try await capture("personal-setup-03-running")
        let task = run.runID
        run.completeExternal(.success, line: "Fixture complete", finalText: "STATUS: DONE", runID: task)
        conversation.beginMaintenance()
        try await settle(450)
        checks["successful_task_preserves_draft"] = conversation.draft == draft

        app.hasCompletedFirstSidekickTask = true
        presentation.surface = .suggestions
        window.setContentSize(CGSize(width: 1040, height: 800)); try await settle(350)
        checks["after_first_success_setup_stays_optional"] = find("personalSetup.finish") != nil && find("sidekick.composer") != nil
        try await capture("personal-setup-04-after-success")

        // Use the real-card view path with an isolated synthetic card. No click executes it.
        app.hasCompletedPersonalSetup = true
        let action = PreparedAction(title: "Synthetic customer brief", method: .research, target: "", urgency: .medium,
            dueDate: "Tomorrow", status: .confirmed, verification: "", cardSummary: "Fixture feedback and the next steps.",
            preparedContent: "A synthetic local brief.", executionRecipe: "none", buttonText: "", detailLabel: "Read the brief",
            sources: [], reviewNote: "")
        presentation.cards.entries = [.init(b: Briefing(from: action), action: action, phase: .offer, dealt: true)]
        try await settle(550)
        checks["completed_setup_keeps_real_cards"] = find("personalSetup.panel") == nil
            && elements().contains { $0.label == "Synthetic customer brief" }
            && presentation.cards.entries.first?.action != nil
        checks["completed_setup_keeps_composer_and_history"] = find("sidekick.composer") != nil && conversation.draft == draft
            && conversation.generation != nil
        try await capture("personal-setup-05-completed-cards")

        // Only this isolated fixture's chat is cleared, after all preservation assertions.
        // This gives the genuinely empty first-Home screenshot without changing production data.
        conversation.endMaintenance()
        try await app.commandCoordinator.clearChat()
        presentation.didClearChat(generation: conversation.generation)
        app.hasCompletedPersonalSetup = false
        app.hasCompletedFirstSidekickTask = false
        presentation.cards.entries = []
        presentation.surface = .suggestions
        try await settle(450)
        checks["first_home_has_empty_history"] = conversation.messages.isEmpty && conversation.draft.isEmpty
            && find("sidekick.expandHistory") == nil && find("sidekick.readyInvitation") != nil
            && find("personalSetup.finish") != nil && find("sidekick.composer") != nil
        try await capture("personal-setup-06-empty-first-home")
        let presentationCapture = FileManager.default.fileExists(atPath: root.appendingPathComponent("personal-setup-presentation-capture").path)
        if presentationCapture {
            window.setContentSize(CGSize(width: 1280, height: 760))
            window.center()
            try await settle(700)
            recordLayout("presentation")
            checks["presentation_window_fully_visible"] = window.screen?.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame) == true
            try await capture("personal-setup-07-full-window")
        }
        checks["personal_setup_never_starts_analysis"] = !app.processing.isBusy && !app.processing.initialComplete
        checks["saved_instructions_preserved"] = try SidekickInstructionStore.read().text == memory
        checks["expected_owned_window_captures"] = captures.count == (presentationCapture ? 11 : 10)
        completed = true; phase = "complete"
        return checks
    }


}
#endif
