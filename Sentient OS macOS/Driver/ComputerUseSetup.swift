// One observable installer per computer-use runtime, shared by onboarding, health and task startup.
// A task captures its backend; switching engines cannot redirect an in-flight installation.
// Doc: Driver/Documentation - Native Computer Use.md

import Foundation

@MainActor
@Observable
final class ComputerUseSetup {
    private static let native = ComputerUseSetup(backend: .openAI)
    private static let cua = ComputerUseSetup(backend: .cua)
    static var current: ComputerUseSetup { instance(for: .current) }
    static func instance(for backend: ComputerUseBackend) -> ComputerUseSetup {
        backend == .openAI ? native : cua
    }
    static func cancelAll() async {
        await native.cancelInstallation()
        await cua.cancelInstallation()
    }

    let backend: ComputerUseBackend
    private init(backend: ComputerUseBackend) {
        self.backend = backend
        ready = backend.isInstalled
    }
    private var hasInstallationHistory: Bool {
        backend == .cua ? CuaDriver.hasInstallationHistory : OpenAIComputerUseSetup.hasInstallationHistory
    }

    enum Progress: Sendable, Equatable {
        case downloading(Double?), verifying, unpacking, checkingSignature, checkingVersion, installing, ready

        var message: String {
            switch self {
            case .downloading: "Downloading…"
            case .verifying, .checkingSignature, .checkingVersion: "Verifying update…"
            case .unpacking: "Preparing computer use…"
            case .installing: "Finishing up…"
            case .ready: "Computer use is up to date."
            }
        }
    }

    // MARK: Installation state

    private(set) var ready = false
    /// The selected dependency install is running (drives the spinner + disables the button).
    private(set) var isInstalling = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var status: String?
    private(set) var failure: Error?
    private var lastInstallSucceeded = false

    /// Cheap re-detect — call on appear and after a setup.
    func refresh() {
        guard !isInstalling else { return }
        ready = backend.isInstalled
    }

    enum UpdateNotice: Equatable { case hidden, updating, failed, ready }
    private(set) var updateNotice: UpdateNotice = .hidden
    private(set) var progress: Progress?
    @ObservationIgnored private var installTask: Task<Bool, Never>?
    @ObservationIgnored private var installGeneration = UUID()

    /// Start shared dependency preparation on every normal app launch, including onboarding.
    /// Existing installs are validated and reused. Routine checks stay quiet; an established
    /// runtime missing required components retains its repair notice. No login or grants here.
    func prepareForLaunch() {
        beginInstall(announceUpdate: hasInstallationHistory && !backend.isInstalled)
    }

    func dismissUpdateNotice() {
        guard updateNotice != .updating else { return }
        updateNotice = .hidden
    }

    /// All callers join ONE install, including a command arriving during a background update.
    /// A force repair cannot race an onboarding download or swap the binary twice.
    func install(force: Bool = false) async {
        beginInstall(force: force)
        _ = await installTask?.value
    }

    private func beginInstall(force: Bool = false, announceUpdate: Bool = true) {
        guard installTask == nil else { return }
        if !force, backend == .cua, backend.isInstalled {
            ready = true
            lastInstallSucceeded = true
            status = "✓ Computer use already installed"
            return
        }
        if announceUpdate, hasInstallationHistory { updateNotice = .updating }
        isInstalling = true
        lastInstallSucceeded = false
        failure = nil
        ready = false
        progress = .downloading(nil)
        status = force ? "Re-installing…" : "Starting…"
        let generation = UUID()
        installGeneration = generation
        installTask = Task { [self] in
            defer {
                isInstalling = false
                installTask = nil
                // Warm the local helper after installation, even when health/upgrade checks
                // are deferred by migration. This never requests consent or contacts a model.
                if lastInstallSucceeded, backend == .current { ComputerUseGate.shared.refresh() }
            }
            do {
                try await installDependency(force: force, onProgress: { [weak self] progress in
                    guard let self, self.isInstalling, self.installGeneration == generation else { return }
                    // URLSession byte callbacks may arrive after the download has completed.
                    // Never let a late callback rewind verification or a newer progress value.
                    if case .downloading(let next) = progress {
                        guard case .downloading(let previous) = self.progress else { return }
                        if let previous, let next, next < previous { return }
                    }
                    self.progress = progress
                }) { line in
                    Log("[computer-use] \(line)")
                    Task { @MainActor [weak self] in
                        guard self?.isInstalling == true, self?.installGeneration == generation else { return }
                        self?.status = line
                    }
                }
                ready = true
                lastInstallSucceeded = true
                status = backend == .openAI ? "✓ Computer use installed" : "✓ Computer use ready"
                progress = .ready
                if updateNotice == .updating { updateNotice = .ready }
                return true
            } catch {
                failure = error
                ready = backend.isInstalled
                status = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                if updateNotice == .updating { updateNotice = .failed }
                if !Task.isCancelled { recordFailure(error) }
                return false
            }
        }
    }

    /// STOP cancels this waiter immediately, without canceling the shared background download.
    /// The install's own network deadline is authoritative; a slow connection must not hit the
    /// former two-minute waiter ceiling while the same download legitimately continues.
    @discardableResult
    func ensureInstalled() async -> Bool {
        if backend == .openAI, await !CodexSetup.shared.ensureComputerUseCLI() {
            failure = OpenAIComputerUse.RuntimeError.cliUnavailable
            status = "Computer use needs Codex CLI. Prepare it in Permissions & Health."
            return false
        }
        if !isInstalling, backend.isInstalled {
            // Runtime.start verifies the selected bundle under its runtime lease, once for
            // all callers sharing that startup. Do not also initialize an MCP client here.
            failure = nil
            ready = true
            return !Task.isCancelled
        }
        beginInstall()
        while isInstalling {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        guard !Task.isCancelled else { return false }
        refresh()
        return ready && lastInstallSucceeded
    }

    /// Uninstall must drain the installer before deleting the managed dependency directory.
    func cancelInstallation() async {
        installTask?.cancel()
        _ = await installTask?.value
        updateNotice = .hidden
    }


    private func installDependency(force: Bool,
                                  onProgress: @escaping @MainActor @Sendable (Progress) -> Void,
                                  onLine: @escaping @Sendable (String) -> Void) async throws {
        switch backend {
        case .openAI:
            guard await CodexSetup.shared.ensureComputerUseCLI() else {
                throw OpenAIComputerUse.RuntimeError.cliUnavailable
            }
            try await OpenAIComputerUseSetup.install(force: force, onProgress: onProgress, onLine: onLine)
        case .cua:
            try await CuaDriverSetup.install(force: force, onProgress: onProgress, onLine: onLine)
        }
    }

    private func recordFailure(_ error: Error) {
        guard !Diagnostics.isExpected(error) else { return }
        let phase: String
        switch progress {
        case .downloading: phase = "download"
        case .verifying, .checkingSignature, .checkingVersion: phase = "verify"
        case .unpacking: phase = "unpack"
        case .installing: phase = "install"
        default: phase = "setup"
        }
        CrashReporting.captureEvent("computer_use.setup_failed", level: .warning,
            tags: Diagnostics.errorFields(error).merging(["runtime": backend.rawValue, "phase": phase, "dependency_version": backend == .cua ? CuaDriver.version : CodexRuntime.release.helper.version]) { _, new in new },
            fingerprint: ["computer_use", "setup_failed", backend.rawValue, Diagnostics.errorFields(error)["error_case"] ?? Diagnostics.errorFields(error)["error_code"] ?? "unknown"])
    }
}
