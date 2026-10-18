#if DEBUG
import AppKit
import CryptoKit
import Foundation
import ScreenCaptureKit
import SwiftUI

/// Own-window rendering only. This entry is called after SidekickAppLab installs its isolated
/// preferences/support root. Direct fixture events never launch a provider or computer-use task.
@MainActor enum SidekickUILab {
    enum Failure: String, Error { case unavailable, invalidFixture, snapshot, screenCapturePermission, providerStarted, screenLocked }
    private typealias Event = SidekickConversationEvent
    private static let source = "ui_fixture"
    private static let draft = "Can you help me find a quiet hour tomorrow?"
    private static let calendarAnswer = "You're free **2:30–4:00 PM tomorrow**. That gives you a quiet 90-minute block after your design review.\n\nI can help protect that time when you're ready."
    private static let researchAnswer = "I found three useful directions for the launch:\n\n- **Start with the existing community.** Share what changed since July.\n  - Include one clear before-and-after example.\n  - Invite people to try a small task.\n- Keep the announcement short and link to the full notes.\n\n> The strongest story is the one people can try for themselves."
    private static let markdownAnswer = """
    ## A small plan for tomorrow

    Your afternoon has room for one focused session.

    1. Finish the **calendar research**.
       - Compare the two open windows.
       - Leave a little travel time.
    2. Pick the slot that feels easiest.

    | Option | Time | Duration |
    |:--|:--|--:|
    | Deep work | 2:30 PM | 90 min |
    | Quick review | 5:00 PM | 30 min |

    ```swift
    let tomorrow = "A little less busy"
    print(tomorrow)
    ```

    [Read the planning guide](https://example.com/planning) when you have a minute.
    """

    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "sidekickapp",
              ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui",
              let store = app.commandCoordinator.run.conversation.store else { throw Failure.unavailable }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            throw Failure.screenLocked
        }
        let coordinator = app.commandCoordinator
        let conversation = coordinator.run.conversation
        let presentation = app.sidekickPresentation
        guard !coordinator.run.isRunning, coordinator.run.interaction == nil else { throw Failure.providerStarted }
        let directory = root.appendingPathComponent("ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        let generation = try store.generation
        let beforeSequence = try store.latestSequence
        let baselineMemory = try SidekickInstructionStore.read().text
        var fixtureIDs: [UUID] = []
        var answers: [String] = []
        let now = Date()
        let fixedDate = now.addingTimeInterval(-3 * 24 * 60 * 60)

        func appendTask(_ index: Int, request: String, answer: String, priority: Event.Priority = .normal,
                        duration: TimeInterval = 2, activity: Bool = false) throws -> String {
            let task = UUID(); fixtureIDs.append(task)
            let date = index == 45 ? now.addingTimeInterval(-5_400)
                : index == 46 ? now.addingTimeInterval(-4_800)
                : index == 47 ? now.addingTimeInterval(-120)
                : fixedDate.addingTimeInterval(Double(index) * 90)
            let id = "ui.answer.\(index)"
            _ = try store.append(.init(id: "ui.start.\(index)", taskID: task, kind: .taskStarted, createdAt: date, source: source), expectedGeneration: generation)
            _ = try store.append(.init(id: "ui.request.\(index)", taskID: task, kind: .userMessage, text: request, createdAt: date, source: source), expectedGeneration: generation)
            if activity {
                let tools = ["sentient_native.get_app_state", "sentient_native.click", "sentient_recovery.read_memory", "sentient_native.get_app_state"]
                let titles = ["Checked tomorrow’s calendar", "Opened the afternoon schedule", "Read your meeting preferences", "Verified the free time block"]
                for step in tools.indices {
                    var arguments = ["title": titles[step]]
                    if step != 2 { arguments["app"] = "com.apple.iCal" }
                    let raw = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
                    for status in [Event.Activity.Status.started, .completed] {
                        _ = try store.append(.init(id: "ui.activity.\(index).\(step).\(status.rawValue)", taskID: task,
                            kind: .activity, text: tools[step], createdAt: date.addingTimeInterval(Double(step * 18 + (status == .started ? 5 : 10))),
                            source: source, activity: .init(toolID: "ui-tool-\(step)", name: tools[step], arguments: raw,
                                result: status == .completed ? "Synthetic fixture result." : nil, status: status)), expectedGeneration: generation)
                    }
                }
            }
            _ = try store.append(.init(id: id, taskID: task, kind: .assistantMessage, text: answer, createdAt: date.addingTimeInterval(duration - 1), source: source, messageKind: .answer, priority: priority), expectedGeneration: generation)
            _ = try store.append(.init(id: "ui.finish.\(index)", taskID: task, kind: .taskFinished, text: "Done", createdAt: date.addingTimeInterval(duration), source: source, outcome: .success), expectedGeneration: generation)
            answers.append(id); return id
        }
        for index in 0..<45 {
            _ = try appendTask(index, request: "Help me plan my afternoon, check \(index + 1).",
                answer: "You have a quiet window after your next meeting. Keep one small thing for tomorrow.")
        }
        let researchID = try appendTask(45, request: "What should we focus on for the launch?", answer: researchAnswer, duration: 22)
        let markdownID = try appendTask(46, request: "Can you turn that into a clear plan?", answer: markdownAnswer, duration: 18)
        let calendarID = try appendTask(47, request: "Research my calendar and let me know when I'm free tomorrow.", answer: calendarAnswer, priority: .high, duration: 84, activity: true)
        try store.markRead(throughSequence: store.latestSequence, expectedGeneration: generation)
        conversation.refresh()
        conversation.beginMaintenance() // visible fixture controls cannot start a provider
        presentation.surface = .suggestions
        conversation.draft = ""
        // Exercise the same deep link a notch pop-out sends before Home first mounts.
        // Its history read must win over initial transcript loading regardless of task order.
        conversation.show(messageID: answers[2])
        let host = NSHostingView(rootView: home(app, reduced: false, opaque: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sidekick UI fixture · synthetic content"
        window.isReleasedWhenClosed = false
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            coordinator.run.recovery.cancel()
            window.close()
        }
        try await settle(1_100)
        checks["ui_initial_deep_link_owns_navigation"] = conversation.navigationRequest == nil
            && presentation.navigationTarget == answers[2]
            && presentation.rows.contains { $0.event.id == answers[2] }
            && presentation.hasLater
        conversation.requestNavigation()
        try await settle(500)
        checks["ui_explicit_latest_leaves_older_history"] = conversation.navigationRequest == nil
            && presentation.navigationTarget == "sidekick-bottom" && !presentation.hasLater
            && presentation.rows.contains { $0.event.id == calendarID }
        presentation.surface = .suggestions
        try await settle(600)
        captures.append(try await capture(host, name: "01-overview-1100", directory: directory))
        checks["ui_demo_cards_available"] = !presentation.cards.entries.isEmpty
        window.setContentSize(NSSize(width: 840, height: 680))
        try await settle(650)
        captures.append(try await capture(host, name: "01b-overview-840", directory: directory))
        // Real caution presentation in the owned defaults suite: the header must make room
        // for a multiline notice, including while the transcript is open at minimum size.
        let originalCautions = UserDefaults.standard.data(forKey: ConnectorCaution.key)
        defer {
            if let originalCautions { UserDefaults.standard.set(originalCautions, forKey: ConnectorCaution.key) }
            else { UserDefaults.standard.removeObject(forKey: ConnectorCaution.key) }
        }
        UserDefaults.standard.set(try JSONEncoder().encode([
            ConnectorCaution.Item(slug: "ui-fixture-calendar", name: "Your synthetic calendar and work account")
        ]), forKey: ConnectorCaution.key)
        try await settle(650)
        captures.append(try await capture(host, name: "01b-overview-840-notice", directory: directory))
        presentation.surface = .conversation
        try await settle(650)
        captures.append(try await capture(host, name: "01b-chat-840-notice", directory: directory))
        presentation.surface = .suggestions
        if let originalCautions { UserDefaults.standard.set(originalCautions, forKey: ConnectorCaution.key) }
        else { UserDefaults.standard.removeObject(forKey: ConnectorCaution.key) }
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        try await settle(650)
        captures.append(try await capture(host, name: "01c-overview-wide", directory: directory))
        host.rootView = home(app, reduced: false, opaque: false, hoveredCard: Briefing.jesaiDemo[0].id)
        try await settle(350)
        captures.append(try await capture(host, name: "01d-card-dismiss-hover", directory: directory))
        host.rootView = home(app, reduced: false, opaque: false)
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.center()
        try await settle(500)

        // Feed phase-bearing input into the actual mounted probe's policy/callback path.
        // This never posts an event to the user's desktop; real event-to-window routing is
        // checked separately through native interaction and the pure policy suite.
        guard let scrollProbe = overviewProbes(host).first(where: { $0.enabled }) else { throw Failure.invalidFixture }
        _ = scroll(scrollProbe, by: 40, phase: .began)
        try await settle(80)
        checks["ui_scroll_partial_keeps_overview"] = presentation.surface == .suggestions && scrollProbe.policy.distance == 40
        captures.append(try await capture(host, name: "22-scroll-pull-40", directory: directory))
        _ = scroll(scrollProbe, by: 50)
        try await settle(80)
        captures.append(try await capture(host, name: "23-scroll-pull-90", directory: directory))
        _ = scroll(scrollProbe, by: -35)
        try await settle(80)
        checks["ui_scroll_reverses_live"] = scrollProbe.policy.distance == 55 && presentation.surface == .suggestions
        captures.append(try await capture(host, name: "24-scroll-reversed-55", directory: directory))
        _ = scroll(scrollProbe, by: 0, phase: .ended)
        try await settle(500)
        checks["ui_scroll_partial_end_settles"] = scrollProbe.policy.distance == 0 && presentation.surface == .suggestions
        captures.append(try await capture(host, name: "25-scroll-settled", directory: directory))
        let scrollMotion = try await SidekickUIRecording.record(window: window,
            url: directory.appendingPathComponent("scroll-motion.mp4"), duration: 4.4) { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
                for index in 0..<12 {
                    _ = scroll(scrollProbe, by: 7, phase: index == 0 ? .began : .changed)
                    try await Task.sleep(for: .milliseconds(32))
                }
                for _ in 0..<8 {
                    _ = scroll(scrollProbe, by: -7)
                    try await Task.sleep(for: .milliseconds(32))
                }
                _ = scroll(scrollProbe, by: 0, phase: .ended)
                try await Task.sleep(for: .milliseconds(650))
                for index in 0..<21 {
                    _ = scroll(scrollProbe, by: 7, phase: index == 0 ? .began : .changed)
                    try await Task.sleep(for: .milliseconds(28))
                }
                _ = scroll(scrollProbe, by: 0, phase: .ended)
                _ = scroll(scrollProbe, by: 0, phase: [], momentum: .ended)
            } catch { return }
        }
        checks["ui_scroll_commit_opens_chat"] = presentation.surface == .conversation && !scrollProbe.policy.consuming
        try saveMotion(scrollMotion, name: "scroll", root: root)
        checks["ui_scroll_motion_recorded"] = scrollMotion["writer_completed"] as? Bool == true

        conversation.draft = draft
        withAnimation(SidekickStyle.motion(false)) { presentation.surface = .conversation }
        await presentation.load(.latest, conversation: conversation)
        for (index, delay) in [0, 150, 150, 300].enumerated() {
            try await settle(delay)
            captures.append(try await capture(host, name: "02-transition-\([0, 150, 300, 600][index])ms", directory: directory))
        }
        checks["ui_draft_survives_surface_transition"] = conversation.draft == draft
        checks["ui_latest_page_is_bounded"] = presentation.rows.count <= 100 && presentation.hasEarlier
        checks["ui_actual_native_message_text"] = nativeTexts(host).contains { $0.contains("quiet 90-minute") }
        captures.append(try await capture(host, name: "03-conversation-1100", directory: directory))
        host.rootView = home(app, reduced: false, opaque: false, hoveredMessage: calendarID)
        try await settle(350)
        captures.append(try await capture(host, name: "14-response-hover", directory: directory))
        host.rootView = home(app, reduced: false, opaque: false, hoveredMessage: "ui.request.47")
        try await settle(350)
        captures.append(try await capture(host, name: "15-prompt-hover", directory: directory))
        host.rootView = home(app, reduced: false, opaque: false)
        let calendarTask = try store.record(id: calendarID)!.event.taskID
        presentation.expandedWorkTasks.insert(calendarTask)
        presentation.navigationTarget = calendarID; presentation.scrollRequest &+= 1
        try await settle(650)
        captures.append(try await capture(host, name: "16-inline-activity", directory: directory))
        checks["ui_work_duration_uses_recorded_task"] = SidekickTranscriptLayout.workLabel(
            state: presentation.taskStates[calendarTask], running: false, waiting: false) == "Worked for 1m 24s"
        checks["ui_activity_coalesces_lifecycle_events"] = SidekickActivityPresentation.steps(try store.activityRecords(taskID: calendarTask)).count == 4
        checks["ui_activity_expansion_preserves_draft"] = conversation.draft == draft
        let workMotion = try await SidekickUIRecording.record(window: window,
            url: directory.appendingPathComponent("activity-motion.mp4"), duration: 3.8) { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
                presentation.expandedWorkTasks.remove(calendarTask)
                try await Task.sleep(for: .milliseconds(650))
                presentation.expandedWorkTasks.insert(calendarTask)
                try await Task.sleep(for: .milliseconds(800))
                presentation.expandedWorkTasks.remove(calendarTask)
                try await Task.sleep(for: .milliseconds(100))
                presentation.expandedWorkTasks.insert(calendarTask)
            } catch { return }
        }
        try saveMotion(workMotion, name: "activity", root: root)
        checks["ui_activity_motion_recorded"] = workMotion["writer_completed"] as? Bool == true
        checks["ui_activity_rapid_reversal_preserves_draft"] = presentation.expandedWorkTasks.contains(calendarTask) && conversation.draft == draft
        presentation.expandedWorkTasks.remove(calendarTask)
        await presentation.load(.latest, conversation: conversation)
        try await settle(350)
        // Selection alone, without a context menu, must expose the real floating action.
        if let selectedView = markdownViews(host).first(where: { $0.source == calendarAnswer && $0.string.contains("quiet 90-minute") }) {
            window.makeFirstResponder(selectedView)
            let selection = (selectedView.string as NSString).range(of: "2:30–4:00 PM tomorrow")
            guard selection.location != NSNotFound else { throw Failure.invalidFixture }
            selectedView.setSelectedRange(selection)
            try await settle(250)
            guard let popup = SidekickMarkdownTextView.selectionReplyWindowForTesting else { throw Failure.invalidFixture }
            checks["ui_selection_reply_visible_without_context_menu"] = popup.isVisible && popup.parent === window
            checks["ui_selection_reply_does_not_take_focus"] = !popup.isKeyWindow && window.firstResponder === selectedView
            captures.append(try await capture(host, name: "04a-floating-selection-reply", directory: directory, expectedChild: popup))
            window.makeFirstResponder(nil)
            try await settle(40) // selection observations intentionally defer out of AppKit reconciliation
            checks["ui_leaving_selection_releases_autofollow"] = !presentation.textSelected
            window.makeFirstResponder(selectedView)
            try await settle(40)
            checks["ui_returning_to_selection_protects_reading"] = presentation.textSelected
            selectedView.perform(NSSelectorFromString("replyToSelection"))
            checks["ui_selection_reply_uses_exact_source"] = conversation.replyReference?.messageID == calendarID
                && conversation.replyReference?.selectedText.map { calendarAnswer.contains($0) && $0.contains("2:30") } == true
            checks["ui_selection_reply_preserves_draft"] = conversation.draft == draft
            conversation.replyReference = nil
            try await settle(200)
            checks["ui_selection_reply_dismisses_after_action"] = SidekickMarkdownTextView.selectionReplyWindowForTesting == nil
        } else { throw Failure.invalidFixture }

        // A real frame-timed recording, separate from the intentionally slower PNG states.
        let motion: [String: Any]
        do {
        motion = try await SidekickUIRecording.record(window: window,
            url: directory.appendingPathComponent("home-motion.mp4"), duration: 4.2) { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
                withAnimation(SidekickStyle.motion(false)) { presentation.surface = .suggestions }
                try await Task.sleep(for: .milliseconds(1600))
                withAnimation(SidekickStyle.motion(false)) { presentation.surface = .conversation }
            } catch { return }
        }
        } catch {
            let failure: [String: Any] = ["reason": (error as? SidekickUIRecording.Failure)?.rawValue ?? "system_failure",
                "domain": (error as NSError).domain, "code": (error as NSError).code]
            try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("ui-motion-failure.json"), options: .atomic)
            throw error
        }
        checks["ui_motion_recording_completed"] = motion["writer_completed"] as? Bool == true
            && (motion["written_frames"] as? Int ?? 0) >= 20
        try JSONSerialization.data(withJSONObject: motion, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("ui-motion.json"), options: .atomic)

        // Reverse a live transition, then finish in the transcript. The draft belongs to the
        // app, not to either mounted composer or the animated suggestions layer.
        withAnimation(SidekickStyle.motion(false)) { presentation.surface = .suggestions }
        try await settle(150)
        withAnimation(SidekickStyle.motion(false)) { presentation.surface = .conversation }
        try await settle(600)
        checks["ui_draft_survives_interrupted_animation"] = conversation.draft == draft

        conversation.replyReference = .init(messageID: calendarID, selectedText: "2:30–4:00 PM tomorrow")
        try await settle(550)
        captures.append(try await capture(host, name: "04-selected-reply", directory: directory))
        checks["ui_reply_reference_exact"] = try store.record(id: calendarID)?.event.text.contains(conversation.replyReference!.selectedText!) == true
        conversation.replyReference = nil

        presentation.searchShown = true; presentation.search = "calendar research"
        await presentation.find(conversation: conversation)
        try await settle(350)
        checks["ui_search_receives_keyboard_focus"] = (window.firstResponder as? NSTextView).map { $0.isEditable && $0.string == presentation.search } == true
        captures.append(try await capture(host, name: "05-history-search", directory: directory))
        checks["ui_search_finds_saved_markdown"] = presentation.searchResults.contains { $0.event.id == markdownID }
        presentation.search = ""; presentation.searchShown = false
        await presentation.load(.around(answers[2]), conversation: conversation)
        checks["ui_older_target_loaded"] = presentation.rows.contains { $0.event.id == answers[2] }
            && presentation.navigationTarget == answers[2] && presentation.hasLater
        if let cursor = presentation.rows.first?.sequence {
            await presentation.load(.earlier(cursor), conversation: conversation)
            checks["ui_earlier_page_bounded_sorted"] = presentation.rows.count <= 100
                && presentation.rows.map(\.sequence) == presentation.rows.map(\.sequence).sorted()
        }
        if let cursor = presentation.rows.last?.sequence {
            await presentation.load(.later(cursor), conversation: conversation)
            checks["ui_later_page_bounded_sorted"] = presentation.rows.count <= 100
                && presentation.rows.map(\.sequence) == presentation.rows.map(\.sequence).sorted()
        }
        let replacementGeneration = UUID()
        presentation.resetForGeneration(replacementGeneration)
        checks["ui_generation_clears_stale_page"] = presentation.rows.isEmpty && presentation.searchResults.isEmpty
            && presentation.generation == replacementGeneration && conversation.draft == draft
        await presentation.load(.around(markdownID), conversation: conversation)
        checks["ui_target_reloads_correct_generation"] = presentation.generation == generation
            && presentation.rows.contains { $0.event.id == markdownID }
        try await settle(650)
        captures.append(try await capture(host, name: "06-long-markdown", directory: directory))
        checks["ui_native_markdown_text_present"] = nativeTexts(host).contains { $0.contains("small plan for tomorrow") }

        window.setContentSize(NSSize(width: 840, height: 680))
        try await settle(550)
        captures.append(try await capture(host, name: "07-conversation-840", directory: directory))
        checks["ui_small_window_has_composer"] = host.bounds.width >= 840 && conversation.draft == draft
        window.setContentSize(NSSize(width: 1100, height: 820))
        host.rootView = home(app, reduced: true, opaque: true)
        try await settle(600)
        presentation.surface = .conversation
        await presentation.load(.around(researchID), conversation: conversation)
        try await settle(300)
        captures.append(try await capture(host, name: "08-reduced-motion-transparency", directory: directory))
        window.appearance = NSAppearance(named: .aqua)
        try await settle(300)
        captures.append(try await capture(host, name: "09-system-light-appearance", directory: directory))
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle(300)
        captures.append(try await capture(host, name: "10-system-dark-appearance", directory: directory))
        host.rootView = home(app, reduced: false, opaque: false)

        // An actual recovery presentation, backed by real fixture question/answer events.
        let questionTask = UUID(); fixtureIDs.append(questionTask)
        let question = try SidekickQuestion(error: nil, question: "Would you like me to protect the longer afternoon block or keep your calendar open?", answers: ["Protect the afternoon", "Keep it open"])
        _ = try store.append(.init(id: "ui.question.start", taskID: questionTask, kind: .taskStarted, source: source), expectedGeneration: generation)
        _ = try store.append(.init(id: "ui.question.request", taskID: questionTask, kind: .userMessage, text: "Help me choose what to do with that time.", source: source), expectedGeneration: generation)
        _ = try store.append(.init(id: "ui.question", taskID: questionTask, kind: .question, text: question.question, source: source, choices: question.answers), expectedGeneration: generation)
        coordinator.run.recovery.present(.clarification(question)) { resolution in
            guard case .answered(let answer) = resolution else { return }
            do {
                _ = try store.append(.init(id: "ui.question.answer", taskID: questionTask, kind: .answer,
                    text: answer.text, source: source, reply: .init(messageID: "ui.question")), expectedGeneration: generation)
                _ = try store.append(.init(id: "ui.question.finish", taskID: questionTask, kind: .taskFinished,
                    text: "Answered", source: source, outcome: .success), expectedGeneration: generation)
            } catch { checks["ui_question_persisted"] = false }
        }
        coordinator.run.recovery.setFocused(true)
        conversation.refresh(); presentation.surface = .conversation
        await presentation.load(.latest, conversation: conversation)
        try await settle(600)
        captures.append(try await capture(host, name: "11-pending-question", directory: directory))
        checks["ui_pending_question_is_real_recovery"] = coordinator.run.recovery.content?.question?.id == question.id
            && !coordinator.run.isRunning

        let metrics = NotchMetrics(availableSize: CGSize(width: 1440, height: 900), hardwareNotch: CGSize(width: 200, height: 32))
        let notchHost = NSHostingView(rootView: notch(phase: .recovery, metrics: metrics, recovery: coordinator.run.recovery, message: nil))
        let notchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        notchWindow.title = "Sidekick notch UI fixture"
        notchWindow.isReleasedWhenClosed = false
        notchWindow.contentView = notchHost; notchWindow.center(); notchWindow.makeKeyAndOrderFront(nil)
        defer { notchWindow.close() }
        try await settle(550)
        captures.append(try await capture(notchHost, name: "12-notch-question", directory: directory))
        // Also exercise the real top-of-screen NSPanel and its interrupted window lifecycle.
        window.orderOut(nil); notchWindow.orderOut(nil)
        try await settle(150)
        checks.merge(try await SidekickNativeNotchLab.run(coordinator: coordinator, root: root)) { _, new in new }
        notchWindow.makeKeyAndOrderFront(nil)
        await presentation.load(.around(answers[2]), conversation: conversation)
        coordinator.run.recovery.draft = "Keep it open"
        checks["ui_composer_accepts_pending_answer"] = SidekickComposer.sendDraft(coordinator: coordinator, presentation: presentation)
        try await settle(500)
        checks["ui_answer_returns_to_latest"] = conversation.navigationRequest == nil
            && presentation.navigationTarget == "sidekick-bottom" && !presentation.hasLater
            && presentation.rows.contains { $0.event.id == "ui.question.answer" }
        checks["ui_question_persisted"] = try store.record(id: "ui.question.answer")?.event.text == "Keep it open"
        checks["ui_answer_keeps_unrelated_draft"] = conversation.draft == draft
        let message = try store.record(id: calendarID)
        notchHost.rootView = notch(phase: .message, metrics: metrics, recovery: nil, message: message)
        try await settle(600)
        captures.append(try await capture(notchHost, name: "13-notch-message", directory: directory))
        checks["ui_notch_native_text_present"] = nativeTexts(notchHost).contains { $0.contains("quiet 90-minute") }

        let failedRecovery = SidekickRecovery()
        failedRecovery.present(.failure(id: UUID(), error: "I couldn’t finish this step. Add a detail to help me continue.")) { _ in }
        failedRecovery.setFocused(true)
        notchHost.rootView = notch(phase: .recovery, metrics: metrics, recovery: failedRecovery, message: nil)
        try await settle(450)
        captures.append(try await capture(notchHost, name: "13b-notch-empty-retry", directory: directory))
        checks["ui_failure_reply_starts_empty"] = failedRecovery.draft.isEmpty
        failedRecovery.cancel()

        // Exercise the real retained-page shell, not a duplicate Settings animation.
        // Self-test startup already isolates preferences/vault and disables provider submission.
        notchWindow.orderOut(nil)
        let navigation = MainNavigation.shared
        navigation.reset()
        let originalDeck = UserDefaults.standard.object(forKey: BriefingDeck.key)
        UserDefaults.standard.set(BriefingDeck.jesai.rawValue, forKey: BriefingDeck.key)
        defer {
            navigation.reset()
            if let originalDeck { UserDefaults.standard.set(originalDeck, forKey: BriefingDeck.key) }
            else { UserDefaults.standard.removeObject(forKey: BriefingDeck.key) }
        }
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.identifier = NSUserInterfaceItemIdentifier(SentientOSApp.homeWindowID)
        host.rootView = rootPage(app, reduced: false)
        window.center(); window.makeKeyAndOrderFront(nil)
        try await settle(700)
        conversation.requestNavigation()
        try await settle(400)
        navigation.show(.settings, settingsPane: .proactive)
        try await settle(110)
        captures.append(try await capture(host, name: "17-settings-opening", directory: directory))
        try await settle(650)
        captures.append(try await capture(host, name: "18-settings-open", directory: directory))
        checks["ui_settings_keeps_home_inert"] = !conversation.isVisible && !presentation.composerFocused
        checks["ui_settings_preserves_draft"] = conversation.draft == draft
        navigation.show(.home)
        try await settle(110)
        captures.append(try await capture(host, name: "19-settings-closing", directory: directory))
        try await settle(650)
        captures.append(try await capture(host, name: "20-home-after-settings", directory: directory))
        checks["ui_settings_return_preserves_conversation"] = conversation.draft == draft
            && presentation.surface == .conversation && !coordinator.run.isRunning

        let settingsMotion = try await SidekickUIRecording.record(window: window,
            url: directory.appendingPathComponent("settings-motion.mp4"), duration: 4.2) { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
                navigation.show(.settings)
                try await Task.sleep(for: .milliseconds(1100))
                navigation.show(.home)
                try await Task.sleep(for: .milliseconds(750))
                navigation.show(.settings)
                try await Task.sleep(for: .milliseconds(90))
                navigation.show(.home)
            } catch { return }
        }
        checks["ui_settings_reversal_keeps_current_route"] = navigation.page == .home && conversation.draft == draft
        checks["ui_settings_motion_recording_completed"] = settingsMotion["writer_completed"] as? Bool == true
            && (settingsMotion["written_frames"] as? Int ?? 0) >= 20
        try JSONSerialization.data(withJSONObject: settingsMotion, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("ui-settings-motion.json"), options: .atomic)

        host.rootView = rootPage(app, reduced: true)
        window.setContentSize(NSSize(width: 1040, height: 800))
        navigation.show(.settings)
        try await settle(400)
        captures.append(try await capture(host, name: "21-settings-reduced-motion", directory: directory))
        navigation.show(.home)
        try await settle(400)
        host.rootView = rootPage(app, reduced: false)
        try await settle(300)
        navigation.show(.knowledge)
        try await settle(100)
        captures.append(try await capture(host, name: "26-knowledge-opening", directory: directory))
        try await settle(1600)
        captures.append(try await capture(host, name: "27-knowledge-open", directory: directory))
        checks["ui_knowledge_keeps_home_inert"] = !conversation.isVisible && !presentation.composerFocused
        checks["ui_knowledge_preserves_draft"] = conversation.draft == draft && navigation.hasOpenedKnowledge
        navigation.show(.home)
        try await settle(100)
        captures.append(try await capture(host, name: "28-knowledge-closing", directory: directory))
        try await settle(650)
        captures.append(try await capture(host, name: "29-home-after-knowledge", directory: directory))
        let knowledgeMotion = try await SidekickUIRecording.record(window: window,
            url: directory.appendingPathComponent("knowledge-motion.mp4"), duration: 4.4) { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
                navigation.show(.knowledge)
                try await Task.sleep(for: .milliseconds(1600))
                navigation.show(.home)
                try await Task.sleep(for: .milliseconds(750))
                navigation.show(.knowledge)
                try await Task.sleep(for: .milliseconds(100))
                navigation.show(.home)
            } catch { return }
        }
        try saveMotion(knowledgeMotion, name: "knowledge", root: root)
        checks["ui_knowledge_motion_recorded"] = knowledgeMotion["writer_completed"] as? Bool == true
        checks["ui_knowledge_reversal_keeps_current_route"] = navigation.page == .home && conversation.draft == draft
        host.rootView = rootPage(app, reduced: true)
        navigation.show(.knowledge)
        try await settle(400)
        captures.append(try await capture(host, name: "30-knowledge-reduced-motion", directory: directory))
        navigation.show(.home)
        try await settle(400)
        host.rootView = rootPage(app, reduced: false)

        // Retained Knowledge must recover when its directory disappears while away.
        // Move only this fixture's synthetic vault, then restore it before manual inspection.
        let fixtureVault = root.appendingPathComponent("vault", isDirectory: true)
        let parkedVault = root.appendingPathComponent("vault-parked", isDirectory: true)
        try FileManager.default.moveItem(at: fixtureVault, to: parkedVault)
        defer {
            if FileManager.default.fileExists(atPath: parkedVault.path), !FileManager.default.fileExists(atPath: fixtureVault.path) {
                try? FileManager.default.moveItem(at: parkedVault, to: fixtureVault)
            }
        }
        navigation.show(.knowledge)
        try await settle(1300)
        checks["ui_knowledge_missing_vault_is_authoritative"] = KnowledgeVault.load() == nil && navigation.page == .knowledge
        captures.append(try await capture(host, name: "31-knowledge-vault-missing", directory: directory))
        navigation.show(.home)
        try await settle(650)
        try FileManager.default.moveItem(at: parkedVault, to: fixtureVault)
        navigation.show(.knowledge)
        try await settle(1500)
        captures.append(try await capture(host, name: "32-knowledge-vault-restored", directory: directory))
        checks["ui_knowledge_restored_vault_available"] = KnowledgeVault.load()?.readme != nil
        navigation.show(.home)
        try await settle(650)

        let fixtureManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as? [String: Any]
        let hold: Int
        if let requested = ProcessInfo.processInfo.environment["LAB_SIDEKICK_UI_HOLD"] {
            guard let seconds = Int(requested) else { throw Failure.invalidFixture }
            hold = seconds
        } else { hold = fixtureManifest?["ui_hold_seconds"] as? Int ?? 0 }
        guard (0...600).contains(hold) else { throw Failure.invalidFixture }
        if hold > 0 {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let ready: [String: Any] = ["process_id": getpid(), "window_id": window.windowNumber,
                "seconds": hold, "provider_submission_disabled": true, "root_navigation_available": true]
            try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("ui-hold-ready.json"), options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(hold))
            let finish = root.appendingPathComponent("ui-hold-complete")
            while ContinuousClock.now < deadline && !FileManager.default.fileExists(atPath: finish.path) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        // Exercise only a guaranteed rejection. No accepted submit, cards, provider, permission
        // setup, native helper, or session-start API is invoked by this fixture.
        conversation.beginMaintenance()
        let sequenceBeforeRejection = try store.latestSequence
        let accepted = SidekickComposer.sendDraft(coordinator: coordinator, presentation: presentation)
        checks["ui_rejected_submission_preserves_draft"] = !accepted && conversation.draft == draft
        checks["ui_rejected_submission_creates_no_task"] = try store.latestSequence == sequenceBeforeRejection
            && !coordinator.run.isRunning && coordinator.run.interaction == nil
        checks["ui_no_background_model_work"] = !conversation.hasPendingCompactionWorkForTesting
        checks["ui_memory_unchanged"] = try SidekickInstructionStore.read().text == baselineMemory
        checks["ui_every_snapshot_nonempty"] = captures.allSatisfy {
            ($0["bytes"] as? Int ?? 0) > 10_000 && ($0["nonblack_fraction"] as? Double ?? 0) > 0.035
                && ($0["sampled_colors"] as? Int ?? 0) > 32

        }
        let manifest: [String: Any] = ["schema": 1, "snapshots": captures, "generation": generation.uuidString,
            "baseline_sequence": beforeSequence, "fixture_tasks": fixtureIDs.map(\.uuidString),
            "calendar_message_id": calendarID, "markdown_message_id": markdownID,
            "retained_draft": conversation.draft, "provider_calls": 0, "checks": checks]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("ui-manifest.json"), options: .atomic)
        return checks
    }

    /// Separate destructive acceptance profile. Uses the real native confirmation buttons
    /// and coordinator; its provider gate is independent from history maintenance.
    static func runClearChat(app: AppState, root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-clear",
              let store = app.commandCoordinator.run.conversation.store else { throw Failure.invalidFixture }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            throw Failure.screenLocked
        }
        let coordinator = app.commandCoordinator, conversation = coordinator.run.conversation
        let presentation = app.sidekickPresentation
        coordinator.run.preventsTaskExecutionForUIFixture = true
        let memoryBefore = try SidekickInstructionStore.read().text
        let vaultFile = root.appendingPathComponent("vault/README.md")
        let vaultBefore = try Data(contentsOf: vaultFile)
        let generation = try store.generation, sequence = try store.latestSequence
        guard sequence > 0 else { throw Failure.invalidFixture }
        let first = try store.transcriptPage().records.first!
        conversation.draft = draft
        conversation.replyReference = .init(messageID: first.event.id)
        conversation.requestNavigation()
        let originalDeck = UserDefaults.standard.object(forKey: BriefingDeck.key)
        UserDefaults.standard.set(BriefingDeck.jesai.rawValue, forKey: BriefingDeck.key)
        let navigation = MainNavigation.shared
        navigation.reset()
        let host = NSHostingView(rootView: rootPage(app, reduced: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Clear chat fixture · synthetic content"
        window.identifier = NSUserInterfaceItemIdentifier(SentientOSApp.homeWindowID)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer {
            window.close(); navigation.reset()
            if let originalDeck { UserDefaults.standard.set(originalDeck, forKey: BriefingDeck.key) }
            else { UserDefaults.standard.removeObject(forKey: BriefingDeck.key) }
        }
        let directory = root.appendingPathComponent("ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var captures: [[String: Any]] = [], checks: [String: Bool] = [:]
        try await settle(900)
        captures.append(try await capture(host, name: "01-chat-before-clear", directory: directory))
        presentation.clearChatConfirmationShown = true
        let cancel = try await confirmationButton("Cancel", window: window)
        try await settle(300)
        guard let sheetView = window.attachedSheet?.contentView else { throw Failure.invalidFixture }
        captures.append(try await capture(sheetView, name: "02-clear-confirmation", directory: directory))
        cancel()
        try await settle(350)
        checks["cancel_preserves_history"] = try store.generation == generation && store.latestSequence == sequence
        checks["cancel_preserves_draft_and_reply"] = conversation.draft == draft && conversation.replyReference != nil
        checks["cancel_dismisses_confirmation"] = !presentation.clearChatConfirmationShown && window.attachedSheet == nil
        presentation.search = "ORBIT-CEDAR"
        await presentation.find(conversation: conversation)
        presentation.clearChatConfirmationShown = true
        let clear = try await confirmationButton("Clear chat", window: window)
        clear()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (try store.generation == generation || coordinator.run.isClearingChat), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle(650)
        captures.append(try await capture(host, name: "03-overview-after-clear", directory: directory))
        checks["history_generation_rotated"] = try store.generation != generation
        checks["history_and_summaries_empty"] = try store.latestSequence == 0 && store.records().isEmpty && store.summaries().isEmpty
        checks["projection_and_reply_empty"] = conversation.messages.isEmpty && conversation.draft.isEmpty && conversation.replyReference == nil
        checks["search_and_reading_state_empty"] = presentation.rows.isEmpty && presentation.searchResults.isEmpty && presentation.search.isEmpty && !presentation.searchShown
        checks["proactive_surface_restored"] = presentation.surface == .suggestions && !presentation.cards.entries.isEmpty
        checks["cleared_projection_idle"] = !presentation.loading && presentation.error == nil && conversation.storageError == nil
        conversation.requestNavigation()
        try await settle(800)
        captures.append(try await capture(host, name: "04-empty-conversation", directory: directory))
        checks["empty_chat_remains_idle"] = !presentation.loading && presentation.error == nil && conversation.storageError == nil
        presentation.surface = .suggestions
        try await settle(400)
        checks["notch_and_retry_empty"] = coordinator.phase == .hidden && coordinator.run.interaction == nil && !coordinator.run.recovery.isPending
        checks["knowledge_unchanged"] = try Data(contentsOf: vaultFile) == vaultBefore
        checks["instructions_unchanged"] = try SidekickInstructionStore.read().text == memoryBefore
        checks["legacy_defaults_removed"] = UserDefaults.standard.data(forKey: SidekickHistory.key) == nil
        let reopened = try SidekickConversationStore(url: store.url)
        checks["reopen_remains_empty"] = try reopened.records().isEmpty && reopened.summaries().isEmpty && !reopened.needsLegacyImport
        // A UI fixture can test reset while still making any accidental submit inert.
        conversation.draft = "This fixture must never launch a provider."
        let rejected = !SidekickComposer.sendDraft(coordinator: coordinator, presentation: presentation)
        checks["provider_submission_blocked"] = try rejected && !coordinator.run.isRunning && store.latestSequence == 0
        conversation.draft = ""
        let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as? [String: Any]
        let hold = configuration?["ui_hold_seconds"] as? Int ?? 0
        guard (0...600).contains(hold) else { throw Failure.invalidFixture }
        if hold > 0 {
            try JSONSerialization.data(withJSONObject: ["process_id": getpid(), "window_id": window.windowNumber])
                .write(to: root.appendingPathComponent("ui-hold-ready.json"), options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(hold))
            while ContinuousClock.now < deadline && !FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-hold-complete").path) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let result: [String: Any] = ["checks": checks, "snapshots": captures, "provider_calls": 0,
                                   "old_generation": generation.uuidString, "new_generation": try store.generation.uuidString]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("clear-ui-manifest.json"), options: .atomic)
        return checks
    }

    private static func confirmationButton(_ title: String, window: NSWindow) async throws -> () -> Void {
        func action(_ element: Any) -> (() -> Void)? {
            if let button = element as? NSButton, button.title == title, button.isEnabled {
                return { button.performClick(nil) }
            }
            if let accessible = element as? NSAccessibilityProtocol {
                if accessible.accessibilityRole() == .button,
                   accessible.accessibilityLabel() == title || accessible.accessibilityTitle() == title {
                    return { _ = accessible.accessibilityPerformPress() }
                }
                for child in accessible.accessibilityChildren() ?? [] {
                    if let press = action(child) { return press }
                }
            }
            return nil
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let sheet = window.attachedSheet, let press = action(sheet) { return press }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.invalidFixture
    }

    private static func home(_ app: AppState, reduced: Bool, opaque: Bool, hoveredMessage: String? = nil,
                             hoveredCard: String? = nil) -> AnyView {
        AnyView(HomeView(deck: .jesai).environment(app)
            .environment(\.sidekickReduceMotionOverride, reduced)
            .environment(\.sidekickHoveredMessageID, hoveredMessage)
            .environment(\.sidekickHoveredCardID, hoveredCard)
            .environment(\.sidekickReduceTransparencyOverride, opaque))
    }
    private static func rootPage(_ app: AppState, reduced: Bool) -> AnyView {
        AnyView(RootView().environment(app)
            .environment(\.sidekickReduceMotionOverride, reduced)
            .environment(\.sidekickReduceTransparencyOverride, false)
            .preferredColorScheme(.dark))
    }
    private static func notch(phase: NotchPhase, metrics: NotchMetrics, recovery: SidekickRecovery?,
                              message: SidekickConversationStore.Record?) -> AnyView {
        AnyView(ZStack(alignment: .top) {
            Color(white: 0.055)
            NotchContent(phase: phase, readBack: nil, statusLine: "", metrics: metrics, recovery: recovery, message: message)
        }.environment(\.colorScheme, .dark))
    }
    private static func settle(_ milliseconds: Int) async throws {
        await Task.yield()
        if milliseconds > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
    }
    private static func overviewProbes(_ view: NSView) -> [SidekickOverviewScroll.Probe] {
        (view as? SidekickOverviewScroll.Probe).map { [$0] } ?? view.subviews.flatMap { overviewProbes($0) }
    }
    @discardableResult private static func scroll(_ probe: SidekickOverviewScroll.Probe, by amount: Double,
                                                  phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []) -> Bool {
        probe.consume(.init(timestamp: ProcessInfo.processInfo.systemUptime, deltaX: 0, deltaY: amount,
            inverted: false, precise: true, phase: phase, momentumPhase: momentum,
            enabled: probe.enabled, ownWindow: true, insideView: true, insideActiveRect: true))
    }
    private static func saveMotion(_ result: [String: Any], name: String, root: URL) throws {
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("ui-\(name)-motion.json"), options: .atomic)
    }

    private static func markdownViews(_ view: NSView) -> [SidekickMarkdownTextView] {
        if let text = view as? SidekickMarkdownTextView { return [text] }
        return view.subviews.flatMap(markdownViews)
    }
    private static func nativeTexts(_ view: NSView) -> [String] {
        (view as? NSTextView).map { [$0.string] } ?? view.subviews.flatMap(nativeTexts)
    }
    private static func capture(_ view: NSView, name: String, directory: URL, expectedChild: NSWindow? = nil) async throws -> [String: Any] {
        guard let window = view.window, window.isVisible, window.windowNumber > 0 else { throw Failure.snapshot }
        // currentProcess is the macOS 14.4+ own-content API: it does not require a
        // blanket screen-recording grant. Never enumerate/capture another process.
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        // currentProcess supplies only this process's shareable windows. No display filter,
        // rectangle capture, other application's window, or screenshot fallback is permitted.
        let available = try await SCShareableContent.currentProcess
        guard let owned = available.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
        }) else { throw Failure.snapshot }
        if let child = expectedChild {
            guard child.parent === window, child.isVisible,
                  (window.childWindows ?? []).filter(\.isVisible).allSatisfy({ $0 === child }),
                  available.windows.contains(where: { $0.windowID == CGWindowID(child.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw Failure.snapshot }
        }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let scale = CGFloat(filter.pointPixelScale)
        guard owned.frame.width > 0, owned.frame.height > 0, scale.isFinite, scale > 0 else { throw Failure.snapshot }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(owned.frame.width * scale))
        configuration.height = Int(ceil(owned.frame.height * scale))
        configuration.showsCursor = false
        configuration.includeChildWindows = expectedChild != nil
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.snapshot }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        var sampled = 0, nonblack = 0
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 120)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 160)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = max(0, min(1, color.redComponent)), green = max(0, min(1, color.greenComponent)), blue = max(0, min(1, color.blueComponent))
                sampled += 1
                if max(red, green, blue) > 0.035 { nonblack += 1 }
                colors.insert((Int(red * 31) << 10) | (Int(green * 31) << 5) | Int(blue * 31))
            }
        }
        return ["name": name, "file": "ui-snapshots/" + name + ".png", "bytes": png.count,
            "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
            "logical_width": owned.frame.width, "logical_height": owned.frame.height,
            "logical_content_width": view.bounds.width, "logical_content_height": view.bounds.height,
            "capture_method": "desktop_independent_own_window", "window_id": owned.windowID,
            "included_child_window_id": expectedChild?.windowNumber ?? 0,
            "owning_process_id": getpid(), "pixel_scale": scale,
            "sampled_colors": colors.count, "nonblack_fraction": Double(nonblack) / Double(max(1, sampled)),
            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "native_text_fragments": nativeTexts(view).count]
    }
}
#endif
