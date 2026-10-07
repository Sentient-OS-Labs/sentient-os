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
dedicated_done = declaration(dedicated, "private func done()")
generic_done = declaration(generic, "private func done()")
dedicated_open = declaration(dedicated, "private func openConnectorPage()")
generic_open = declaration(generic, "private func openConnectorPage()")
for name, source in (("dedicated", dedicated), ("generic", generic)):
    assert "checkingEmail" not in source, name
    assert "MailAccountCollection.collect" not in source, name
    assert '"Open connector settings"' in source, name
for action in (dedicated_done, generic_done):
    assert "Task" not in action and "await " not in action
    assert "HostedConnectorSetup.confirm" in action
for action in (dedicated_open, generic_open):
    assert "Task" not in action and "await " not in action
    assert "HostedConnectorSetup.settingsOpened" in action
assert "if selected {" in dedicated
assert "if hostedConnected {" in generic
assert "if usesDirect {" in generic
assert ".onDisappear(perform: cancelOperation)" in generic

source = r'''
import Foundation

@MainActor enum ModelBackend: String { case chatgpt, claude, custom; static var current: Self = .chatgpt }
@MainActor final class MemoryDefaults {
    var values: [String: Bool] = [:]
    func object(forKey key: String) -> Any? { values[key] }
}
@MainActor enum UserDefaults { static let standard = MemoryDefaults() }
@MainActor enum ConnectorRegistry {
    static var eligible = true
    static func kbEligible(_ slug: String, backend: ModelBackend = .current) -> Bool { eligible }
    static func kbKey(_ slug: String) -> String { "mcp." + slug + ".kb" }
    static func setKBEnabled(_ slug: String, _ enabled: Bool) { UserDefaults.standard.values[kbKey(slug)] = enabled }
}
@MainActor enum ConnectorCensus {
    struct DetectedConnector {
        enum Origin {
            case chatgpt, claude
            init?(backend: ModelBackend) {
                switch backend { case .chatgpt: self = .chatgpt; case .claude: self = .claude; case .custom: return nil }
            }
        }
        let slug: String
    }
    static var records: [DetectedConnector] = []
    static func cached(for origin: DetectedConnector.Origin) -> [DetectedConnector] { records }
}
@MainActor enum HostedConnectorSetup {
    static var calls: [(String, ModelBackend, Bool)] = []
    static var settingsCalls: [(String, ModelBackend)] = []
    static var accepted = true
    static var onConfirm: () -> Void = {}
    static func confirm(slug: String, backend: ModelBackend, reconnected: Bool) -> Bool {
        calls.append((slug, backend, reconnected))
        guard accepted, backend == ModelBackend.current, backend != .custom else { return false }
        onConfirm()
        return true
    }
    static func settingsOpened(slug: String, backend: ModelBackend) {
        settingsCalls.append((slug, backend))
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
        var connectorURL: URL { ConnectorLinks.page(for: slug) }
    }
    let service: Service
    var backend: ModelBackend = .chatgpt
    var connected = false
    var openedConnectorPage = false
    var dismissals = 0
    init(_ slug: String) { service = Service(slug: slug) }
    func dismiss() { dismissals += 1 }
    func tapDone() { done() }
    func openSettings() { openConnectorPage() }
__DEDICATED__
}
@MainActor final class GenericFixture {
    struct Source { let serviceSlug: String }
    let source: Source
    var hostedBackend: ModelBackend = .chatgpt
    var openedConnectorPage = false
    var hostedSelected = false
    var usesDirect = false
    var busy = false
    var dismissals = 0
    var selectionSlug: String { source.serviceSlug }
    var connected: Bool { hostedConnected }
    init(_ slug: String) { source = Source(serviceSlug: slug) }
    func dismiss() { dismissals += 1 }
    func tapDone() { done() }
    func stopReading() { stopHostedReading() }
    func openSettings() { openConnectorPage() }
__GENERIC__
}

@main struct SheetTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); checks += 1
    }
    @MainActor static func reset() {
        HostedConnectorSetup.calls = []; HostedConnectorSetup.accepted = true
        HostedConnectorSetup.settingsCalls = []
        HostedConnectorSetup.onConfirm = {}; Analytics.signals = 0
        NSWorkspace.shared.succeeds = true; NSWorkspace.shared.urls = []
        ModelBackend.current = .chatgpt; ConnectorRegistry.eligible = true
        ConnectorCensus.records = []; UserDefaults.standard.values = [:]
    }
    @MainActor static func main() {
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
        for (captured, current) in [(ModelBackend.chatgpt, ModelBackend.claude), (.claude, .chatgpt), (.custom, .custom)] {
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
        for slug in ["gmail", "google-calendar"] {
            reset()
            let sheet = DedicatedFixture(slug)
            HostedConnectorSetup.onConfirm = { sheet.connected = true }
            sheet.openedConnectorPage = true
            sheet.tapDone()
            check(sheet.connected && sheet.dismissals == 1, "Dedicated Done did not confirm/dismiss synchronously")
            check(HostedConnectorSetup.calls.first?.0 == slug && HostedConnectorSetup.calls.first?.2 == true, "Dedicated confirmation lost its source/reconnect")
            check(Analytics.signals == 1, "First confirmation telemetry missing")
            sheet.tapDone()
            check(Analytics.signals == 1, "Existing connection counted again")
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
            check(sheet.hostedSelected && sheet.dismissals == 1, "Hosted Done did not immediately delegate and dismiss")
            check(HostedConnectorSetup.calls.first?.0 == slug && HostedConnectorSetup.calls.first?.2 == true, "Hosted confirmation lost its source/reconnect")
            ConnectorCensus.records = []
            check(sheet.connected, "Missing cache undid explicit source selection")
            sheet.stopReading()
            check(!sheet.hostedSelected && HostedConnectorSetup.calls.count == 1, "Stop reading re-confirmed the source")
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
        check(UserDefaults.standard.values["mcp.direct-fixture.kb"] == true, "Direct initial selection changed")
        check(HostedConnectorSetup.calls.isEmpty, "Direct OAuth was routed through hosted trust")
        UserDefaults.standard.values["mcp.direct-fixture.kb"] = false
        direct.tapDone()
        check(UserDefaults.standard.values["mcp.direct-fixture.kb"] == false, "Direct Settings opt-out was overwritten")
        print("PASS: \(checks) hosted sheet confirmation, state, provider and direct-route checks")
    }
}
'''.replace("__DEDICATED__", dedicated_done + "\n" + dedicated_open).replace("__GENERIC__", "\n".join([
    generic_done,
    generic_open,
    declaration(generic, "private func stopHostedReading()"),
    declaration(generic, "private var hostedCanRead: Bool"),
    declaration(generic, "private var hostedConnected: Bool"),
]))

with tempfile.TemporaryDirectory(prefix="sentient-hosted-sheet-tests-") as directory:
    directory = Path(directory)
    path = directory / "SheetTests.swift"
    path.write_text(source)
    executable = directory / "tests"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
