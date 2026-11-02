// Trusts explicit Done as the user's hosted-source selection, without a provider probe.
// Defers disclosed contact collection until actual mailbox processing.
// Doc: ../Sources/Documentation - Sources - Cloud (Gmail, Calendar).md

import Foundation

@MainActor
enum HostedConnectorSetup {
    enum PageProgress: String {
        case unopened, awaitingConfirmation, confirmed
    }

    /// Keep browser handoffs across sheet dismissal and app restart, scoped to the reader.
    /// The mcp namespace also lets the existing factory reset clear this setup history.
    static func pageProgressKey(slug: String, backend: ModelBackend) -> String {
        "mcp.\(ConnectorRegistry.canonicalSlug(slug)).pageProgress.\(backend.rawValue)"
    }

    private static var collectionJobs: [String: Task<Void, Never>] = [:]
    private static var teardownDepth = 0
    /// Done saves the user's declaration immediately. Actual reads record health observations;
    /// provider discovery and optional contact collection never gate source selection.
    @discardableResult
    static func confirm(slug: String, backend: ModelBackend = .current, reconnected: Bool = false) -> Bool {
        guard teardownDepth == 0, !Task.isCancelled, backend.hasSubscriptionConnectors, ModelBackend.current == backend else { return false }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-") else { return false }
        let defaults = UserDefaults.standard
        let progressKey = pageProgressKey(slug: slug, backend: backend)
        let awaitingConfirmation = defaults.string(forKey: progressKey) == PageProgress.awaitingConfirmation.rawValue
        ConnectorCensus.confirmSelection(slug: slug, reconnected: reconnected || awaitingConfirmation)
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
        defaults.set(PageProgress.confirmed.rawValue, forKey: progressKey)
        return true
    }

    /// Opening settings may change the hosted account without changing its service slug.
    /// Conservatively request a backfill for selected sources, even if the user only looks.
    /// The existing checkpoint and notes remain intact until a subsequent read succeeds.
    /// This is not a new declaration or consent to collect an address: no background work runs.
    static func settingsOpened(slug: String, backend: ModelBackend = .current) {
        guard teardownDepth == 0, backend.hasSubscriptionConnectors, ModelBackend.current == backend else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-") else { return }
        let defaults = UserDefaults.standard
        defaults.set(PageProgress.awaitingConfirmation.rawValue,
                     forKey: pageProgressKey(slug: slug, backend: backend))
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

    /// Source selection is synchronous, so no delayed provider response can undo this opt-out.
    /// Keep the provider connection and existing knowledge; retire pending contact consent.
    static func stopReading(slug: String, backend: ModelBackend = .current) {
        guard teardownDepth == 0, ModelBackend.current == backend else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-") else { return }
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
        let pending = Array(collectionJobs.values)
        for job in pending { job.cancel() }
        for job in pending { await job.value }
    }

    static func endTeardown() {
        teardownDepth = max(0, teardownDepth - 1)
    }
}
