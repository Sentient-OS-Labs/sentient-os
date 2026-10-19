// Coordinates configured native helper startup, shared readiness checks, and explicit recovery.
// A task lease prevents Sentient's recovery UI from restarting computer use during its own work.
// Doc: Driver/Documentation - Native Computer Use.md

import AppKit
import Foundation

@MainActor
@Observable
final class OpenAIComputerUseRuntime {
    static let shared = OpenAIComputerUseRuntime()
    private init() {}

    private var activeTasks: Set<UUID> = []
    private var taskHelpers: [UUID: NSRunningApplication] = [:]
    private var activeConfiguration: OpenAIComputerUse.Configuration?
    private var launched: (app: NSRunningApplication, configuration: OpenAIComputerUse.Configuration)?
    private var checked: (app: NSRunningApplication, configuration: OpenAIComputerUse.Configuration, at: Date)?
    @ObservationIgnored private var starting: Task<NSRunningApplication, Error>?
    private var startingConfiguration: OpenAIComputerUse.Configuration?
    private var startingID: UUID?
    @ObservationIgnored private var checking: Task<Void, Error>?
    private var checkingID: UUID?
    private var checkingConfiguration: OpenAIComputerUse.Configuration?
    private var checkingFresh = false
    private var restarting = false
    private var diagnosticLease: UUID?

    /// A user-requested repair owns the idle runtime. Ordinary tasks wait cancellably;
    /// repairs never tear down a helper underneath an existing agent.
    func reserveDiagnostic() -> UUID? {
        guard activeTasks.isEmpty, diagnosticLease == nil, !restarting else { return nil }
        let id = UUID(); diagnosticLease = id; return id
    }
    func endDiagnostic(_ id: UUID) { if diagnosticLease == id { diagnosticLease = nil } }

    @discardableResult
    func start(configuration selected: OpenAIComputerUse.Configuration,
               stoppingConflictingHelpers: Bool = false) async throws -> NSRunningApplication {
        let lease = try await CodexRuntime.sharedRuntimeLease()
        defer { lease.unlock() }
        let configuration = try selected.afterRuntimeLease()
        if let activeConfiguration, !activeTasks.isEmpty, activeConfiguration != configuration {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        while let starting {
            let sameConfiguration = startingConfiguration == configuration
            do {
                let app = try await awaitStartup(starting, id: startingID)
                if sameConfiguration, !app.isTerminated {
                    // A foreground waiter may have joined a passive startup just before a
                    // different client relaunched its helper. Recheck before taking ownership.
                    if stoppingConflictingHelpers {
                        try await OpenAIComputerUse.stopConflictingHelpers(configuration: configuration)
                    }
                    if !app.isTerminated { return app }
                }
            } catch OpenAIComputerUse.RuntimeError.conflictingHelper where stoppingConflictingHelpers {
                // A task can arrive while a passive health check is refusing a foreign helper.
                // Retry with takeover after that shared startup has settled.
                try Task.checkCancellation()
            }
        }
        guard !restarting else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        let id = UUID()
        let task = Task { @MainActor in
            defer {
                if self.startingID == id {
                    self.starting = nil; self.startingID = nil; self.startingConfiguration = nil
                }
            }
            // Startup owns its lease independently of its waiters. STOP may release a caller
            // while Settings or another request still needs this shared preparation.
            let startupLease = try await CodexRuntime.sharedRuntimeLease()
            defer { startupLease.unlock() }
            let configuration = try configuration.afterRuntimeLease()
            _ = try await OpenAIComputerUse.validate(at: configuration.appURL)
            try Task.checkCancellation()
            for attempt in 0..<3 {
                do {
                    if stoppingConflictingHelpers {
                        try await OpenAIComputerUse.stopConflictingHelpers(configuration: configuration)
                    }
                    let running = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
                        .filter { !$0.isTerminated }
                    if let app = running.first {
                        guard running.count == 1, let url = app.bundleURL,
                              await OpenAIComputerUse.acceptsRunningHelper(at: url, configuration: configuration) else {
                            throw OpenAIComputerUse.RuntimeError.conflictingHelper
                        }
                        // The last native client can close while compatibility is checked.
                        // A dead cached helper is a fresh startup, not a permission failure.
                        if app.isTerminated { continue }
                        if let launched, !launched.app.isTerminated,
                           launched.app.processIdentifier == app.processIdentifier,
                           launched.configuration != configuration,
                           url.standardizedFileURL == configuration.appURL.standardizedFileURL {
                            self.checked = nil
                            throw OpenAIComputerUse.RuntimeError.restartRequired
                        }
                        return app
                    }
                    self.checked = nil
                    let options = NSWorkspace.OpenConfiguration()
                    options.activates = false
                    options.allowsRunningApplicationSubstitution = false
                    options.environment = configuration.environment
                    let app: NSRunningApplication
                    do { app = try await NSWorkspace.shared.openApplication(at: configuration.appURL, configuration: options) }
                    catch { throw OpenAIComputerUse.RuntimeError.launchFailed }
                    guard app.bundleURL?.standardizedFileURL == configuration.appURL.standardizedFileURL else {
                        throw OpenAIComputerUse.RuntimeError.conflictingHelper
                    }
                    // openApplication can succeed before a service that lost its registration exits.
                    // Detect that startup failure before any model or user action is sent.
                    try await Task.sleep(for: .milliseconds(100))
                    guard !app.isTerminated else { throw OpenAIComputerUse.RuntimeError.launchFailed }
                    self.launched = (app, configuration)
                    Log("Native computer use: helper started with the selected CLI")
                    try Task.checkCancellation()
                    return app
                } catch let error as OpenAIComputerUse.RuntimeError where stoppingConflictingHelpers
                    && attempt < 2 && [.conflictingHelper, .launchFailed].contains(error) {
                    // Startup-only retries: never replay a tool, click, keystroke or send.
                    self.checked = nil
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            throw OpenAIComputerUse.RuntimeError.launchFailed
        }
        starting = task
        startingID = id
        startingConfiguration = configuration
        do { return try await awaitStartup(task, id: id) }
        catch {
            if !(error is CancellationError) { invalidate() }
            throw error
        }
    }

    /// Await shared startup without transferring cancellation to it. Poll only the task's
    /// lifetime, not the helper; this also lets STOP release the run promptly.
    private func awaitStartup(_ task: Task<NSRunningApplication, Error>, id: UUID?) async throws -> NSRunningApplication {
        while let id, startingID == id {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return try await task.value
    }

    /// A live service diagnostic for explicit setup and repair, after consent. Ordinary tasks
    /// establish their own required MCP connection instead of starting an extra Codex process.
    func check(configuration selected: OpenAIComputerUse.Configuration, fresh: Bool = false) async throws {
        let lease = try await CodexRuntime.sharedRuntimeLease()
        defer { lease.unlock() }
        let configuration = try selected.afterRuntimeLease()
        if let checking {
            let sameConfiguration = checkingConfiguration == configuration
            let satisfiesFreshness = checkingFresh || !fresh
            try await withTaskCancellationHandler { try await checking.value } onCancel: { checking.cancel() }
            try Task.checkCancellation()
            if sameConfiguration, satisfiesFreshness { return }
        }
        let task = Task { @MainActor in
            do {
                let app = try await self.start(configuration: configuration, stoppingConflictingHelpers: true)
                guard await Permissions.nativeAutomationState() == .granted else {
                    throw OpenAIComputerUse.RuntimeError.permissionRequired
                }
                if !fresh, let checked, !checked.app.isTerminated,
                   checked.app.processIdentifier == app.processIdentifier,
                   checked.configuration == configuration, Date().timeIntervalSince(checked.at) < 30 {
                    return
                }
                try await OpenAIComputerUseProbe.check(configuration)
                try Task.checkCancellation()
                self.checked = (app, configuration, Date())
                Log("Native computer use: service check passed")
            } catch {
                self.checked = nil
                if !Task.isCancelled, !(error is CancellationError) {
                    if !Diagnostics.isExpected(error) { Diagnostics.report(.readinessFailed, phase: .probe, error: error) }
                    let reason = (error as? OpenAIComputerUse.RuntimeError).map { String(describing: $0) } ?? "unexpected"
                    Log("Native computer use: service check failed (\(reason))")
                }
                throw error
            }
        }
        let id = UUID()
        checking = task
        checkingID = id
        checkingConfiguration = configuration
        checkingFresh = fresh
        defer {
            if checkingID == id { checking = nil; checkingID = nil; checkingConfiguration = nil; checkingFresh = false }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func beginTask(configuration: OpenAIComputerUse.Configuration) async throws -> UUID {
        while diagnosticLease != nil { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if let activeConfiguration, !activeTasks.isEmpty, activeConfiguration != configuration {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        let id = UUID()
        activeTasks.insert(id)
        activeConfiguration = configuration
        do {
            let app = try await start(configuration: configuration, stoppingConflictingHelpers: true)
            taskHelpers[id] = app
            AgentRunDiagnostics.current?.recordHelper(running: !app.isTerminated, atStart: true)
            let permission = await Permissions.nativeAutomationState()
            CrashReporting.diagnosticBreadcrumb("computer_use.task_readiness", data: [
                "helper_running": String(!app.isTerminated),
                "automation_granted": String(permission == .granted),
                "expected_helper_version": CodexRuntime.release.helper.version,
                "expected_helper_build": String(CodexRuntime.release.helperBuild)])
            guard permission == .granted else {
                throw OpenAIComputerUse.RuntimeError.permissionRequired
            }
            try Task.checkCancellation()
            return id
        } catch { endTask(id); throw error }
    }

    func endTask(_ id: UUID) {
        if let app = taskHelpers.removeValue(forKey: id) {
            AgentRunDiagnostics.current?.recordHelper(running: !app.isTerminated, atStart: false)
            CrashReporting.diagnosticBreadcrumb("computer_use.task_ended", data: ["helper_running": String(!app.isTerminated)])
        }
        activeTasks.remove(id)
        if activeTasks.isEmpty { activeConfiguration = nil }
    }

    func invalidate() { checked = nil }

    /// An invalid helper cannot pass restart()'s signature check. Before replacing it,
    /// take the same exclusive file lock used by the installer, then stop ONLY our bundle.
    /// Another process's live task makes this fail as busy rather than disrupting its work.
    func prepareForReinstall(configuration: OpenAIComputerUse.Configuration) async throws {
        guard activeTasks.isEmpty, starting == nil, checking == nil, !restarting else {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        try Task.checkCancellation()
        guard let lease = try CodexRuntime.executionLease(for: CodexRuntime.executable.path, exclusive: true) else {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        defer { lease.unlock() }
        _ = try configuration.afterRuntimeLease()
        restarting = true
        defer { restarting = false }
        let own = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
            .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == configuration.appURL.standardizedFileURL }
        for app in own {
            _ = app.terminate()
            for _ in 0..<20 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
            if !app.isTerminated { _ = app.forceTerminate() }
            for _ in 0..<20 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
            guard app.isTerminated else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        }
        launched = nil; checked = nil
    }

    /// Explicit repair respects Sentient's active-task lease and takes over competing helpers
    /// just like task startup, then gracefully restarts only the private helper.
    func restart(configuration selected: OpenAIComputerUse.Configuration) async throws {
        guard activeTasks.isEmpty, starting == nil, checking == nil, !restarting else {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        // Also respect a task in another Sentient process, not only this instance's IDs.
        guard let lease = try CodexRuntime.executionLease(for: CodexRuntime.executable.path, exclusive: true) else {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        defer { lease.unlock() }
        let configuration = try selected.afterRuntimeLease()
        restarting = true
        checked = nil
        defer { restarting = false }
        _ = try await OpenAIComputerUse.validate(at: configuration.appURL)
        try Task.checkCancellation()
        try await OpenAIComputerUse.stopConflictingHelpers(configuration: configuration)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
        guard running.count <= 1, running.allSatisfy({
            $0.bundleURL?.standardizedFileURL == configuration.appURL.standardizedFileURL
        }) else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        if let app = running.first {
            guard app.terminate() else { throw OpenAIComputerUse.RuntimeError.helperRunning }
            let deadline = Date().addingTimeInterval(5)
            while !app.isTerminated, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard app.isTerminated else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        }
        launched = nil
        // The permission flow will start a fresh helper with the chosen configuration.
    }
}
