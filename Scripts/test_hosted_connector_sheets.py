#!/usr/bin/env python3
"""Check exact hosted-sheet actions with in-memory preferences and confirmation spies.

This tests the view/controller boundary. HostedConnectorSetup's real persistence and
background jobs have separate tests; this harness cannot launch CLIs or contact users.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    index = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[start:index]


dedicated = (ROOT / "Views/CloudConnectSheet.swift").read_text()
generic = (ROOT / "Views/Settings/ConnectorConnectSheet.swift").read_text()
pills = (ROOT / "Views/Settings/ConnectorsSection.swift").read_text()
dedicated_done = declaration(dedicated, "private func done()")
generic_done = declaration(generic, "private func done()")
dedicated_open = declaration(dedicated, "private func openConnectorPage()")
generic_open = declaration(generic, "private func openConnectorPage()")
for name, source in (("dedicated", dedicated), ("generic", generic)):
    assert "checkingEmail" not in source, name
    assert "MailAccountCollection.collect" not in source, name
    assert '"Open connector settings"' in source, name
    assert "@AppStorage private var pageProgress: HostedConnectorSetup.PageProgress" in source, name
    assert "HostedConnectorSetup.pageProgressKey(" in source, name
    assert "openedConnectorPage || pageProgress != .unopened" in source, name
    assert "if hasOpenedConnectorPage {" in source, name
for action in (dedicated_done, generic_done):
    assert "Task" not in action and "await " not in action
    assert "HostedConnectorSetup.confirm" in action
    assert "verifyAndConfirm" not in action
for action in (dedicated_open, generic_open):
    assert "Task" not in action and "await " not in action
    assert "HostedConnectorSetup.settingsOpened" in action
assert "if selected {" in dedicated
assert "if hostedConnected {" in generic
assert "if usesDirect {" in generic
assert ".onDisappear(perform: cancelOperation)" in generic

source = r'''
import Foundation

@MainActor enum ModelBackend: String {
    case chatgpt, claude, custom, sentient
    static var current: Self = .chatgpt
    var hasSubscriptionConnectors: Bool { self == .chatgpt || self == .claude }
}
@MainActor enum CodexAuth { static let connectorLockedTip = "Locked" }
@MainActor enum HostedConnectorStore { static let services: Set<String> = ["gmail", "google-calendar", "google-drive", "slack", "outlook-mail", "outlook-calendar"] }
@MainActor final class MemoryDefaults {
    var values: [String: Bool] = [:]
    func object(forKey key: String) -> Any? { values[key] }
}
@MainActor enum UserDefaults { static let standard = MemoryDefaults() }
@MainActor enum ConnectorRegistry {
    static var eligible = true
    static var directRequired = false
    static var revisions: [String: String] = [:]
    static var includedUnavailableDirect = false
    static func kbEligible(_ slug: String, backend: ModelBackend = .current) -> Bool { eligible }
    static func requiresDirectKnowledgeConnection(_ slug: String, backend: ModelBackend = .current) -> Bool { directRequired }
    static func kbKey(_ slug: String) -> String { "mcp." + slug + ".kb" }
    static func setKBEnabled(_ slug: String, _ enabled: Bool) {
        UserDefaults.standard.values[kbKey(slug)] = enabled
        _ = advanceKnowledgeSelectionRevision(slug)
    }
    static func advanceKnowledgeSelectionRevision(_ slug: String) -> String {
        revisions[slug] = UUID().uuidString
        return revisions[slug]!
    }
    static func knowledgeSelectionRevision(_ slug: String) -> String? { revisions[slug] }
    static func detectedForCurrentBackend(includeUnavailableDirect: Bool = false) -> [ConnectorCensus.DetectedConnector] {
        includedUnavailableDirect = includeUnavailableDirect
        return ConnectorCensus.records
    }
}
@MainActor enum ConnectorCensus {
    struct DetectedConnector {
        enum Origin {
            case chatgpt, claude
            init?(backend: ModelBackend) {
                switch backend { case .chatgpt: self = .chatgpt; case .claude: self = .claude; case .custom, .sentient: return nil }
            }
        }
        let slug: String
        var canAttempt = true
        var healthy = true
    }
    static var records: [DetectedConnector] = []
    static func cached(for origin: DetectedConnector.Origin) -> [DetectedConnector] { records }
}
@MainActor enum HostedConnectorSetup {
    static var calls: [(String, ModelBackend, Bool)] = []
    static var settingsCalls: [(String, ModelBackend)] = []
    static var accepted = true
    static var onConfirm: () -> Void = {}
    static var onStop: () -> Void = {}
    static var stopCalls: [(String, ModelBackend)] = []
    static func confirm(slug: String, backend: ModelBackend, reconnected: Bool) -> Bool {
        calls.append((slug, backend, reconnected))
        guard accepted, backend == ModelBackend.current, backend != .custom else { return false }
        onConfirm()
        return true
    }
    static func settingsOpened(slug: String, backend: ModelBackend) {
        settingsCalls.append((slug, backend))
    }
    static func stopReading(slug: String, backend: ModelBackend) {
        stopCalls.append((slug, backend)); onStop()
    }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var succeeds = true
    var urls: [URL] = []
    func open(_ url: URL) -> Bool { urls.append(url); return succeeds }
}
@MainActor enum ConnectorLinks {
    static func page(for slug: String, backend: ModelBackend = .current) -> URL {
        URL(string: "https://" + (backend == .claude ? "claude.example" : "chatgpt.example") + "/" + slug)!
    }
}
@MainActor enum Analytics {
    static var signals = 0
    static func signal(_ name: String, parameters: [String: String]) { signals += 1 }
}
@MainActor final class DedicatedFixture {
    @MainActor struct Service {
        let slug: String
        var analyticsName: String { slug }
        var title: String { slug }
        var connectorURL: URL { ConnectorLinks.page(for: slug) }
    }
    let service: Service
    var backend: ModelBackend = .chatgpt
    var connected = false
    var selected = false
    var openedConnectorPage = false
    var dismissals = 0
    init(_ slug: String) { service = Service(slug: slug) }
    func dismiss() { dismissals += 1 }
    func tapDone() { done() }
    func openSettings() { openConnectorPage() }
    func tapStopReading() { stopReading() }
__DEDICATED__
}
@MainActor final class GenericFixture {
    struct Source { let serviceSlug: String; var directProvider: Bool? = true }
    struct Direct { let slug: String }
    let source: Source
    var hostedBackend: ModelBackend = .chatgpt
    var openedConnectorPage = false
    var hostedSelected = false
    var usesDirect = false
    var direct: Direct?
    var repairingHostedKnowledge = false
    var repairSelection: Bool?
    var repairRevision: String?
    var connectionCompleted = false
    var boundConnectorID: String?
    var connectCalls = 0
    var busy = false
    var operation: Task<Void, Never>?
    var connectors: [ConnectorCensus.DetectedConnector] = []
    var name: String { source.serviceSlug }
    var dismissals = 0
    var selectionSlug: String { source.serviceSlug }
    var connected: Bool { hostedConnected }
    init(_ slug: String) { source = Source(serviceSlug: slug) }
    func dismiss() { dismissals += 1 }
    func tapDone() { done() }
    func stopReading() { stopHostedReading() }
    func openSettings() { openConnectorPage() }
    func repair() { repairHostedKnowledge() }
    func finishDirect(_ slug: String) { finishKnowledgeRepair(with: slug) }
    func connect() { connectCalls += 1 }
__GENERIC__
}
@MainActor struct PillFixture {
    struct Source {
        let serviceSlug: String
        let connector: ConnectorCensus.DetectedConnector?
        var usesHostedConnection = true
        var isDirectSetup = false
        var showsInKnowledgeSources = true
    }
    var source: Source
    var knowledgeEnabled = true
    var locked = false
    var isSelected: Bool { selected }
    var detailText: String? { detail }
    var statusText: String { status }
__PILL__
}

@main struct SheetTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); checks += 1
    }
    @MainActor static func reset() {
        HostedConnectorSetup.calls = []; HostedConnectorSetup.accepted = true
        HostedConnectorSetup.settingsCalls = []
        HostedConnectorSetup.stopCalls = []; HostedConnectorSetup.onStop = {}
        HostedConnectorSetup.onConfirm = {}; Analytics.signals = 0
        NSWorkspace.shared.succeeds = true; NSWorkspace.shared.urls = []
        ModelBackend.current = .chatgpt; ConnectorRegistry.eligible = true
        ConnectorRegistry.directRequired = false
        ConnectorRegistry.revisions = [:]
        ConnectorRegistry.includedUnavailableDirect = false
        ConnectorCensus.records = []; UserDefaults.standard.values = [:]
    }
    @MainActor static func main() async {
        for backend in [ModelBackend.chatgpt, .claude] {
            for opens in [true, false] {
                reset(); ModelBackend.current = backend; NSWorkspace.shared.succeeds = opens
                let sheet = DedicatedFixture("gmail"); sheet.backend = backend
                sheet.openSettings()
                check(NSWorkspace.shared.urls == [ConnectorLinks.page(for: "gmail", backend: backend)], "Dedicated browser got the wrong provider/source")
                check(sheet.openedConnectorPage == opens, "Dedicated browser result did not control reconnect state")
                check(HostedConnectorSetup.settingsCalls.count == (opens ? 1 : 0), "Dedicated failed browser open invalidated checkpoints")
                if opens {
                    check(HostedConnectorSetup.settingsCalls.first?.0 == "gmail" && HostedConnectorSetup.settingsCalls.first?.1 == backend, "Dedicated settings callback lost its source/provider")
                }
                check(HostedConnectorSetup.calls.isEmpty && sheet.dismissals == 0, "Opening dedicated settings confirmed or dismissed the source")

                reset(); ModelBackend.current = backend; NSWorkspace.shared.succeeds = opens
                let generic = GenericFixture("outlook-mail"); generic.hostedBackend = backend
                generic.openSettings()
                check(NSWorkspace.shared.urls == [ConnectorLinks.page(for: "outlook-mail", backend: backend)], "Generic browser got the wrong provider/source")
                check(generic.openedConnectorPage == opens, "Generic browser result did not control reconnect state")
                check(HostedConnectorSetup.settingsCalls.count == (opens ? 1 : 0), "Generic failed browser open invalidated checkpoints")
                if opens {
                    check(HostedConnectorSetup.settingsCalls.first?.0 == "outlook-mail" && HostedConnectorSetup.settingsCalls.first?.1 == backend, "Generic settings callback lost its source/provider")
                }
                check(HostedConnectorSetup.calls.isEmpty && generic.dismissals == 0, "Opening generic settings confirmed or dismissed the source")
            }
        }
        for (captured, current) in [(ModelBackend.chatgpt, ModelBackend.claude), (.claude, .chatgpt), (.custom, .custom), (.sentient, .sentient)] {
            reset(); ModelBackend.current = current
            let sheet = DedicatedFixture("gmail"); sheet.backend = captured
            sheet.openSettings()
            check(NSWorkspace.shared.urls.isEmpty && HostedConnectorSetup.settingsCalls.isEmpty, "Stale/custom dedicated sheet opened settings")
            check(!sheet.openedConnectorPage && sheet.dismissals == 1, "Stale/custom dedicated sheet remained active")
            let generic = GenericFixture("slack"); generic.hostedBackend = captured
            generic.openSettings()
            check(NSWorkspace.shared.urls.isEmpty && HostedConnectorSetup.settingsCalls.isEmpty, "Stale/custom generic sheet opened settings")
            check(!generic.openedConnectorPage && generic.dismissals == 1, "Stale/custom generic sheet remained active")
        }
        reset(); ModelBackend.current = .sentient
        let hostedDedicated = DedicatedFixture("gmail"); hostedDedicated.backend = .sentient
        hostedDedicated.tapDone()
        let hostedGeneric = GenericFixture("slack"); hostedGeneric.hostedBackend = .sentient
        hostedGeneric.tapDone()
        check(HostedConnectorSetup.calls.isEmpty && NSWorkspace.shared.urls.isEmpty,
              "Sentient funding claimed access to subscription connectors")
        for slug in ["gmail", "google-calendar"] {
            reset()
            let sheet = DedicatedFixture(slug)
            HostedConnectorSetup.onConfirm = { sheet.connected = true }
            sheet.openedConnectorPage = true
            sheet.tapDone()
            check(sheet.connected && sheet.dismissals == 1, "Dedicated Done did not immediately confirm/dismiss")
            check(HostedConnectorSetup.calls.first?.0 == slug && HostedConnectorSetup.calls.first?.2 == true, "Dedicated confirmation lost its source/reconnect")
            check(Analytics.signals == 1, "First confirmation telemetry missing")
            sheet.tapDone()
            check(Analytics.signals == 1, "Existing connection counted again")
            sheet.selected = true
            HostedConnectorSetup.onStop = { sheet.selected = false }
            sheet.tapStopReading()
            check(!sheet.selected && HostedConnectorSetup.stopCalls.first?.0 == slug,
                  "Dedicated Stop reading bypassed shared consent cancellation")
            sheet.selected = true; ModelBackend.current = .claude
            sheet.tapStopReading()
            check(sheet.selected && HostedConnectorSetup.stopCalls.count == 1,
                  "Stale dedicated sheet revoked the current provider selection")
            reset()
            let stale = DedicatedFixture(slug); ModelBackend.current = .claude
            stale.tapDone()
            check(!stale.connected && stale.dismissals == 1 && Analytics.signals == 0, "Stale provider confirmed or signaled")
        }
        for slug in ["google-drive", "outlook-mail", "outlook-calendar", "slack"] {
            reset()
            let sheet = GenericFixture(slug)
            HostedConnectorSetup.onConfirm = { sheet.hostedSelected = true }
            check(!sheet.connected, "Unselected source appeared connected")
            ConnectorCensus.records = [.init(slug: slug)]
            check(!sheet.connected, "Cached discovery overrode false reading preference")
            sheet.openedConnectorPage = true
            sheet.tapDone()
            check(sheet.hostedSelected && sheet.dismissals == 1, "Hosted Done did not immediately confirm/dismiss")
            check(ConnectorRegistry.includedUnavailableDirect,
                  "Hosted Done hid unrelated direct accounts that still need recovery")
            check(HostedConnectorSetup.calls.first?.0 == slug && HostedConnectorSetup.calls.first?.2 == true, "Hosted confirmation lost its source/reconnect")
            ConnectorCensus.records = []
            check(sheet.connected, "Missing cache undid explicit source selection")
            HostedConnectorSetup.onStop = { sheet.hostedSelected = false }
            sheet.stopReading()
            check(!sheet.hostedSelected && HostedConnectorSetup.calls.count == 1
                  && HostedConnectorSetup.stopCalls.first?.0 == slug,
                  "Hosted Stop reading bypassed shared consent cancellation")
            sheet.tapDone()
            check(sheet.hostedSelected, "Done did not delegate re-enabling a stored false selection")
            ModelBackend.current = .claude
            sheet.stopReading()
            check(sheet.hostedSelected, "Stale sheet cleared the new provider's selection")
        }
        reset()
        let stale = GenericFixture("slack"); ModelBackend.current = .claude
        stale.tapDone()
        check(!stale.hostedSelected && stale.dismissals == 1, "Stale generic sheet confirmed")
        reset()
        ConnectorRegistry.eligible = false
        let taskOnly = GenericFixture("task-only")
        check(!taskOnly.connected, "Undeclared task-only source appeared connected")
        ConnectorCensus.records = [.init(slug: "task-only")]
        check(taskOnly.connected && !taskOnly.hostedSelected, "Task-only declaration invented reading state")
        reset()
        let direct = GenericFixture("direct-fixture"); direct.usesDirect = true
        direct.busy = true; direct.tapDone()
        check(direct.dismissals == 0 && HostedConnectorSetup.calls.isEmpty, "Direct OAuth lost its busy guard")
        direct.busy = false; direct.tapDone()
        check(UserDefaults.standard.values["mcp.direct-fixture.kb"] == nil,
              "Done without an OAuth account invented a knowledge source")
        direct.direct = .init(slug: "direct-fixture"); direct.tapDone()
        check(UserDefaults.standard.values["mcp.direct-fixture.kb"] == nil,
              "Direct Done enabled a visible default-off knowledge toggle")
        check(HostedConnectorSetup.calls.isEmpty, "Direct OAuth was routed through hosted trust")
        UserDefaults.standard.values["mcp.direct-fixture.kb"] = true
        direct.tapDone()
        check(UserDefaults.standard.values["mcp.direct-fixture.kb"] == true,
              "Direct Done lost an explicit knowledge opt-in")
        UserDefaults.standard.values["mcp.direct-fixture.kb"] = false
        direct.tapDone()
        check(UserDefaults.standard.values["mcp.direct-fixture.kb"] == false, "Direct Settings opt-out was overwritten")
        reset()
        let repair = GenericFixture("granola"); repair.hostedSelected = true
        UserDefaults.standard.values["mcp.granola.kb"] = true
        repair.repair()
        check(repair.repairingHostedKnowledge && repair.connectCalls == 1 && repair.repairSelection == true,
              "Explicit hosted repair did not start a separate account choice")
        check(UserDefaults.standard.values["mcp.granola.kb"] == true,
              "Starting or canceling repair retired the hosted selection before OAuth success")
        repair.finishDirect("direct-chosen")
        check(UserDefaults.standard.values["mcp.direct-chosen.kb"] == true
              && UserDefaults.standard.values["mcp.granola.kb"] == false,
              "Successful explicit repair did not transfer reading to the chosen account")
        repair.usesDirect = true; repair.direct = .init(slug: "direct-chosen"); repair.tapDone()
        check(UserDefaults.standard.values["mcp.direct-chosen.kb"] == true,
              "Done changed a successful explicit repair selection")
        check(HostedConnectorSetup.calls.isEmpty && ConnectorCensus.records.isEmpty,
              "Repair changed hosted account metadata instead of only reading selection")
        reset()
        let general = GenericFixture("granola"); general.hostedSelected = true
        UserDefaults.standard.values["mcp.granola.kb"] = true
        general.finishDirect("direct-added")
        check(UserDefaults.standard.values["mcp.granola.kb"] == true
              && UserDefaults.standard.values["mcp.direct-added.kb"] == nil,
              "Adding a direct account silently consumed hosted reading consent")
        let stopped = GenericFixture("granola"); stopped.hostedSelected = true; stopped.repair()
        stopped.hostedSelected = false; UserDefaults.standard.values["mcp.granola.kb"] = false
        stopped.finishDirect("direct-late")
        stopped.usesDirect = true; stopped.direct = .init(slug: "direct-late"); stopped.tapDone()
        check(UserDefaults.standard.values["mcp.granola.kb"] == false
              && UserDefaults.standard.values["mcp.direct-late.kb"] == nil,
              "An old repair overwrote a later Stop reading")
        let renewed = GenericFixture("granola"); renewed.hostedSelected = true
        ConnectorRegistry.setKBEnabled("granola", true); renewed.repair()
        ConnectorRegistry.setKBEnabled("granola", false)
        ConnectorRegistry.setKBEnabled("granola", true)
        renewed.finishDirect("direct-obsolete")
        renewed.usesDirect = true; renewed.direct = .init(slug: "direct-obsolete"); renewed.tapDone()
        check(UserDefaults.standard.values["mcp.granola.kb"] == true
              && UserDefaults.standard.values["mcp.direct-obsolete.kb"] == nil,
              "Stop followed by a newer Done was overwritten by an older repair")
        let repeated = GenericFixture("granola"); repeated.hostedSelected = true; repeated.repair()
        ConnectorRegistry.setKBEnabled("granola", true)
        repeated.finishDirect("direct-repeated")
        repeated.usesDirect = true; repeated.direct = .init(slug: "direct-repeated"); repeated.tapDone()
        check(UserDefaults.standard.values["mcp.granola.kb"] == true
              && UserDefaults.standard.values["mcp.direct-repeated.kb"] == nil,
              "Repeated explicit Done did not retire the earlier repair decision")
        let first = GenericFixture("granola"); first.hostedSelected = true; first.repair()
        let latest = GenericFixture("granola"); latest.hostedSelected = true; latest.repair()
        first.finishDirect("direct-earlier"); latest.finishDirect("direct-latest")
        check(UserDefaults.standard.values["mcp.direct-earlier.kb"] == nil
              && UserDefaults.standard.values["mcp.direct-latest.kb"] == true,
              "An earlier OAuth completion replaced the account chosen by a newer repair")
        reset()
        let directOptOut = GenericFixture("granola"); directOptOut.hostedSelected = true; directOptOut.repair()
        ConnectorRegistry.setKBEnabled("direct-opted-out", false)
        directOptOut.finishDirect("direct-opted-out")
        directOptOut.usesDirect = true; directOptOut.direct = .init(slug: "direct-opted-out")
        directOptOut.connectionCompleted = true; directOptOut.tapDone()
        check(UserDefaults.standard.values["mcp.direct-opted-out.kb"] == false,
              "Repair or Done overwrote the chosen direct account's explicit opt-out")
        ConnectorRegistry.setKBEnabled("direct-opted-out", true)
        directOptOut.tapDone()
        check(UserDefaults.standard.values["mcp.direct-opted-out.kb"] == true
              && UserDefaults.standard.values["mcp.granola.kb"] == false,
              "Done did not complete the still-authorized repair after explicit direct opt-in")
        reset()
        var pill = PillFixture(source: .init(serviceSlug: "google-drive", connector: .init(slug: "google-drive")))
        check(pill.isSelected && pill.detailText == nil && pill.statusText == "Selected for analysis and nightly updates.",
              "Explicit Done still appeared to need verification in the source list")
        pill.source = .init(serviceSlug: "google-drive", connector: .init(slug: "google-drive", canAttempt: false))
        check(pill.isSelected && pill.detailText == nil && pill.statusText == "Selected for analysis and nightly updates.",
              "Cached read failure overrode the selected source chip")
        pill.source = .init(serviceSlug: "google-drive", connector: nil)
        check(pill.isSelected && pill.detailText == nil && pill.statusText == "Selected for analysis and nightly updates.",
              "Missing catalog entry overrode the selected source chip")
        pill.source = .init(serviceSlug: "direct-fixture", connector: nil, usesHostedConnection: false)
        check(!pill.isSelected && pill.detailText == "Connection needs attention · Manage"
              && pill.statusText == "Selected, but review this connection before analysis can use it.",
              "Direct catalog-only KB selection appeared available without a stored account")
        pill.source = .init(serviceSlug: "direct-fixture",
                            connector: .init(slug: "direct-fixture", canAttempt: false), usesHostedConnection: false)
        check(!pill.isSelected && pill.detailText == "Connection needs attention · Manage",
              "Stale direct catalog metadata appeared available without a stored account")
        pill.source = .init(serviceSlug: "direct-fixture",
                            connector: .init(slug: "direct-fixture", canAttempt: true, healthy: false),
                            usesHostedConnection: false)
        check(pill.isSelected && pill.detailText == nil && pill.statusText == "Selected for analysis and nightly updates.",
              "Stored direct account's cached failure overrode the selected source chip")
        pill.knowledgeEnabled = false
        check(!pill.isSelected && pill.detailText == nil && !pill.statusText.hasPrefix("Selected"),
              "Unselected source appeared selected or broken")
        pill.locked = true
        check(pill.statusText == CodexAuth.connectorLockedTip && pill.detailText == nil, "Locked connector lost its plan guidance")
        pill.locked = false
        pill.source = .init(serviceSlug: "github", connector: .init(slug: "github"), showsInKnowledgeSources: false)
        check(!pill.isSelected && pill.detailText == "Connected"
              && pill.statusText == "Connected to Sidekick. Open to manage this connection.",
              "Connected Sidekick app looked like an unselected knowledge source")
        print("PASS: \(checks) hosted sheet confirmation, state, provider and direct-route checks")
    }
}
'''.replace("__DEDICATED__", dedicated_done + "\n" + dedicated_open + "\n" +
    declaration(dedicated, "private func stopReading()")).replace("__GENERIC__", "\n".join([
    generic_done,
    generic_open,
    declaration(generic, "private func stopHostedReading()"),
    declaration(generic, "private func repairHostedKnowledge()"),
    declaration(generic, "private func finishKnowledgeRepair(with"),
    declaration(generic, "private var needsDirectKnowledgeConnection: Bool"),
    declaration(generic, "private var hostedCanRead: Bool"),
    declaration(generic, "private var hostedConnected: Bool"),
])).replace("__PILL__", declaration(pills, "private var selected: Bool") + "\n" +
    declaration(pills, "private var detail: String?") + "\n" +
    declaration(pills, "private var status: String"))

with tempfile.TemporaryDirectory(prefix="sentient-hosted-sheet-tests-") as directory:
    directory = Path(directory)
    path = directory / "SheetTests.swift"
    path.write_text(source)
    executable = directory / "tests"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
