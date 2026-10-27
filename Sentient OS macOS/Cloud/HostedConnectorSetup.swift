// Verifies native hosted-connection metadata on explicit Done, without a model turn.
// Defers disclosed contact collection until actual mailbox processing.
// Doc: ../Sources/Documentation - Sources - Cloud (Gmail, Calendar).md

import Foundation

@MainActor
enum HostedConnectorSetup {
    private static var collectionJobs: [String: Task<Void, Never>] = [:]
    private static var teardownDepth = 0
    private static var generation = 0
    private struct VerificationJob {
        let slug: String
        let task: Task<Bool, Never>
    }
    private static var verificationJobs: [UUID: VerificationJob] = [:]
    // Source selections are shared by every window and backend. A later Stop reading or
    // reconnect therefore retires every older confirmation for that same canonical source.
    private static var sourceRevisions: [String: UInt64] = [:]

    /// Explicit Done checks only native connection metadata. A cancellation/backend change
    /// cannot save a late selection, and no model turn or content read is used for readiness.
    static func verifyAndConfirm(slug: String, backend: ModelBackend = .current, reconnected: Bool = false) async -> Bool {
        guard teardownDepth == 0, !Task.isCancelled, ModelBackend.current == backend else { return false }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        let startedGeneration = generation, id = UUID()
        let revision = advanceSourceRevision(slug)
        let verification = Task { await ConnectorCensus.verifyConnection(slug: slug, backend: backend) }
        verificationJobs[id] = VerificationJob(slug: slug, task: verification)
        defer { verificationJobs.removeValue(forKey: id) }
        let ready = await withTaskCancellationHandler { await verification.value } onCancel: { verification.cancel() }
        guard ready, !Task.isCancelled, teardownDepth == 0, generation == startedGeneration,
              sourceRevisions[slug] == revision,
              ModelBackend.current == backend else { return false }
        return confirm(slug: slug, backend: backend, reconnected: reconnected)
    }

    /// This synchronous persistence seam also requires native readiness. Callers cannot turn
    /// an unverified browser declaration into a connected source by skipping the async check.
    @discardableResult
    static func confirm(slug: String, backend: ModelBackend = .current, reconnected: Bool = false) -> Bool {
        guard teardownDepth == 0, backend != .custom, ModelBackend.current == backend else { return false }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-"), ConnectorCensus.isReady(slug: slug, backend: backend) else { return false }
        ConnectorCensus.confirmSelection(slug: slug, reconnected: reconnected)
        let defaults = UserDefaults.standard
        switch slug {
        case "gmail":
            defaults.set(true, forKey: "dbg.gmail.connected")
            defaults.set(true, forKey: "dbg.run.gmail")
        case "google-calendar":
            defaults.set(true, forKey: "dbg.calendar.connected")
            defaults.set(true, forKey: "dbg.run.calendar")
        default:
            if ConnectorRegistry.kbEligible(slug, backend: backend) {
                ConnectorRegistry.setKBEnabled(slug, true)
            }
        }
        if let request = mailCollectionRequest(slug: slug, backend: backend) {
            // Persist intent, not an address, so quitting between onboarding and processing
            // does not lose the disclosed request. Existing selections never imply consent.
            defaults.set(UUID().uuidString, forKey: request.key)
        }
        return true
    }

    /// Opening settings may change the hosted account without changing its service slug.
    /// Conservatively request a backfill for selected sources, even if the user only looks.
    /// The existing checkpoint and notes remain intact until a subsequent read succeeds.
    /// This is not a new declaration or consent to collect an address: no background work runs.
    static func settingsOpened(slug: String, backend: ModelBackend = .current) {
        guard teardownDepth == 0, backend != .custom, ModelBackend.current == backend else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-") else { return }
        advanceSourceRevision(slug)
        ConnectorCensus.invalidateReadiness(slug: slug, backend: backend)
        let defaults = UserDefaults.standard
        let selected: Bool
        switch slug {
        case "gmail": selected = defaults.bool(forKey: "dbg.run.gmail")
        case "google-calendar": selected = defaults.bool(forKey: "dbg.run.calendar")
        default:
            selected = ConnectorRegistry.kbEligible(slug, backend: backend)
                && ConnectorRegistry.isKBEnabled(slug)
        }
        guard selected else { return }
        let key = ConnectorRegistry.readGenerationKey(slug, backend.rawValue)
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    /// A source-level opt-out wins over Done in any other open window. It keeps the linked
    /// provider and existing knowledge, but retires pending verification and contact consent.
    static func stopReading(slug: String, backend: ModelBackend = .current) {
        guard teardownDepth == 0, ModelBackend.current == backend else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-") else { return }
        advanceSourceRevision(slug)
        let defaults = UserDefaults.standard
        switch slug {
        case "gmail": defaults.set(false, forKey: "dbg.run.gmail")
        case "google-calendar": defaults.set(false, forKey: "dbg.run.calendar")
        default: ConnectorRegistry.setKBEnabled(slug, false)
        }
        for provider in [ModelBackend.chatgpt, .claude] {
            guard let request = mailCollectionRequest(slug: slug, backend: provider) else { continue }
            defaults.removeObject(forKey: request.key)
            collectionJobs[request.key]?.cancel()
        }
    }

    @discardableResult
    private static func advanceSourceRevision(_ slug: String) -> UInt64 {
        let revision = (sourceRevisions[slug] ?? 0) &+ 1
        sourceRevisions[slug] = revision
        for job in verificationJobs.values where job.slug == slug { job.task.cancel() }
        return revision
    }

    /// Start alongside the first ensuing mailbox read, never from the connector screen.
    /// A missing address remains pending for the next read, including iterative runs. Once
    /// queued by MailAccountCloud, that actor owns upload retries and discovery need not repeat.
    static func processingStarted(slug: String, backend: ModelBackend = .current) {
        guard teardownDepth == 0, !Task.isCancelled else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard let request = mailCollectionRequest(slug: slug, backend: backend),
              let requestID = UserDefaults.standard.string(forKey: request.key),
              collectionJobs[request.key] == nil else { return }
        collectionJobs[request.key] = Task {
            defer { collectionJobs[request.key] = nil }
            guard !Task.isCancelled, teardownDepth == 0,
                  UserDefaults.standard.string(forKey: request.key) == requestID else { return }
            do {
                let outcome = try await ModelBackend.$runOverride.withValue(backend) {
                    try await MailAccountCollection.collect(engine: request.engine, provider: request.provider)
                }
                guard !Task.isCancelled else { return }
                switch outcome {
                case .saved, .pending:
                    // A reconnect during discovery is a new request for a potentially different
                    // account. An older result must not consume that newer declaration.
                    if UserDefaults.standard.string(forKey: request.key) == requestID {
                        UserDefaults.standard.removeObject(forKey: request.key)
                    }
                case .noConnection, .noAddress:
                    break
                }
            } catch {
                if !Task.isCancelled { Log("Hosted connector contact collection deferred (\(ErrorLabel(error)))") }
            }
        }
    }

    private static func mailCollectionRequest(slug: String, backend: ModelBackend)
        -> (key: String, engine: MailAccount.Engine, provider: MailAccount.Provider)? {
        guard let engine = MailAccount.Engine(rawValue: backend.rawValue) else { return nil }
        let provider: MailAccount.Provider
        if slug == "gmail" { provider = .gmail }
        else if OutlookMailConnector.isMail(slug) { provider = .outlook }
        else { return nil }
        return ("connectedEmail.pendingCollection.\(engine.rawValue).\(provider.rawValue)", engine, provider)
    }

    /// Stop and drain before reset/uninstall changes connector or contact state. New Done
    /// actions remain suspended through the whole teardown, including its asynchronous steps.
    static func beginTeardown() async {
        teardownDepth += 1
        generation &+= 1
        let verifications = verificationJobs.values.map(\.task)
        for job in verifications { job.cancel() }
        for job in verifications { _ = await job.value }
        let pending = Array(collectionJobs.values)
        for job in pending { job.cancel() }
        for job in pending { await job.value }
    }

    static func endTeardown() {
        teardownDepth = max(0, teardownDepth - 1)
    }
}
