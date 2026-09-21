//
// WritingStyle.swift
// Creates writingstyle.md once from the user's own words in sent mail and local messages, each
// headed by who it went to and the medium.
// collect() gathers and renders the samples with no knowledge base needed; publishIfNeeded() lands
// the file once one exists; generateIfNeeded() is both, for the home's silent setup of an existing
// knowledge base. preserve() protects vault swaps.
// Doc: Documentation - Knowledge Base (Vault).md
//

import Foundation
import Darwin

nonisolated enum WritingStyle {
    static let fileName = "writingstyle.md"
    @MainActor private static var generating = false
    #if DEBUG
    @TaskLocal static var acceptanceSources: Set<String>?
    #endif

    enum Failure: LocalizedError {
        case noVault, busy, permissions, changed, tooLarge
        case mail(String)
        var errorDescription: String? {
            switch self {
            case .noVault: "Create your knowledge base first, then try again."
            case .busy: "Double Tap setup is already running. Try again when it finishes."
            case .permissions: "Allow Full Disk Access in Settings to read your sent messages, then try again."
            case .changed: "Your connected sources changed during setup. Try again with your current selection."
            case .tooLarge: "Your writing samples are too large to use in one reply. Your messages have not been shortened."
            case .mail(let slug): "Couldn’t read complete sent emails from \(slug == "gmail" ? "Gmail" : "Outlook"). Check its connection in Settings, then try again."
            }
        }
    }

    static func exists(in root: URL = VaultGenerator.vaultRoot) -> Bool {
        (try? root.appendingPathComponent(fileName).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
            .map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }

    @MainActor struct Selection: Equatable {
        let backend = ModelBackend.current
        // Writing samples are independent of the regular analysis/chat-picker selections.
        // All local one-to-one conversations participate when their source is present.
        let imessage: Bool
        let whatsapp: Bool
        let mail: [String]
        let origins: [String]
        init() {
            #if DEBUG
            if let sources = acceptanceSources {
                imessage = sources.contains("imessage")
                whatsapp = sources.contains("whatsapp")
                mail = ["gmail", OutlookMailConnector.slug].filter { sources.contains($0) }
                origins = mail.map { ConnectorRegistry.readOrigin(slug: $0, backend: ModelBackend.current) }
                return
            }
            #endif
            imessage = FileManager.default.fileExists(atPath: iMessageSource().dbPath)
            whatsapp = WhatsAppSource.isInstalled && FileManager.default.fileExists(atPath: WhatsAppSource().dbPath)
            var slugs: [String] = []
            if ModelBackend.connectorsAvailable {
                if UserDefaults.standard.bool(forKey: "dbg.gmail.connected") {
                    slugs.append("gmail")
                }
                if ConnectorRegistry.detectedForCurrentBackend().contains(where: { $0.slug == OutlookMailConnector.slug && $0.healthy }) {
                    slugs.append(OutlookMailConnector.slug)
                }
            }
            mail = slugs
            origins = slugs.map { ConnectorRegistry.readOrigin(slug: $0, backend: ModelBackend.current) }
        }
    }

    /// Collect, then land the file, for a knowledge base that already exists: the home's silent
    /// setup and the introduction sheet. Initial processing calls the two halves itself, so the
    /// collection can run alongside the first build.
    @MainActor static func generateIfNeeded(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let root = VaultGenerator.vaultRoot
        guard !exists(in: root) else { return }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path) else { throw Failure.noVault }
        let content = try await collect(progress: progress)
        progress("Saving your writing samples…")
        try publishIfNeeded(content, in: root)
    }

    /// The samples, rendered, without touching the knowledge base: only landing the file needs a
    /// vault, so the first build can gather these in parallel. Fewer samples are valid when the
    /// selected sources have less history, including none. Errors and cancellation leave nothing
    /// behind, so the next setup can retry honestly.
    @MainActor static func collect(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        guard !generating else { throw Failure.busy }
        generating = true
        PipelineActivity.begin()
        defer { generating = false; PipelineActivity.end() }
        let selection = Selection()
        if selection.imessage || selection.whatsapp {
            guard Permissions.hasFullDiskAccess() else { throw Failure.permissions }
        }
        let imessagePath = iMessageSource().dbPath, whatsappPath = WhatsAppSource().dbPath
        progress("Reading your sent messages…")
        let localTask = Task.detached {
            // The Mac's Contacts name iMessage handles and email addresses alike; best-effort.
            let names = selection.imessage || !selection.mail.isEmpty ? AddressBookNames.loadMap() : [:]
            let imessage = selection.imessage ? try LocalWritingSamples.iMessage(path: imessagePath, names: names) : []
            let whatsapp = selection.whatsapp ? try LocalWritingSamples.whatsApp(path: whatsappPath) : []
            return (imessage, whatsapp, names)
        }
        let (imessage, whatsapp, names) = try await withTaskCancellationHandler { try await localTask.value } onCancel: { localTask.cancel() }
        try Task.checkCancellation()
        var mail: [(source: String, sample: WritingStyleMail.Sample)] = []
        for slug in selection.mail {
            progress(slug == "gmail" ? "Reading your sent emails from Gmail…" : "Reading your sent emails from Outlook…")
            let samples = try await WritingStyleMail.read(slug: slug)
            mail += samples.map { (slug, $0) }
        }
        try Task.checkCancellation()
        guard selection == Selection() else { throw Failure.changed }
        // Each provider contributes its own latest 15 emails. Equal timestamps use stable
        // provider/message IDs; separate sent messages with identical bodies remain separate.
        mail.sort {
            if $0.sample.date != $1.sample.date { return $0.sample.date! > $1.sample.date! }
            return ($0.source + $0.sample.id) < ($1.source + $1.sample.id)
        }
        let entries = mail.map { Entry(to: named($0.sample.to, names: names), medium: "email", text: $0.sample.text) }
            + imessage.map { Entry(to: [$0.recipient], medium: "iMessage", text: $0.text) }
            + whatsapp.map { Entry(to: [$0.recipient], medium: "WhatsApp", text: $0.text) }
        let content = render(entries)
        // Keep every byte of the samples. Never silently lose them at the normal vault cap.
        guard content.utf8.count <= DoubleTapInference.vaultByteCeiling - 2_000 else { throw Failure.tooLarge }
        Log("WritingStyle: collected \(mail.count) emails, \(imessage.count) iMessage and \(whatsapp.count) WhatsApp messages")
        return content
    }

    /// Land collected samples in the knowledge base. A file that appeared meanwhile, the user's own
    /// or another run's, always wins.
    @MainActor static func publishIfNeeded(_ content: String, in root: URL = VaultGenerator.vaultRoot) throws {
        if exists(in: root) { return }
        try publish(content, in: root)
        #if DEBUG
        // Scratch-vault checks must not alter the real vault's sync state or schedule a push.
        if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil { VaultActivity.shared.markChanged() }
        #else
        VaultActivity.shared.markChanged()
        #endif
        Log("WritingStyle: saved to the knowledge base")
    }

    /// One sample as written: the user's words, who they went to, and the medium.
    struct Entry: Equatable, Sendable {
        let to: [String]
        let medium: String
        let text: String
    }

    /// Each sample under a "To NAME (medium)" line, samples separated by a blank line.
    static func render(_ entries: [Entry]) -> String {
        entries.map { "To \(recipientLine($0.to)) (\($0.medium))\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// An address the Mac's Contacts know becomes that contact's name; names pass through.
    static func named(_ to: [String], names: [String: String]) -> [String] {
        to.map { $0.contains("@") ? AddressBookNames.resolve($0, in: names) ?? $0 : $0 }
    }

    /// Up to three names, then a count; mail with no visible recipient says so.
    static func recipientLine(_ to: [String]) -> String {
        guard !to.isEmpty else { return "undisclosed recipients" }
        let shown = to.prefix(3).joined(separator: ", ")
        return to.count > 3 ? "\(shown) and \(to.count - 3) more" : shown
    }

    /// Same-volume, exclusive publication: the complete file appears at once, and a concurrent
    /// user-created file is never replaced. Temporary raw samples are removed on every exit path.
    static func publish(_ content: String, in root: URL) throws {
        let fm = FileManager.default
        let temporary = root.appendingPathComponent(".writingstyle-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = root.appendingPathComponent(fileName)
        guard link(temporary.path, destination.path) == 0 else {
            if errno == EEXIST, exists(in: root) { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The normal vault architect never owns this artifact. Restore the current original before
    /// every atomic swap, including rebuilds and resumed updates; drop an invented staged copy.
    static func preserve(in staging: URL, from live: URL) throws {
        let fm = FileManager.default
        let staged = staging.appendingPathComponent(fileName)
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        if exists(in: live) { try fm.copyItem(at: live.appendingPathComponent(fileName), to: staged) }
    }
}
