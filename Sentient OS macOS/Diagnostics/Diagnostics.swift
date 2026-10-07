// Structure-only operational diagnostics, shared failure ownership, and bounded repeat reporting.
// withOperation carries correlation through async work; report accepts only static reasons and numeric fields.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import Synchronization

nonisolated enum Diagnostics {
    enum Event: String, CaseIterable, Sendable {
        case modelOutputInvalid = "model.output_invalid"
        case storeReadFailed = "store.read_failed"
        case sourceReadFailed = "source.read_failed"
        case sourceReadDegraded = "source.read_degraded"
        case sourceSnapshotDegraded = "source.snapshot_degraded"
        case ingestionSkipped = "ingestion.items_skipped"
        case engineReloadFailed = "engine.reload_failed"
        case operationStalled = "operation.stalled"
        case vaultFailed = "vault.operation_failed"
        case vaultOutputInvalid = "vault.output_invalid"
        case doubleTapFailed = "doubletap.failed"
        case wakeFailed = "wake.operation_failed"
        case wakeMissed = "wake.run_missed"
        case cycleIncomplete = "cycle.incomplete"
        case connectorFailed = "connector.operation_failed"
        case inventoryDegraded = "connector.inventory_degraded"
        case childFailed = "process.child_failed"
        case mirrorFailed = "mirror.operation_failed"
        case keychainFailed = "secure_store.operation_failed"
        case knowledgeFailed = "knowledge.operation_failed"
        case cleanupFailed = "cleanup.operation_failed"
        case inputFailed = "input.operation_failed"
        case migrationFailed = "runtime.migration_failed"
        case updateFailed = "app_update.failed"
        case serviceFailed = "service.operation_failed"
        case readinessFailed = "computer_use.readiness_failed"
    }

    enum Phase: String, Sendable {
        case read, write, remove, reset, uninstall, create, update, publish, rotate
        case enumerate, snapshot, extract, generate, parse, validate, commit, reload, load
        case judge, prepare, capture, encode, request, stream, paste, start, finalize, monitor
        case arm, cancel, begin, heartbeat, restore, deadman, ceiling, connect, probe
        case discovery, callback, exchange, refresh, inventory, identity, proof, setup
        case download, verify, unpack, install, migrate, cutover, child, complete, random
    }

    enum Count: String, Sendable {
        case attempted, failed, skipped, deferred, completed, accepted, rejected, bytes, items
        case before, after, filesBefore = "files_before", filesAfter = "files_after"
        case bytesBefore = "bytes_before", bytesAfter = "bytes_after"
        case elapsedMS = "elapsed_ms", deadlineMS = "deadline_ms", ageHours = "age_hours"
        case exitCode = "exit_code", httpStatus = "http_status", osStatus = "os_status"
        case signal, retries, stageCount = "stage_count", failureCount = "failure_count"
    }

    enum Flag: String, Sendable {
        case partial, retriable, checkpointAdvanced = "checkpoint_advanced"
        case permissionGranted = "permission_granted", outputPresent = "output_present"
        case previousStateRetained = "previous_state_retained", expectedShutdown = "expected_shutdown"
        case completeSnapshot = "complete_snapshot", restored, changed, fallbackAvailable = "fallback_available"
    }

    /// No source IDs or user-supplied connector labels may cross this boundary.
    static func source(_ value: String) -> String {
        let known: Set<String> = ["file", "files", "whatsapp", "imessage", "notes", "apple_mail", "appleMail",
            "apple_calendar", "appleCalendar", "apple-calendar", "apple-mail", "gmail", "calendar", "google-calendar", "outlook", "outlook-mail",
            "outlook-calendar", "slack", "notion", "granola", "voice", "screen_capture", "hotkey", "mirror",
            "doubletap", "google-drive", "linear", "asana", "github", "teams", "dropbox", "box", "hubspot", "direct_connector", "provider", "invite", "mail_account", "app", "wakeHelper"]
        return known.contains(value) ? value : (value.hasPrefix("direct-") ? "direct_connector" : "other")
    }

    @TaskLocal static var current: Operation?

    final class Operation: Sendable {
        let id = UUID().uuidString
        let name: String
        private let parent: Operation?
        var parentID: String? { parent?.id }
        let began = Date()
        let backend: String
        private let failures = Mutex<Set<String>>([])
        private let causes = Mutex<Set<String>>([])
        private let phaseValue = Mutex<Phase?>(nil)
        var phase: Phase? {
            get { phaseValue.withLock { $0 } }
            set { phaseValue.withLock { $0 = newValue } }
        }
        init(_ name: StaticString, doubleTapProvider: DoubleTapProvider? = nil) {
            self.name = name.description; parent = Diagnostics.current
            backend = doubleTapProvider?.rawValue ?? ModelBackend.current.rawValue
        }
        var hasFailure: Bool { failures.withLock { !$0.isEmpty } }
        func claim(_ key: String) -> Bool {
            parent?.noteChildFailure()
            return failures.withLock { $0.insert(key).inserted }
        }
        func markReported(_ error: Error) {
            let key = Diagnostics.causeKey(error)
            causes.withLock { _ = $0.insert(key) }
            parent?.markReported(error)
        }
        func wasReported(_ error: Error) -> Bool { causes.withLock { $0.contains(Diagnostics.causeKey(error)) } }
        private func noteChildFailure() {
            failures.withLock { _ = $0.insert("child") }
            parent?.noteChildFailure()
        }
    }

    static func withOperation<T>(_ name: StaticString, isolation: isolated (any Actor)? = #isolation,
                                 _ body: () async throws -> T) async rethrows -> T {
        let operation = Operation(name)
        return try await $current.withValue(operation) {
            CrashReporting.diagnosticBreadcrumb("operation.begin", data: ["operation": operation.name, "operation_id": operation.id])
            defer {
                CrashReporting.diagnosticBreadcrumb("operation.end", data: ["operation": operation.name,
                    "operation_id": operation.id, "failed": String(operation.hasFailure),
                    "elapsed_ms": String(Int(Date().timeIntervalSince(operation.began) * 1000))])
            }
            if ["frontier_run", "computer_run"].contains(operation.name) {
                return try await ChildProcessDiagnostics.observe { try await body() }
            }
            return try await body()
        }
    }

    static func step(_ phase: Phase, source family: String? = nil) {
        current?.phase = phase
        var fields = ["phase": phase.rawValue]
        if let operation = current { fields["operation_id"] = operation.id; fields["operation"] = operation.name }
        if let family { fields["source"] = source(family) }
        CrashReporting.diagnosticBreadcrumb("operation.phase", data: fields)
    }

    struct Payload: Sendable {
        let event: String
        let tags: [String: String]
        let extra: [String: String]
        let fingerprint: [String]
    }

    /// Error metadata comes from the type, associated-case label and platform code, never its description/userInfo.
    static func errorFields(_ error: Error) -> [String: String] {
        let reflected = Mirror(reflecting: error)
        let typeName = String(describing: type(of: error))
        let safeType = typeName.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
        var fields = ["error_type": String(safeType.prefix(96))]
        if reflected.displayStyle == .enum, let label = reflected.children.first?.label {
            fields["error_case"] = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(64))
        }
        let ns = error as NSError
        let domains: Set<String> = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                                   "NSMachErrorDomain", "SQLite", "SQLiteError", "SUSparkleErrorDomain", "SUErrorDomain"]
        fields["error_domain"] = domains.contains(ns.domain) ? ns.domain : "application"
        fields["error_code"] = String(ns.code)
        switch error {
        case MirrorClient.MirrorError.http(let code, _): fields["http_status"] = String(code)
        case DoubleTapInference.Failure.http(let code, _): fields["http_status"] = String(code)
        case DirectMCPError.http(let code): fields["http_status"] = String(code)
        case CodexCLI.CLIError.exitFailure(let code, _): fields["exit_code"] = String(code)
        default: break
        }
        return fields
    }

    private static func causeKey(_ error: Error) -> String {
        let fields = errorFields(error)
        return [fields["error_type"], fields["error_case"], fields["error_domain"], fields["error_code"], fields["http_status"], fields["exit_code"]]
            .map { $0 ?? "" }.joined(separator: ":")
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
    }

    /// Expected user/configuration states remain breadcrumbs or UI messages, not wrapper defects.
    static func isExpected(_ error: Error) -> Bool {
        if isCancellation(error) { return true }
        if case VaultCloud.CloudError.vaultChanged = error { return true }
        switch error {
        case CodexRuntime.Failure.busy, OpenAIComputerUse.RuntimeError.helperRunning,
             OpenAIComputerUse.RuntimeError.permissionRequired, OpenAIComputerUse.RuntimeError.restartRequired,
             DirectMCPError.authorizationDenied, DirectMCPError.connectionChanged, DirectMCPError.reconnectRequired,
             DirectMCPError.accountSetupRequired, DirectMCPError.duplicateLabel, DirectMCPError.busy: return true
        default: break
        }
        switch CodexFailureReason.classify(error) {
        case .notInstalled, .notLoggedIn, .tokenExpired, .planDenied, .usageLimit: return true
        default: return false
        }
    }

    static func boundary<T>(_ event: Event, phase: Phase, reason: StaticString,
                            source: String? = nil, isolation: isolated (any Actor)? = #isolation,
                            _ body: () async throws -> T) async rethrows -> T {
        do { return try await body() }
        catch {
            if !isExpected(error) { report(event, phase: current?.phase ?? phase, reason: reason, error: error, source: source, terminal: true) }
            throw error
        }
    }

    static func payload(_ event: Event, phase: Phase, reason: StaticString,
                        error: Error? = nil, source family: String? = nil,
                        counts: [Count: Int] = [:], flags: [Flag: Bool] = [:]) -> Payload {
        var tags = ["phase": phase.rawValue, "reason": reason.description,
                    "backend": current?.backend ?? ModelBackend.current.rawValue, "diagnostic_schema": "1"]
        if let family { tags["source"] = source(family) }
        if let error { tags.merge(errorFields(error)) { _, new in new } }
        var extra = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, String($0.value)) })
        for (key, value) in flags { extra[key.rawValue] = String(value) }
        return Payload(event: event.rawValue, tags: tags, extra: extra,
                       fingerprint: [event.rawValue, phase.rawValue, reason.description, tags["error_type"] ?? "none",
                                     tags["error_case"] ?? tags["error_code"] ?? "none"])
    }

    /// terminal prevents outer wrappers from reporting the same already-diagnosed operation again.
    static func report(_ event: Event, phase: Phase, reason: StaticString = "unexpected",
                       error: Error? = nil, source: String? = nil,
                       counts: [Count: Int] = [:], flags: [Flag: Bool] = [:],
                       terminal: Bool = false, cooldown: TimeInterval = 900) {
        if let error, isCancellation(error) { return }
        if terminal {
            if let error, current?.wasReported(error) == true { return }
            if error == nil, current?.hasFailure == true { return }
        }
        if let error { current?.markReported(error) }
        let value = payload(event, phase: phase, reason: reason, error: error, source: source, counts: counts, flags: flags)
        CrashReporting.captureEvent(value.event, tags: value.tags, extra: value.extra,
                                    fingerprint: value.fingerprint, cooldown: cooldown)
    }

    static func removeForCleanup(_ url: URL, phase: Phase, reason: StaticString) {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let ns = error as NSError
            guard !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError) else { return }
            report(.cleanupFailed, phase: phase, reason: reason, error: error)
        }
    }

    enum BackgroundWork: String, Sendable { case migration, mailAccount, invite }
    private static let backgroundLock = Mutex(())
    static func backgroundFailure(_ work: BackgroundWork, now: Date = Date(), defaults: UserDefaults = .standard) -> [Count: Int]? {
        guard CrashReporting.diagnosticsEnabled else { return nil }
        return backgroundLock.withLock { _ in
            let key = "diagnostics.background." + work.rawValue
            let previous = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
            let began = min(previous["began"] ?? now.timeIntervalSince1970, now.timeIntervalSince1970)
            let count = min(Int(previous["attempts"] ?? 0) + 1, 1_000_000)
            defaults.set(["began": began, "attempts": Double(count)], forKey: key)
            guard count >= 3 else { return nil }
            return [.attempted: count, .ageHours: max(0, Int((now.timeIntervalSince1970 - began) / 3600))]
        }
    }
    static func backgroundRecovered(_ work: BackgroundWork, defaults: UserDefaults = .standard) {
        backgroundLock.withLock { _ in defaults.removeObject(forKey: "diagnostics.background." + work.rawValue) }
    }

    struct RepeatState: Sendable { var sent: Date; var suppressed = 0 }
    private static let repeats = Mutex<[String: RepeatState]>([:])

    /// Shared by existing and new events. Bounded memory; no durable user/content keys.
    static func claim(event: String, fingerprint: [String]?, tags: [String: String],
                      cooldown: TimeInterval, now: Date = Date()) -> Int? {
        let key = (fingerprint ?? [event]).joined(separator: ":") + ":" + (tags["source"] ?? "") + ":" + (tags["backend"] ?? "") + ":" + (tags["runtime"] ?? "")
        return repeats.withLock { values in
            if var previous = values[key], now.timeIntervalSince(previous.sent) < cooldown {
                previous.suppressed += 1; values[key] = previous; return nil
            }
            let suppressed = values[key]?.suppressed ?? 0
            if values.count >= 512 { values = values.filter { now.timeIntervalSince($0.value.sent) < 3600 } }
            if values.count >= 512 { values.removeAll(keepingCapacity: true) }
            values[key] = RepeatState(sent: now)
            return suppressed
        }
    }

    /// Observes non-returning on-device engine operations without cancelling or freeing their state.
    final class Watchdog: Sendable {
        private let finished = Mutex(false)
        private let operation: Operation?
        private let phase: Phase
        private let seconds: TimeInterval
        init(phase: Phase, seconds: TimeInterval) {
            operation = current; self.phase = phase; self.seconds = seconds
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.finished.withLock({ finished in
                    guard !finished else { return false }; finished = true; return true
                }) else { return }
                Diagnostics.$current.withValue(self.operation) {
                    let payload = Diagnostics.payload(.operationStalled, phase: self.phase, reason: "no_progress",
                                                      counts: [.elapsedMS: Int(self.seconds * 1000)])
                    var tags = payload.tags
                    tags["backend"] = "on_device"; tags["runtime"] = "litertlm"
                    CrashReporting.captureEvent(payload.event, tags: tags, extra: payload.extra,
                                                fingerprint: payload.fingerprint)
                }
            }
        }
        func finish() { finished.withLock { $0 = true } }
        deinit { finish() }
    }
}
