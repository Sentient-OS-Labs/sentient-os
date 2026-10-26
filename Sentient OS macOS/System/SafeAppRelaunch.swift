// Source permission changes may require a fresh process. Restart preserves unsent work,
// waits for explicit leave approval, and launches a replacement only after this process exits.
import AppKit
import Foundation
import Observation

@MainActor @Observable
final class SafeAppRelaunch {
    static let shared = SafeAppRelaunch()
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var ticket: PermissionRelaunchHandoff.Ticket?
    private var preparationID: UUID?
    private(set) var failure: String?
    private(set) var isPreparing = false
    private var savedResume = false
    private var resumePersonalSetup = false
    private(set) var isApplicationTerminating = false
    private init() {}

    func configure(_ state: AppState) { appState = state }

    private var blockingReason: String? { blockingReason(allowPermissionWait: false) }
    private func blockingReason(allowPermissionWait: Bool) -> String? {
        guard let appState else { return "Reopen Sentient to finish permission setup." }
        if appState.isUninstalling || appState.processing.isSuspended { return "Wait for the current maintenance to finish." }
        if (appState.commandCoordinator.run.isRunning
            && !(allowPermissionWait && appState.commandCoordinator.run.canSavePermissionWaitForRelaunch))
            || DoubleTap.shared.isDrafting {
            return "Finish or stop the current Sidekick task before relaunching."
        }
        if appState.processing.isBusy || PipelineActivity.shared.isRunning {
            return "Pause analysis and wait for it to stop before relaunching."
        }
        if CodexSetup.shared.installing || CodexSetup.shared.preparing || ClaudeSetup.shared.installing
            || ClaudeSetup.shared.preparing || ComputerUseSetup.current.isInstalling {
            return "Wait for the current setup download to finish before relaunching."
        }
        if NativePermissionCheck.shared.isChecking || ComputerUseDoctor.shared.isRunning {
            return "Finish the computer-use check before relaunching."
        }
        return nil
    }
    var statusReason: String? { isPreparing ? "Preparing to relaunch…" : (blockingReason ?? failure) }
    var canRelaunch: Bool { !isPreparing && blockingReason == nil }
    var allowsAutomaticRelaunch: Bool {
        !isPreparing && blockingReason == nil && appState?.hasCompletedOnboarding == true
    }
    var canRelaunchPermissionWait: Bool {
        !isPreparing && appState?.commandCoordinator.run.canSavePermissionWaitForRelaunch == true
            && blockingReason(allowPermissionWait: true) == nil
    }

    @discardableResult
    func relaunchPermissionWait() -> Bool {
        guard canRelaunchPermissionWait, let appState else { return false }
        failure = nil; isPreparing = true
        let id = UUID(); preparationID = id
        preparation = Task {
            let saved = await appState.commandCoordinator.run.savePermissionWaitForRelaunch()
            guard preparationID == id else { return }
            preparation = nil; preparationID = nil; isPreparing = false
            guard saved, !Task.isCancelled else {
                failure = "Keep your request in the composer and finish or stop the current work before relaunching."
                return
            }
            _ = relaunchPreservingDraft()
        }
        return true
    }

    /// True means the user request was accepted; asynchronous preparation can still fail visibly.
    @discardableResult
    func relaunchForPersonalSetup() -> Bool {
        requestRelaunch(resumePersonalSetup: true)
    }

    @discardableResult
    func relaunchPreservingDraft() -> Bool {
        requestRelaunch(resumePersonalSetup: false)
    }

    private func requestRelaunch(resumePersonalSetup: Bool) -> Bool {
        failure = nil
        guard canRelaunch else { return false }
        self.resumePersonalSetup = resumePersonalSetup
        isPreparing = true
        let id = UUID(); preparationID = id
        MainNavigation.shared.confirmLeavingKnowledge { [weak self] approved in
            guard let self, self.preparationID == id else { return }
            guard approved else { self.cancelPendingRelaunch(); return }
            self.preparation = Task { await self.prepareRelaunch(id: id) }
        }
        return true
    }

    private func prepareRelaunch(id: UUID) async {
        defer { if preparationID == id { preparation = nil } }
        do {
            let prepared = try await PermissionRelaunchHandoff.prepare()
            guard preparationID == id else { prepared.cancel(); return }
            ticket = prepared
            try Task.checkCancellation()
            // Native proof clients have a real subprocess lifetime even while no task is active.
            await NativePermissionCheck.shared.close()
            try Task.checkCancellation()
            guard blockingReason == nil, let appState, prepared.isReady else {
                throw PermissionRelaunchHandoff.Failure.notReady
            }
            let conversation = appState.commandCoordinator.run.conversation
            do {
                try PermissionRelaunchDraft.save(.init(text: conversation.draft, reply: conversation.replyReference,
                                                       generation: conversation.generation))
            } catch {
                cancelPendingRelaunch(reason: "Your unsent Sidekick message could not be saved. Try again before relaunching.")
                return
            }
            UserDefaults.standard.set(resumePersonalSetup, forKey: PersonalSetupProgress.resumeKey)
            savedResume = true
            // The delegate repeats the live Knowledge guard and commits only after draining.
            // The helper has no authority to launch anything until that final approval.
            NSApp.terminate(nil)
        } catch {
            if preparationID == id { cancelPendingRelaunch(reason: error is CancellationError ? nil : error.localizedDescription) }
        }
    }

    /// Called by the app delegate immediately before its final affirmative termination reply.
    /// Standard Quit has no prepared handoff and simply continues after draining the proof client.
    func approveTermination() -> Bool {
        guard let ticket else { isApplicationTerminating = true; return true }
        if let blockingReason {
            cancelPendingRelaunch(reason: blockingReason)
            return false
        }
        do { try ticket.commit(); isApplicationTerminating = true; return true }
        catch { cancelPendingRelaunch(reason: error.localizedDescription); return false }
    }

    func cancelPendingRelaunch(reason: String? = nil) {
        preparation?.cancel()
        preparationID = nil
        ticket?.cancel(); ticket = nil
        if savedResume {
            UserDefaults.standard.removeObject(forKey: PersonalSetupProgress.resumeKey)
            PermissionRelaunchDraft.clear()
        }
        savedResume = false; isPreparing = false
        isApplicationTerminating = false
        failure = reason
    }
}

/// This one-use file is private app data, never diagnostics or an outgoing request. It only
/// preserves an unsent composer across an explicit permission restart; it is never submitted.
enum PermissionRelaunchDraft {
    struct Snapshot: Codable {
        let text: String
        let reply: SidekickConversationEvent.ReplyReference?
        let generation: UUID?
    }
    private static var url: URL { URL.sentientSupport.appendingPathComponent("Sidekick/PermissionRelaunchDraft.json") }
    static func save(_ snapshot: Snapshot) throws {
        let file = url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if snapshot.text.isEmpty && snapshot.reply == nil { try? FileManager.default.removeItem(at: file); return }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_000_000 else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Read without consuming; AppState removes this only after a matching-generation restore.
    static func take() -> Snapshot? {
        let file = url
        guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? .max) <= 1_000_000 else { return nil }
        guard let data = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return snapshot
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}
