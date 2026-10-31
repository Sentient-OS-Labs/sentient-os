#if DEBUG
// Renders real hosted/direct source controls with process-isolated synthetic preferences.
// run captures owned windows and checks route repair visibility without invoking sign-in or reads.
// Doc: ../Views/Settings/Documentation - Settings.md
import AppKit
import SwiftUI

@MainActor enum ConnectorSetupLab {
    static func run(root: URL) async throws -> [String: Bool] {
        typealias Failure = SidekickPolishLab.Failure
        let env = ProcessInfo.processInfo.environment
        guard env["SENTIENT_SELFTEST"] == "sidekickapp", env["LAB_SIDEKICK_STAGE"] == "ui-connector-setup",
              env["LAB_SIDEKICK_ROOT"] == root.standardizedFileURL.path,
              root.standardizedFileURL == root.resolvingSymlinksInPath(),
              UserDefaults.standard.string(forKey: "lab.fixture.nonce") != nil else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            throw Failure.screenLocked
        }
        // Claude census storage is local fixture metadata, independent of the real Codex account.
        UserDefaults.standard.set(ModelBackend.claude.rawValue, forKey: ModelBackend.key)
        let records = ["granola", "notion"].map { slug in
            ConnectorCensus.DetectedConnector(slug: slug, displayName: slug.capitalized, origin: .claude,
                serverURL: "https://fixture.invalid/" + slug, catalogID: nil, iconPath: nil,
                healthy: false, lastSeen: .distantPast, readinessVerified: false)
        }
        ConnectorCensus.persist(records, for: .claude)
        for record in records { ConnectorRegistry.setKBEnabled(record.slug, true) }
        let catalog = ConnectorSource.catalog(with: records)
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        let directory = root.appendingPathComponent("connector-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: AnyView(Color.black))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connector setup · isolated fixture"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        var phase = "catalog", complete = false
        defer {
            let report: [String: Any] = ["schema": 1, "completed": complete, "phase": phase,
                "checks": checks, "captures": captures, "provider_calls": 0, "oauth_actions": 0,
                "capture_scope": "current_process_windows_only"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("connector-setup-manifest.json"), options: .atomic)
            }
        }
        func render(_ view: AnyView, name: String) async throws -> [SidekickPolishLab.Element] {
            phase = name
            host.rootView = AnyView(view.frame(width: 640, height: 760).background(Theme.bg)
                .environment(\.accessibilityEnabled, true).preferredColorScheme(.dark))
            try await SidekickPolishLab.settle(500)
            _ = await SidekickPolishLab.activateOwnAccessibility()
            try await SidekickPolishLab.settle(250)
            let elements = SidekickPolishLab.elements(host, maximumDepth: 80)
            var capture = try await SidekickPolishLab.capture(host, name: name, directory: directory)
            capture["file"] = "connector-snapshots/" + name + ".png"
            captures.append(capture)
            checks[name + "_window_bounds"] = window.screen?.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame) == true
            return elements
        }
        let catalogView = AnyView(ChipFlow {
            ForEach(catalog) { source in ConnectorPill(source: source, locked: false, action: {}) }
        }.padding(24).frame(width: 600))
        _ = try await render(catalogView, name: "01-hosted-and-direct-catalog")
        for (index, slug) in ["granola", "notion"].enumerated() {
            let choices = catalog.filter { $0.serviceSlug == slug }
            guard let hosted = choices.first(where: { $0.connector?.origin == .claude }),
                  let direct = choices.first(where: { $0.connector == nil }) else { throw Failure.unavailable }
            checks[slug + "_both_routes_visible"] = choices.count == 2 && hosted.usesHostedConnection && !direct.usesHostedConnection
            let hostedName = "\(index * 2 + 2)-\(slug)-hosted-repair"
            let elements = try await render(AnyView(ConnectorConnectSheet(source: hosted, connectors: .constant(records))), name: hostedName)
            let repair = elements.first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Connect to Sentient" }
            checks[slug + "_repair_is_visible"] = repair != nil
            checks[slug + "_repair_is_enabled"] = repair?.enabled == true
            if let repair {
                checks[slug + "_repair_fits"] = window.convertToScreen(host.bounds).insetBy(dx: -1, dy: -1).contains(repair.frame)
            }
            let directElements = try await render(AnyView(ConnectorConnectSheet(source: direct, connectors: .constant(records))),
                                                  name: "\(index * 2 + 3)-\(slug)-direct-setup")
            checks[slug + "_direct_does_not_bind_hosted"] = directElements.contains {
                $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Connect \(slug.capitalized)"
            } && !directElements.contains { $0.label == "Open connector settings" }
            checks[slug + "_choice_preserved"] = ConnectorRegistry.isKBEnabled(slug)
        }
        checks["no_direct_account_created"] = DirectMCPStore.connections().isEmpty
        checks["five_owned_captures"] = captures.count == 5
        complete = true; phase = "complete"
        return checks
    }
}
#endif
