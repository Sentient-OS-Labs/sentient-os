// Prepares Sentient-funded inference and the local runtimes without a subscription login.
// prepare() is commitment-only; refresh() checks an already-selected connection and its allowance.
// Doc: Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md

import Foundation
import Observation

@MainActor
@Observable
final class SentientSetup {
    static let shared = SentientSetup()
    private(set) var preparing = false
    private(set) var checking = false
    private(set) var ready = false
    private(set) var status: String?
    private(set) var usage: HostedInference.Usage?
    @ObservationIgnored private var preparationTask: Task<Bool, Never>?

    static let unavailableMessage = "Sentient hosted inference is not available in this build yet. Choose your own provider to continue."
    var configured: Bool { HostedInference.isConfigured }

    /// Does not change the saved provider. Each caller checks its own selection before committing.
    func prepare() async -> Bool {
        if let preparationTask { return await preparationTask.value }
        guard configured else {
            ready = false; usage = nil; status = Self.unavailableMessage
            return false
        }
        preparing = true
        let task = Task { await prepareConnection() }
        preparationTask = task
        let result = await task.value
        preparationTask = nil
        preparing = false
        return result
    }

    private func prepareConnection() async -> Bool {
        ready = false
        status = "Connecting to Sentient…"
        do { usage = try await HostedInference.validate() }
        catch { status = error.localizedDescription; usage = nil; return false }
        guard !Task.isCancelled else { return false }
        status = "Preparing your AI runtime…"
        guard await ClaudeSetup.shared.ensureCurrent(), !Task.isCancelled else {
            status = ClaudeSetup.shared.installStatus ?? "The AI runtime couldn't be prepared. Try again."
            return false
        }
        status = "Preparing computer use…"
        guard await CodexSetup.shared.ensureCurrent(), !Task.isCancelled else {
            status = CodexSetup.shared.installStatus ?? "Computer use couldn't be prepared. Try again."
            return false
        }
        let computer = ComputerUseSetup.instance(for: .openAI)
        await computer.install()
        guard computer.ready, !Task.isCancelled else {
            status = computer.status ?? "Computer use couldn't be prepared. Try again."
            return false
        }
        // Configuration may have changed while downloads were in progress.
        guard configured else { status = Self.unavailableMessage; return false }
        ready = true
        status = nil
        return true
    }

    /// Browsing the provider picker does not silently enroll an installation.
    func refresh() async {
        guard !preparing, !checking else { return }
        guard configured else { ready = false; usage = nil; status = Self.unavailableMessage; return }
        guard ModelBackend.current == .sentient else { return }
        checking = true
        defer { checking = false }
        do {
            usage = try await HostedInference.validate()
            await ClaudeSetup.shared.refreshInstalled()
            await CodexSetup.shared.refreshInstalled()
            let computer = ComputerUseSetup.instance(for: .openAI)
            computer.refresh()
            ready = ClaudeSetup.shared.installed && CodexSetup.shared.computerUseReady
                && !CodexSetup.shared.outdated && computer.ready
            status = ready ? nil : "Finish setting up Sentient to resume hosted work."
        } catch {
            ready = false
            usage = nil
            status = error.localizedDescription
        }
    }
}
