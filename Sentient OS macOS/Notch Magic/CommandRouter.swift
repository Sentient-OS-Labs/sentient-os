//
//  CommandRouter.swift
//  Sentient OS macOS
//
//  The pre-run router for Sidekick / command-bar submissions: one cheap, hermetic frontier
//  call (luna tier → haiku on Claude, low effort, ~1-3s) that decides whether a command can
//  ride the screen-free connector spine — the ENTIRE task fits ONE connected service's tools —
//  or needs computer use. Fail-closed toward computer: any error, timeout, unparseable reply,
//  or unlisted target routes there, and a wrong "computer" pick costs nothing because the
//  connector tools ride that run too. Skipped entirely — no run, no latency — when the census
//  detects no connectors (BYOM included: a custom backend detects none); the two dedicated-chip
//  services (Gmail, Google Calendar) join the routable list only once the router runs at all.
//  Card fires never pass through here (beginExternalRun adopts the run without start()).
//
//  Key surface: isActive · route(_:) → .computer | .connector(slug:name:) ·
//  routableServices() (internal for the connector lab's routereval; lab dies at Step 4).
//  Doc: Documentation - Sidekick - General.md (this folder).
//

import Foundation

enum CommandRouter {

    enum Route: Equatable {
        case computer
        case connector(slug: String, name: String)
    }

    /// Whether submissions route at all. Keyed on the census ONLY (README decision #7: zero
    /// detected connectors = today's users = no router latency) — the chips alone never
    /// activate it, they only join the service list once something is detected.
    static var isActive: Bool { !ConnectorRegistry.detectedForCurrentBackend().isEmpty }

    /// One routable service, as the router prompt lists it.
    struct Service { let slug: String; let name: String; let description: String }

    /// Chips first (when connected), then every detected connector — stable order, deduped.
    /// Curated packs supply the display name + one-line description; uncurated connectors
    /// ride on their census display name alone.
    static func routableServices() -> [Service] {
        var services: [Service] = []
        func add(_ slug: String, _ fallbackName: String?) {
            guard !services.contains(where: { $0.slug == slug }) else { return }
            let pack = ConnectorRegistry.pack(forSlug: slug)
            services.append(Service(slug: slug,
                                    name: pack?.displayName ?? fallbackName
                                        ?? ConnectorCensus.titleCased(slug),
                                    description: pack?.routerDescription ?? ""))
        }
        if UserDefaults.standard.bool(forKey: "dbg.gmail.connected") { add("gmail", nil) }
        if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") { add("google-calendar", nil) }
        for connector in ConnectorRegistry.detectedForCurrentBackend() {
            add(connector.slug, connector.displayName)
        }
        return services
    }

    /// Route one command. Never throws and never stalls the run: ANY failure — a router error,
    /// a timeout, an unparseable or unlisted answer — is `.computer`. Duration is always
    /// measured and logged; the command text itself is never logged in Release.
    static func route(_ command: String) async -> Route {
        guard isActive else {
            Log("router: skipped (no connectors)")
            return .computer
        }
        let services = routableServices()
        let t0 = Date()
        var inv = CodexCLI.Invocation(prompt: prompt(command: command, services: services))
        inv.model = .gpt56luna          // → haiku on the Claude tier map
        inv.effort = .low
        inv.sandbox = .readOnly
        inv.webSearch = false
        inv.includeUserConfig = false   // hermetic: the service list is IN the prompt — no
                                        // connector schemas need to load, which keeps it fast
        inv.timeout = 30
        inv.feature = "router"
        inv.outputSchema = schema
        do {
            let env = try await CodexTrigger.$current.withValue(.sidekick) {
                try await FrontierRun.run(inv)
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            struct Reply: Codable { let route: String; let target: String? }
            guard let data = env.jsonResult.data(using: .utf8),
                  let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  reply.route == "connector",
                  let slug = reply.target,
                  let hit = services.first(where: { $0.slug == slug }) else {
                Log("router: computer in \(ms)ms")
                return .computer
            }
            Log("router: connector slug=\(slug) in \(ms)ms")
            return .connector(slug: slug, name: hit.name)
        } catch {
            if !Task.isCancelled {
                Log("router: computer (fail-closed — \(ErrorLabel(error))) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            return .computer
        }
    }

    // MARK: Telemetry (called by CommandRunModel once the run's outcome is known)

    /// One row per routed submission: the decision, the curated slug or "other", the router's
    /// decision time, and whether a routed connector leg fell back to computer use. Never the
    /// command text. The fallback is also the one defect-shaped router signal, so it lands in
    /// Sentry too (structure only; the underlying error already reported through the spine).
    static func recordOutcome(route: String, slug: String?, ms: Int, fellBack: Bool) {
        let target = slug.map(ConnectorRegistry.telemetrySlug) ?? ""
        Analytics.signal("Connector.routed", parameters: [
            "route": route, "target": target, "ms": String(ms), "fallback": String(fellBack)])
        if fellBack {
            CrashReporting.captureEvent("mcp.route.fallback", level: .warning,
                                        tags: ["slug": target],
                                        fingerprint: ["mcp", "route", "fallback"])
        }
    }

    // MARK: The prompt (tune ONLY against the lab's routereval)

    private static func prompt(command: String, services: [Service]) -> String {
        let list = services.map {
            $0.description.isEmpty ? "- \($0.slug): \($0.name)"
                                   : "- \($0.slug): \($0.name) (\($0.description))"
        }.joined(separator: "\n")
        return """
        You are a router inside Sentient OS. Decide HOW one user command should be
        executed. Do not execute anything.

        THE COMMAND (spoken or typed by the user just now):
        \(command)

        THE TWO ROUTES:
        - "connector": the ENTIRE task can be completed with one connected service's
          tools alone (below), with no need to see the screen or touch any app window.
        - "computer": any part of the task needs the screen, an app, or a website.
          Connector tools remain available inside this route too, so a wrong "computer"
          pick costs nothing.

        CONNECTED SERVICES:
        \(list)

        RULES:
        - When in doubt, choose "computer".
        - "connector" is right ONLY when EVERY step of the command fits that ONE
          service's tools. If any step needs a second service (listed or not), a
          device action (like printing), or anything on screen, choose "computer".
          Example: "find the invoice email and save it to my notes" touches email
          AND notes, so it is "computer".
        - A general question that no listed service's data would answer is "computer".
        - The command may point at the screen ("this", "reply to this"). Screenshots
          ride both routes, so that alone never forces "computer".
        - Never output a slug that is not listed above.

        Reply with JSON only: {"route":"computer","target":""} or {"route":"connector","target":"<slug>"}
        """
    }

    /// Both keys required (the judge's strict-schema convention — `--output-schema` is
    /// server-enforced on codex); `target` is "" on the computer route. The decode above
    /// stays tolerant either way.
    private static let schema = """
    {"type":"object","additionalProperties":false,"required":["route","target"],"properties":{\
    "route":{"type":"string","enum":["computer","connector"]},"target":{"type":"string"}}}
    """
}
