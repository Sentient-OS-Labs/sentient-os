// Trusts an explicit hosted-connector confirmation, then wakes its provider in the background.
// Defers disclosed contact collection until mailbox processing; neither job gates source selection.
// Doc: ../Sources/Documentation - Sources - Cloud (Gmail, Calendar).md

import Foundation

@MainActor
enum HostedConnectorSetup {
    private static var jobs: [String: Task<Void, Never>] = [:]
    private static var collectionJobs: [String: Task<Void, Never>] = [:]
    private static var reconnects: Set<String> = []
    private static var teardownDepth = 0

    /// Done is the user's declaration. Provider discovery and optional contact collection must
    /// never gate it, and a sheet opened under another backend cannot select the wrong account.
    @discardableResult
    static func confirm(slug: String, backend: ModelBackend = .current, reconnected: Bool = false) -> Bool {
        guard teardownDepth == 0, backend != .custom, ModelBackend.current == backend else { return false }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard !slug.hasPrefix("direct-") else { return false }
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
        schedule(slug: slug, backend: backend, reconnected: reconnected)
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

    /// Start alongside the first ensuing mailbox read, never from the connector screen.
    /// A missing address remains pending for the next read, including iterative runs. Once
    /// queued by MailAccountCloud, that actor owns upload retries and discovery need not repeat.
    static func processingStarted(slug: String, backend: ModelBackend = .current) {
        guard teardownDepth == 0, !Task.isCancelled else { return }
        let slug = ConnectorRegistry.canonicalSlug(slug)
        guard let request = mailCollectionRequest(slug: slug, backend: backend),
              let requestID = UserDefaults.standard.string(forKey: request.key),
              collectionJobs[request.key] == nil else { return }
        let warmup = jobs[backend.rawValue + ":" + slug]
        collectionJobs[request.key] = Task {
            defer { collectionJobs[request.key] = nil }
            // Fast onboarding may reach processing before its wake prompt finishes. Wait
            // here in the background, keeping the mailbox's actual read independent.
            await warmup?.value
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

    private static func schedule(slug: String, backend: ModelBackend, reconnected: Bool) {
        let key = backend.rawValue + ":" + slug
        if jobs[key] != nil {
            // Coalesce duplicate Done clicks. A later browser reconnect deserves another wake
            // after any already-running work, since its newly linked state may not exist yet.
            if reconnected { reconnects.insert(key) }
            return
        }
        jobs[key] = Task {
            defer { jobs[key] = nil; reconnects.remove(key) }
            repeat {
                reconnects.remove(key)
                await ModelBackend.$runOverride.withValue(backend) {
                    await warm(slug: slug, backend: backend)
                }
            } while !Task.isCancelled && reconnects.contains(key)
        }
    }

    private static func warm(slug: String, backend: ModelBackend) async {
        guard !Task.isCancelled else { return }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-connector-warm-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: workspace) }
            var invocation = CodexCLI.Invocation(prompt: "Hi. Reply with exactly OK. Do not call tools or access any files, messages, calendars or other content.")
            invocation.feature = "census"
            invocation.model = .gpt6luna
            invocation.effort = .low
            invocation.sandbox = .readOnly
            invocation.webSearch = false
            invocation.timeout = 60
            invocation.cwd = workspace.path
            if backend == .claude, ConnectorRegistry.server(for: slug)?.claudeServerURL != nil {
                // Allow the hosted connector to attach, with no connector-tool approval grants.
                // toolsDisabled would prevent that attachment and defeat this best-effort wake.
                invocation.mcpAttachServer = slug
                invocation.connectorOnlyRead = true
            } else {
                invocation.includeUserConfig = false
                // Unknown Claude connectors still get a harmless provider wake. ChatGPT's
                // hosted apps survive ignore-user-config, as in the existing census warmup.
                if backend == .claude { invocation.toolsDisabled = true }
            }
            _ = try await CodexTrigger.$current.withValue(.probe) {
                try await FrontierRun.run(invocation)
            }
        } catch {
            if !Task.isCancelled { Log("Hosted connector warmup deferred (\(ErrorLabel(error)))") }
        }
    }

    /// Stop and drain before reset/uninstall changes connector or contact state. New Done
    /// actions remain suspended through the whole teardown, including its asynchronous steps.
    static func beginTeardown() async {
        teardownDepth += 1
        reconnects.removeAll()
        let pending = Array(jobs.values) + Array(collectionJobs.values)
        for job in pending { job.cancel() }
        for job in pending { await job.value }
    }

    static func endTeardown() {
        teardownDepth = max(0, teardownDepth - 1)
    }
}
