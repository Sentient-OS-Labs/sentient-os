// Explicit native tool checks and bounded repairs, shared by Health and the agent's diagnostic tool.
// Never observes customer apps, changes TCC, uploads automatically, or terminates the parent agent.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable final class ComputerUseDoctor: NSObject, NSWindowDelegate {
    static let shared = ComputerUseDoctor()
    nonisolated static let savedReportKey = "computerUse.lastDiagnostic.v1"
    private(set) var report: ComputerUseCheckReport?
    private(set) var isRunning = false
    private(set) var controls: ComputerUseTestControls?
    var uploadMessage: String?
    var uploading = false
    @ObservationIgnored private var work: Task<ComputerUseCheckReport, Never>?
    @ObservationIgnored private var window: NSWindow?
    #if DEBUG
    @ObservationIgnored var testProbeFailures: [NativeComputerUseFailure] = []
    #endif

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.savedReportKey), data.count < 96_000 {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            report = try? decoder.decode(ComputerUseCheckReport.self, from: data)
        }
    }

    func start() {
        guard !isRunning else { show(); return }
        begin(source: .settings, backend: ModelBackend.current, call: nil)
    }
    func show() {
        if window == nil {
            let host = NSHostingController(rootView: ComputerUseDoctorView(doctor: self).preferredColorScheme(.dark))
            let panel = NSWindow(contentViewController: host)
            panel.title = "Computer-use check"
            panel.styleMask = [.titled, .closable, .miniaturizable]
            panel.backgroundColor = .black
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.setContentSize(NSSize(width: 540, height: 620))
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func cancel() { work?.cancel() }
    func windowWillClose(_ notification: Notification) { cancel(); window = nil }

    func clear(defaults: UserDefaults = .standard) async {
        let task = work; task?.cancel(); _ = await task?.value
        report = nil; window?.close(); window = nil
        defaults.removeObject(forKey: Self.savedReportKey)
    }

    /// The native broker owns serialization. This check uses its current session and does not
    /// restart the helper while the parent agent owns it. A dead session can recover on a read.
    func checkFromAgent(authorization: ComputerUseDiagnosticAuthorization, backend: ModelBackend,
                        call: @escaping ComputerUseCheckProbe.Call) async throws -> Data {
        guard !isRunning else {
            var busy = makeReport(source: .agent, backend: backend); busy.outcome = .busy; busy.finishedAt = Date()
            return try busy.encoded()
        }
        begin(source: .agent, backend: backend, call: call)
        guard let work else { throw CancellationError() }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return try result.encoded()
    }

    private func begin(source: ComputerUseCheckReport.Source, backend: ModelBackend, call: ComputerUseCheckProbe.Call?) {
        report = makeReport(source: source, backend: backend)
        uploadMessage = nil
        controls = ComputerUseTestControls()
        isRunning = true
        show()
        work = Task { [self] in
            await run(source: source, agentCall: call)
            controls = nil; isRunning = false
            report?.finish()
            let finished = report!
            if let data = try? finished.encoded() { UserDefaults.standard.set(data, forKey: Self.savedReportKey) }
            Analytics.signal("ComputerUse.checkFinished", parameters: ["source": source.rawValue,
                "backend": backend.rawValue,
                "outcome": finished.outcome.rawValue, "repair_attempted": String(finished.repairAttempted),
                "repair_verified": String(finished.repairVerified)])
            work = nil
            return finished
        }
    }

    private func makeReport(source: ComputerUseCheckReport.Source, backend: ModelBackend) -> ComputerUseCheckReport {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var report = ComputerUseCheckReport(source: source, environment: .init(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            binaryID: BuildIdentity.identifier, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            backend: backend.rawValue, helperVersion: CodexRuntime.release.helper.version,
            helperBuild: CodexRuntime.release.helperBuild, cliVersion: CodexRuntime.release.cli.version))
        let history = (try? DiagnosticHistory.snapshot().errors) ?? []
        report.recentEvents = Array(history.compactMap {
            ComputerUseCheckReport.TechnicalEvent(at: $0.at, event: $0.event, fields: $0.fields)
        }.suffix(16))
        return report
    }

    private func run(source: ComputerUseCheckReport.Source, agentCall: ComputerUseCheckProbe.Call?) async {
        let runtime = OpenAIComputerUseRuntime.shared
        let reservation = source == .settings ? runtime.reserveDiagnostic() : nil
        if source == .settings, reservation == nil { report?.outcome = .busy; return }
        var runtimeLease: CodexRuntime.FileLock?
        defer { runtimeLease?.unlock(); if let reservation { runtime.endDiagnostic(reservation) } }
        var session: OpenAIComputerUseSession?
        var stage = ComputerUseCheckReport.Check.runtime
        do {
            report?.update(stage, .running)
            if source == .settings {
                guard await ComputerUseSetup.instance(for: .openAI).ensureInstalled() else {
                    try Task.checkCancellation()
                    recordInfrastructureError(ComputerUseSetup.instance(for: .openAI).failure ?? OpenAIComputerUse.RuntimeError.incomplete, at: stage)
                    report?.outcome = .needsAttention; return
                }
            }
            var configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
            do { _ = try await OpenAIComputerUse.validate(at: configuration.appURL) }
            catch {
                let invalidHelper = (error as? OpenAIComputerUse.RuntimeError).map {
                    [.invalidSignature, .incomplete, .changedInstallation].contains($0)
                } ?? false
                let invalidPackage: Bool
                if case CodexRuntime.Failure.invalidPackage = error { invalidPackage = true } else { invalidPackage = false }
                guard source == .settings, invalidHelper || invalidPackage else { throw error }
                report?.repairAttempted = true; report?.update(.repair, .running)
                try await runtime.prepareForReinstall(configuration: configuration)
                let setup = ComputerUseSetup.instance(for: .openAI)
                guard await setup.ensureInstalled(force: true) else {
                    try Task.checkCancellation()
                    throw setup.failure ?? OpenAIComputerUse.RuntimeError.incomplete
                }
                configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                _ = try await OpenAIComputerUse.validate(at: configuration.appURL)
            }
            // Installation must finish before taking the read lease. Keep the selected
            // files stable through every native call and through cancellation cleanup.
            runtimeLease = try await CodexRuntime.sharedRuntimeLease()
            configuration = try configuration.afterRuntimeLease()
            report?.update(stage, .passed)
            stage = .permissions; report?.update(stage, .running)
            _ = try await runtime.start(configuration: configuration, stoppingConflictingHelpers: source == .settings)
            let automation = await Permissions.nativeAutomationState(ask: false)
            let screen = Permissions.hasScreenRecording()
            let ax = Permissions.tccState(service: "kTCCServiceAccessibility", clientBundleID: OpenAIComputerUse.bundleID)
            let capture = Permissions.tccState(service: "kTCCServiceScreenCapture", clientBundleID: OpenAIComputerUse.bundleID)
            report?.permissions = ["automation": String(describing: automation),
                "sentientScreenRecording": screen ? "granted" : "denied",
                "helperAccessibilityCached": ax.rawValue, "helperScreenRecordingCached": capture.rawValue]
            // An unreadable TCC database is unknown, not proof of denial. The actual probe
            // may still succeed; an explicit denied/unrequested grant points to setup first.
            guard screen, automation == .granted, ax != .denied, ax != .notAsked,
                  capture != .denied, capture != .notAsked else {
                report?.update(stage, .needsAttention); report?.outcome = .permissionsNeeded; return
            }
            report?.update(stage, .passed)
            guard let controls, let window else { throw CancellationError() }
            for _ in 0..<20 where controls.view.window !== window { try await Task.sleep(for: .milliseconds(50)) }
            let target = controls.target(window: window)
            let update: ComputerUseCheckProbe.Update = { [weak self] check, status, failure in
                self?.report?.update(check, status, failure: failure)
                if check == .accessibility, status == .passed { self?.report?.update(.connection, .passed) }
            }
            for attempt in 0..<2 {
                do {
                    try Task.checkCancellation()
                    stage = .connection; report?.update(stage, .running)
                    let call: ComputerUseCheckProbe.Call
                    if let agentCall { call = agentCall }
                    else {
                        let opened = try await OpenAIComputerUseSession.open(configuration)
                        session = opened
                        call = { tool, data in try await opened.call(tool, arguments: data, timeout: 12) }
                    }
                    #if DEBUG
                    if !testProbeFailures.isEmpty { throw testProbeFailures.removeFirst() }
                    #endif
                    try await ComputerUseCheckProbe.run(target: target, call: call, update: update)
                    await session?.close(); session = nil
                    let repaired = report?.repairAttempted == true
                    report?.repairVerified = repaired
                    report?.outcome = repaired ? .repaired : .passed
                    if repaired { report?.update(.repair, .passed) }
                    return
                } catch {
                    await session?.close(); session = nil
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    let failure = error as? NativeComputerUseFailure
                    guard attempt == 0, source == .settings, let failure,
                          ComputerUseCheckReport.allowsConnectionRepair(failure) else { throw error }
                    // Only idle-runtime repair, once, followed by the complete real check.
                    report?.repairAttempted = true; report?.update(.repair, .running, failure: failure)
                    runtimeLease?.unlock(); runtimeLease = nil
                    try await runtime.restart(configuration: configuration)
                    runtimeLease = try await CodexRuntime.sharedRuntimeLease()
                    configuration = try configuration.afterRuntimeLease()
                    _ = try await runtime.start(configuration: configuration, stoppingConflictingHelpers: true)
                    try await Task.sleep(for: .milliseconds(500))
                    controls.reset()
                }
            }
        } catch {
            await session?.close()
            if error is CancellationError || Task.isCancelled { report?.outcome = .cancelled; return }
            if let failure = error as? NativeComputerUseFailure {
                if report?.steps.last?.status == .running { report?.update(stage, .needsAttention, failure: failure) }
                report?.outcome = ComputerUseCheckReport.outcome(for: failure)
            } else {
                recordInfrastructureError(error, at: stage)
                if case CodexRuntime.Failure.busy = error { report?.outcome = .busy }
                else if (error as? OpenAIComputerUse.RuntimeError) == .helperRunning { report?.outcome = .busy }
                else { report?.outcome = (error as? OpenAIComputerUse.RuntimeError) == .permissionRequired ? .permissionsNeeded : .needsAttention }
            }
            if report?.repairAttempted == true { report?.update(.repair, .needsAttention) }
        }
    }

    private func recordInfrastructureError(_ error: Error, at check: ComputerUseCheckReport.Check) {
        guard var snapshot = report else { return }
        if let runtime = error as? OpenAIComputerUse.RuntimeError {
            snapshot.update(check, .needsAttention)
            if let index = snapshot.steps.firstIndex(where: { $0.check == check }) {
                snapshot.steps[index].evidence["runtime_error"] = String(describing: runtime)
            }
        } else if let setup = error as? CodexRuntime.Failure {
            snapshot.update(check, .needsAttention)
            if let index = snapshot.steps.firstIndex(where: { $0.check == check }) {
                snapshot.steps[index].evidence["runtime_error"] = String(describing: setup)
            }
        } else {
            var failure = NativeComputerUseFailure(kind: .unknown, code: nil, detail: .unspecified, stage: .probe)
            failure.recordSystemError(error)
            snapshot.update(check, .needsAttention, failure: failure)
        }
        report = snapshot
    }

    func saveReport() {
        guard !isRunning, let report, let data = try? report.encoded() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sentient-Computer-Use-\(report.id.uuidString.prefix(8)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); uploadMessage = "Saved locally. Report not sent." }
        catch { uploadMessage = "The report couldn’t be saved. Try another location." }
    }

    func sendReport() {
        guard !uploading, !isRunning, let report else { return }
        uploading = true; uploadMessage = nil
        Task {
            defer { uploading = false }
            do {
                let receipt = try await ComputerUseReportUpload.shared.send(report)
                if self.report?.id == report.id { uploadMessage = "Sent to the Sentient team. Report " + String(receipt.uuidString.prefix(8)) + "." }
            } catch {
                if self.report?.id == report.id { uploadMessage = "The report couldn’t be sent. Save a copy to share with support, or try again later." }
            }
        }
    }
}

@MainActor final class ComputerUseTestControls: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 100))
    let nonce = String(UUID().uuidString.prefix(8))
    let field = NSTextField()
    private(set) var clicks = 0
    private var button: NSButton!
    var marker: String { "Sentient check \(nonce)" }
    var buttonLabel: String { "Check button \(nonce)" }
    var fieldLabel: String { "Check text \(nonce)" }
    var expectedText: String { "Hello from Sentient" }
    override init() {
        super.init()
        let title = NSTextField(labelWithString: "A little space to check things.")
        title.setAccessibilityLabel(marker)
        title.font = .systemFont(ofSize: 11); title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 0, y: 75, width: 450, height: 18)
        button = NSButton(title: "Try a click", target: self, action: #selector(clicked))
        button.setAccessibilityLabel(buttonLabel)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 0, y: 35, width: 220, height: 32)
        field.frame = NSRect(x: 235, y: 39, width: 225, height: 25)
        field.placeholderString = "Test text appears here"
        field.setAccessibilityLabel(fieldLabel)
        view.addSubview(title); view.addSubview(button); view.addSubview(field)
    }
    @objc private func clicked() { clicks += 1; button.title = "Click checked" }
    func reset() { clicks = 0; field.stringValue = ""; button.title = "Try a click" }
    func target(window: NSWindow) -> ComputerUseCheckProbe.Target {
        .init(app: Bundle.main.bundleURL.path, marker: marker, buttonLabel: buttonLabel,
              fieldLabel: fieldLabel, expectedText: expectedText,
              isCurrent: { [weak self, weak window] in
                  guard let self, let window else { return false }
                  return window.isVisible && window.isOnActiveSpace && !window.isMiniaturized
                      && self.view.window === window && NSApp.keyWindow === window
              }, wasClicked: { [weak self] in (self?.clicks ?? 0) > 0 },
              textMatches: { [weak self] in guard let self else { return false }; return self.field.stringValue == self.expectedText })
    }
}
