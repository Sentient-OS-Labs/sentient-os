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

    private(set) var isReady = false
    private var activeTasks: Set<UUID> = []
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

    @discardableResult
    func start(configuration selected: OpenAIComputerUse.Configuration) async throws -> NSRunningApplication {
        let lease = try await CodexRuntime.sharedRuntimeLease()
        defer { lease.unlock() }
        let configuration = try selected.afterRuntimeLease()
        if let activeConfiguration, !activeTasks.isEmpty, activeConfiguration != configuration {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        if let starting {
            let sameConfiguration = startingConfiguration == configuration
            let app = try await withTaskCancellationHandler { try await starting.value } onCancel: { starting.cancel() }
            try Task.checkCancellation()
            if sameConfiguration, !app.isTerminated { return app }
        }
        guard !restarting else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        let task = Task { @MainActor in
            _ = try await OpenAIComputerUse.validate(at: configuration.appURL, configuration: configuration)
            try Task.checkCancellation()
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
            if let app = running.first {
                guard running.count == 1, let url = app.bundleURL,
                      await OpenAIComputerUse.acceptsRunningHelper(at: url, configuration: configuration) else {
                    throw OpenAIComputerUse.RuntimeError.conflictingHelper
                }
                if let launched, !launched.app.isTerminated,
                   launched.app.processIdentifier == app.processIdentifier,
                   launched.configuration != configuration,
                   url.resolvingSymlinksInPath() == configuration.appURL.resolvingSymlinksInPath() {
                    self.isReady = false
                    throw OpenAIComputerUse.RuntimeError.restartRequired
                }
                return app
            }
            self.isReady = false
            self.checked = nil
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            options.allowsRunningApplicationSubstitution = false
            options.environment = configuration.environment
            let app: NSRunningApplication
            do { app = try await NSWorkspace.shared.openApplication(at: configuration.appURL, configuration: options) }
            catch { throw OpenAIComputerUse.RuntimeError.launchFailed }
            guard app.bundleURL?.resolvingSymlinksInPath() == configuration.appURL.resolvingSymlinksInPath() else {
                throw OpenAIComputerUse.RuntimeError.helperRunning
            }
            self.launched = (app, configuration)
            Log("Native computer use: helper started with the selected CLI")
            try Task.checkCancellation()
            return app
        }
        let id = UUID()
        starting = task
        startingID = id
        startingConfiguration = configuration
        defer {
            if startingID == id { starting = nil; startingID = nil; startingConfiguration = nil }
        }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { isReady = false; checked = nil; throw error }
    }

    /// A live service check, after consent. Short caching avoids a background Codex process on
    /// every Settings refresh; task startup requests a fresh check before invoking the model.
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
                let app = try await self.start(configuration: configuration)
                guard await Permissions.nativeAutomationState() == .granted else {
                    throw OpenAIComputerUse.RuntimeError.permissionRequired
                }
                if !fresh, let checked, !checked.app.isTerminated,
                   checked.app.processIdentifier == app.processIdentifier,
                   checked.configuration == configuration, Date().timeIntervalSince(checked.at) < 30 {
                    self.isReady = true
                    return
                }
                try await OpenAIComputerUseProbe.check(configuration)
                try Task.checkCancellation()
                self.checked = (app, configuration, Date())
                self.isReady = true
                Log("Native computer use: service check passed")
            } catch {
                self.checked = nil
                self.isReady = false
                if !Task.isCancelled, !(error is CancellationError) {
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
        if let activeConfiguration, !activeTasks.isEmpty, activeConfiguration != configuration {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        let id = UUID()
        activeTasks.insert(id)
        activeConfiguration = configuration
        do {
            try await check(configuration: configuration, fresh: true)
            try Task.checkCancellation()
            return id
        } catch { endTask(id); throw error }
    }

    func endTask(_ id: UUID) {
        activeTasks.remove(id)
        if activeTasks.isEmpty { activeConfiguration = nil }
    }

    func invalidate() { isReady = false; checked = nil }

    /// Invoked only by the visible Restart button, whose copy asks the user to finish other
    /// apps' computer-use tasks. Never force-kill, never terminate a different installed bundle.
    func restart(configuration selected: OpenAIComputerUse.Configuration) async throws {
        let lease = try await CodexRuntime.sharedRuntimeLease()
        defer { lease.unlock() }
        let configuration = try selected.afterRuntimeLease()
        guard activeTasks.isEmpty, starting == nil, checking == nil, !restarting else {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        restarting = true
        isReady = false
        checked = nil
        defer { restarting = false }
        _ = try await OpenAIComputerUse.validate(at: configuration.appURL, configuration: configuration)
        try Task.checkCancellation()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
        guard running.count <= 1, running.allSatisfy({
            $0.bundleURL?.resolvingSymlinksInPath() == configuration.appURL.resolvingSymlinksInPath()
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
