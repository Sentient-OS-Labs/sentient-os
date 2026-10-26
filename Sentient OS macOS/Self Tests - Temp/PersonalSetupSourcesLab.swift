#if DEBUG
// Actual optional source/timing UI, with only owned empty folders and a captured callback.
// SidekickAppLab installs the isolated defaults/support root before constructing this view.
import AppKit
import SwiftUI

@MainActor enum PersonalSetupSourcesLab {
    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        typealias Failure = SidekickPolishLab.Failure
        let environment = ProcessInfo.processInfo.environment
        guard environment["SENTIENT_SELFTEST"] == "sidekickapp",
              environment["LAB_SIDEKICK_STAGE"] == "ui-personal-sources",
              let configured = environment["LAB_SIDEKICK_ROOT"],
              root.standardizedFileURL == URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath(),
              UserDefaults.standard.string(forKey: "lab.fixture.nonce") != nil else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        guard !app.processing.isBusy, app.processing.record.status == .idle,
              let store = app.commandCoordinator.run.conversation.store else { throw Failure.unavailable }

        guard OvernightWakeSetup.enableSourceFixture(root: root) else { throw Failure.isolation }
        let defaults = UserDefaults.standard
        for key in SourceSelection.folderKeys + ["dbg.run.whatsapp", "dbg.run.imessage", "dbg.run.notes", "dbg.run.gmail", "dbg.run.calendar"] {
            defaults.set(false, forKey: key)
        }
        for key in [CustomRoots.key, "dbg.whatsapp.chats", "dbg.imessage.chats", AppleMailSelection.key, SourceSelection.pendingProtectedSourceKey] {
            defaults.set("", forKey: key)
        }
        defaults.removeObject(forKey: AppleCalendarSource.selectionKey)
        defaults.set(PersonalSetupProgress.Stage.sources.rawValue, forKey: PersonalSetupProgress.stageKey)
        app.hasCompletedOnboarding = true; app.hasCompletedPersonalSetup = false
        app.commandCoordinator.run.preventsTaskExecutionForUIFixture = true
        let conversation = app.commandCoordinator.run.conversation
        let draft = "Keep this draft while I choose my sources."
        conversation.draft = draft
        let baseline = try store.latestSequence
        let selectionRoot = root.appendingPathComponent("source-fixtures", isDirectory: true)
        let folders = ["Project Notes", "Reference Files", "Meeting Notes"].map {
            selectionRoot.appendingPathComponent($0, isDirectory: true)
        }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        var lastElements: [[String: Any]] = []
        var accessibilityActivation: [Int] = []
        var callbacks: [ProcessingCoordinator.Timing] = []
        var callbacksAfterDismissal: [Bool] = []
        var phase = "initializing"
        var completed = false
        weak var observedWindow: NSWindow?
        defer {
            let manifest: [String: Any] = ["schema": 1, "checks": checks, "captures": captures,
                "completed": completed, "phase": phase, "last_accessibility_elements": lastElements,
                "callbacks": callbacks.map(\.rawValue), "callbacks_after_sheet_dismissal": callbacksAfterDismissal,
                "provider_calls": 0, "protected_source_reads": 0,
                "wake_setup_requests": OvernightWakeSetup.sourceFixtureSetups,
                "wake_refresh_requests": OvernightWakeSetup.sourceFixtureRefreshes,
                "wake_refresh_uses_fixture": true,
                "accessibility_activation_results": accessibilityActivation,
                "capture_scope": "current_process_windows_only", "selected_roots": CustomRoots.urls.map(\.path)]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("personal-sources-manifest.json"), options: .atomic)
            }
        }
        func readyView() -> AnyView {
            AnyView(OnboardingReadyView(onStart: { timing in
                callbacksAfterDismissal.append(observedWindow?.attachedSheet == nil)
                callbacks.append(timing)
            })
            .environment(app).environment(\.accessibilityEnabled, true)
            .background(Theme.bg)
            .preferredColorScheme(.dark))
        }
        func makeWindow(_ host: NSView, size: CGSize) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Personal sources · isolated fixture"
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false; window.contentView = host
            observedWindow = window
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return window
        }
        var host = NSHostingView(rootView: readyView())
        var window = makeWindow(host, size: CGSize(width: 840, height: 760))
        defer { window.close() }
        func settle(_ milliseconds: Int = 350) async throws { try await SidekickPolishLab.settle(milliseconds) }
        func nodes(_ view: NSView) -> [SidekickPolishLab.Element] {
            let result = SidekickPolishLab.elements(view, maximumDepth: 80)
            lastElements = result.map { ["id": $0.identifier, "role": $0.role, "label": $0.label,
                "enabled": $0.enabled as Any? ?? NSNull(),
                "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }
            return result
        }
        func find(_ identifier: String, in view: NSView) -> SidekickPolishLab.Element? {
            let candidates = nodes(view).filter { $0.identifier == identifier && $0.frame.width > 0 && $0.frame.height > 0 }
            return candidates.first { $0.role == NSAccessibility.Role.button.rawValue } ?? candidates.first
        }
        func click(_ identifier: String, in view: NSView) async throws {
            phase = "click:" + identifier
            guard let target = find(identifier, in: view), target.role == NSAccessibility.Role.button.rawValue,
                  let owner = view.window else { throw Failure.accessibility }
            try SidekickPolishLab.postClick(window: owner, screenPoint: CGPoint(x: target.frame.midX, y: target.frame.midY))
            try await settle()
        }
        func capture(_ name: String, view: NSView) async throws {
            var capture = try await SidekickPolishLab.capture(view, name: name, directory: directory)
            capture["parent_content_width"] = host.bounds.width
            capture["parent_content_height"] = host.bounds.height
            captures.append(capture)
        }
        func buttonFits(_ identifier: String, view: NSView) -> Bool {
            guard let button = find(identifier, in: view), let owner = view.window else { return false }
            return owner.convertToScreen(view.convert(view.bounds, to: nil)).insetBy(dx: -1, dy: -1).contains(button.frame)
        }
        func checkParentSize(_ name: String, expected: CGSize) {
            checks[name + "_requested_parent_bounds"] = abs(host.bounds.width - expected.width) < 1
                && abs(host.bounds.height - expected.height) < 1
            checks[name + "_native_window_on_screen"] = window.screen?.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame) == true
        }
        func waitForCount(_ count: Int) async throws {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            for _ in 0..<20 {
                try await settle(100)
                if SourceSelection.selectionCount == count,
                   find("personalSetup.startAnalysis", in: host)?.enabled == (count >= SourceSelection.minimumSelections) {
                    // AX enabled state changes before the 0.4 s capsule / 0.6 s halo animations
                    // finish. Capture the settled production appearance, not an intermediate gray.
                    try await settle(700)
                    if SourceSelection.selectionCount == count,
                       find("personalSetup.startAnalysis", in: host)?.enabled == (count >= SourceSelection.minimumSelections) { return }
                }
            }
            throw Failure.accessibility
        }
        func timingView() async throws -> NSView {
            phase = "waiting:analysis.timing.controls"
            var warmedSheet: ObjectIdentifier?
            for attempt in 0..<35 {
                if let sheet = window.attachedSheet, let view = sheet.contentView {
                    if warmedSheet != ObjectIdentifier(sheet) || attempt == 12 || attempt == 24 {
                        accessibilityActivation.append(await SidekickPolishLab.activateOwnAccessibility())
                        warmedSheet = ObjectIdentifier(sheet)
                        try await settle(200)
                    }
                    let identifiers = ["analysis.timing.now", "analysis.timing.overnight", "analysis.timing.continue"]
                    if identifiers.allSatisfy({ identifier in
                        guard let element = find(identifier, in: view) else { return false }
                        return element.role == NSAccessibility.Role.button.rawValue && element.enabled == true
                    }) { return view }
                }
                try await settle(100)
            }
            throw Failure.accessibility
        }
        func waitForTimingContinue(_ enabled: Bool, in view: NSView) async throws {
            phase = "waiting:analysis.timing.continue:" + String(enabled)
            for _ in 0..<35 {
                if let button = find("analysis.timing.continue", in: view),
                   button.role == NSAccessibility.Role.button.rawValue, button.enabled == enabled {
                    try await settle(450)
                    if find("analysis.timing.continue", in: view)?.enabled == enabled { return }
                }
                try await settle(100)
            }
            throw Failure.accessibility
        }
        func chooseNow(expectedCallbacks: Int, captureName: String, parentSize: CGSize) async throws {
            try await click("personalSetup.startAnalysis", in: host)
            let timing = try await timingView()
            checkParentSize(captureName, expected: parentSize)
            checks[captureName + "_does_not_start_on_open"] = callbacks.count == expectedCallbacks - 1 && !app.processing.isBusy
            checks[captureName + "_now_and_continue_fit"] = buttonFits("analysis.timing.now", view: timing)
                && buttonFits("analysis.timing.continue", view: timing)
            checks[captureName + "_sheet_stays_bounded"] = timing.window.map {
                $0.frame.height <= window.frame.height + 1
                    && $0.screen?.visibleFrame.insetBy(dx: -1, dy: -1).contains($0.frame) == true
            } ?? false
            let refreshesBefore = OvernightWakeSetup.sourceFixtureRefreshes
            try await click("analysis.timing.overnight", in: timing)
            try await waitForTimingContinue(false, in: timing)
            checks[captureName + "_overnight_footer_stays_bounded"] = buttonFits("analysis.timing.continue", view: timing)
                && (timing.window.map { $0.frame.height <= window.frame.height + 1 } ?? false)
            checks[captureName + "_overnight_only_refreshes_fixture"] = OvernightWakeSetup.sourceFixtureRefreshes > refreshesBefore
                && OvernightWakeSetup.sourceFixtureSetups == 0 && callbacks.count == expectedCallbacks - 1
                && !app.processing.isBusy && app.processing.record.status == .idle
            try await capture(captureName + "-overnight", view: timing)

            try await click("analysis.timing.now", in: timing)
            try await waitForTimingContinue(true, in: timing)
            checks[captureName + "_choosing_now_waits_for_continue"] = callbacks.count == expectedCallbacks - 1
            CustomRoots.remove(folders[2])
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try await waitForTimingContinue(false, in: timing)
            try await click("analysis.timing.continue", in: timing)
            checks[captureName + "_source_loss_prevents_continue"] = SourceSelection.selectionCount == 2
                && find("analysis.timing.continue", in: timing)?.enabled == false
                && callbacks.count == expectedCallbacks - 1 && window.attachedSheet != nil
            CustomRoots.add(folders[2])
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try await waitForTimingContinue(true, in: timing)
            checks[captureName + "_restored_source_reenables_continue"] = SourceSelection.selectionCount == 3
                && find("analysis.timing.continue", in: timing)?.enabled == true
            try await capture(captureName, view: timing)
            try await click("analysis.timing.continue", in: timing)
            for _ in 0..<25 {
                try await settle(100)
                if callbacks.count == expectedCallbacks && window.attachedSheet == nil { break }
            }
            checks[captureName + "_callback_after_dismissal"] = callbacks.count == expectedCallbacks
                && callbacks.last == .now && callbacksAfterDismissal.last == true && window.attachedSheet == nil
            checks[captureName + "_callback_does_not_run_analysis"] = !app.processing.isBusy && app.processing.record.status == .idle
        }

        try await settle(700)
        accessibilityActivation.append(await SidekickPolishLab.activateOwnAccessibility())
        try await settle(300)
        try await waitForCount(0)
        checkParentSize("standard", expected: CGSize(width: 840, height: 760))
        checks["zero_sources_disables_start"] = find("personalSetup.startAnalysis", in: host)?.enabled == false
        checks["zero_source_start_fits_standard"] = buttonFits("personalSetup.startAnalysis", view: host)
        try await click("personalSetup.startAnalysis", in: host)
        checks["disabled_start_opens_no_timing"] = window.attachedSheet == nil && callbacks.isEmpty
        try await capture("personal-sources-01-zero-standard", view: host)

        folders.prefix(2).forEach(CustomRoots.add)
        try await waitForCount(2)
        window.setContentSize(CGSize(width: 700, height: 560)); try await settle()
        checkParentSize("minimum", expected: CGSize(width: 700, height: 560))
        checks["two_sources_disables_start"] = find("personalSetup.startAnalysis", in: host)?.enabled == false
        checks["start_fits_minimum"] = buttonFits("personalSetup.startAnalysis", view: host)
        try await capture("personal-sources-02-two-minimum", view: host)
        CustomRoots.add(folders[2]); try await waitForCount(3)
        checks["three_sources_enables_start"] = find("personalSetup.startAnalysis", in: host)?.enabled == true
        checks["only_owned_folders_are_selected"] = SourceSelection.current().count == 3
            && Set(CustomRoots.urls) == Set(folders) && SourceSelection.selectedProtectedSources.isEmpty
        try await capture("personal-sources-03-three-minimum", view: host)
        try await chooseNow(expectedCallbacks: 1, captureName: "personal-sources-04-timing-minimum", parentSize: CGSize(width: 700, height: 560))

        phase = "close_and_reopen"
        window.close()
        host.rootView = AnyView(Color.black)
        try await settle(150)
        host = NSHostingView(rootView: readyView())
        window = makeWindow(host, size: CGSize(width: 840, height: 760))
        try await settle(500)
        accessibilityActivation.append(await SidekickPolishLab.activateOwnAccessibility())
        try await settle(250); try await waitForCount(3)
        checkParentSize("reopened_standard", expected: CGSize(width: 840, height: 760))
        checks["sources_survive_close_reopen"] = Set(CustomRoots.urls) == Set(folders)
            && find("personalSetup.startAnalysis", in: host)?.enabled == true && window.attachedSheet == nil
        checks["sidekick_draft_survives_close_reopen"] = conversation.draft == draft
        checks["reopen_does_not_repeat_callback"] = callbacks.count == 1
        try await capture("personal-sources-05-reopened-standard", view: host)
        try await chooseNow(expectedCallbacks: 2, captureName: "personal-sources-06-timing-standard", parentSize: CGSize(width: 840, height: 760))
        checks["selection_and_sidekick_history_preserved"] = try store.latestSequence == baseline && conversation.draft == draft
        checks["no_automatic_processing_or_schedule"] = !app.processing.isBusy && app.processing.record.status == .idle
            && !defaults.bool(forKey: OvernightScheduler.prodEnabledKey) && !defaults.bool(forKey: OvernightScheduler.enabledKey)
        checks["wake_install_never_requested"] = OvernightWakeSetup.sourceFixtureSetups == 0
        checks["eight_owned_captures"] = captures.count == 8
        // Exercise the same production handoff against this real native owner. Closing the
        // owner must cancel a chosen result even if SwiftUI reports dismissal afterward.
        phase = "native_owner_close_cancellation"
        let closingHandoff = AnalysisTimingHandoff()
        var lateCallbacks = 0
        closingHandoff.attach(to: window)
        let queued = closingHandoff.choose(.now) { _ in lateCallbacks += 1 }
        window.close()
        closingHandoff.sheetDidDismiss()
        try await settle(250)
        checks["native_owner_close_cancels_queued_handoff"] = queued && lateCallbacks == 0 && !closingHandoff.isPending
        closingHandoff.attach(to: nil)
        completed = true; phase = "complete"
        return checks
    }
}
#endif
