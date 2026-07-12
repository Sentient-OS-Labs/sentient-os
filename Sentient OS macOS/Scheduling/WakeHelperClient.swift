//
//  WakeHelperClient.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  App-side client for the root wake helper. Registers the LaunchDaemon via SMAppService (a
//  one-time user approval in System Settings > Login Items), then drives the four XPC ops. Every
//  call is async and fail-safe — if the helper isn't reachable, calls return false rather than throw.
//

import Foundation
import ServiceManagement

/// Runs a `(Bool) -> Void` exactly once, from whichever of reply/error/timeout wins. Thread-safe.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let body: (Bool) -> Void
    init(_ body: @escaping (Bool) -> Void) { self.body = body }
    func fire(_ value: Bool) {
        lock.lock(); let go = !done; done = true; lock.unlock()
        if go { body(value) }
    }
}

@MainActor
final class WakeHelperClient {
    static let shared = WakeHelperClient()
    private var connection: NSXPCConnection?

    /// Register the daemon. The first call surfaces a System Settings approval prompt.
    @discardableResult
    func register() -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: WakeHelperConfig.daemonPlistName)
        do { try service.register() } catch { Log("WakeHelper register error: \(error)") }
        Log("WakeHelper status after register: \(service.status.rawValue)")
        return service.status
    }

    func unregister() async {
        let service = SMAppService.daemon(plistName: WakeHelperConfig.daemonPlistName)
        try? await service.unregister()
    }

    /// Live registration status of the root daemon (`.enabled` = approved & ready · `.requiresApproval`
    /// = registered, waiting for the user in System Settings · `.notRegistered` = never registered ·
    /// `.notFound` = the bundled plist is missing / the build isn't signed for it). Read on every check
    /// so a mid-session approval/revoke in System Settings is seen immediately.
    var status: SMAppService.Status { SMAppService.daemon(plistName: WakeHelperConfig.daemonPlistName).status }

    /// True once the user has approved the daemon and it's ready to accept XPC.
    var isReady: Bool { status == .enabled }

    /// Open System Settings > General > Login Items, where the user approves the daemon. Called by the
    /// setup UX when `register()` returns `.requiresApproval`.
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Liveness — can the daemon actually be reached over XPC right now? This catches what file
    /// checks can't: the App Background Activity toggle in System Settings boots a disabled
    /// daemon OUT of launchd while leaving its plist on disk, so every disk read stays green on a
    /// dead helper (field-found 2026-07-11; `launchctl print system/…` can't tell either — it
    /// answers "could not find service" for everything unprivileged). One probe covers BOTH
    /// install paths (the production plist and the dev cockpit's SMAppService daemon share the
    /// mach service). Probes with `heartbeat`, the one op harmless in every state: mid-run it's
    /// exactly what the app already sends every 60s; idle it arms a deadman whose firing is a
    /// no-op (disablesleep is already 0). A booted-out service invalidates immediately, so the
    /// false case answers in milliseconds. Quiet on purpose: a miss here is an EXPECTED state
    /// (not installed / toggled off), not an error worth a scary log line — real ops keep theirs.
    func isReachable() async -> Bool { await call(quiet: true) { $0.heartbeat(withReply: $1) } }

    /// The user-facing daemon verdict, shared by Settings → Health and onboarding's permissions
    /// step. ready = answers over XPC · disabled = unreachable with the files all correct (the
    /// background toggle is off — launchd honors it over any bootstrap, so only the user flipping
    /// it back on helps) · notSetUp = unreachable with a stale or missing plist (the installer
    /// fixes it).
    enum DaemonHealth { case ready, disabled, notSetUp }

    func healthProbe() async -> DaemonHealth {
        if await isReachable() { return .ready }
        if WakeHelperInstaller.isInstalledAndCurrent() || isReady { return .disabled }
        return .notSetUp
    }

    // MARK: - The four ops

    func beginAwake(timeout: Int = 7200) async -> Bool { await call { $0.beginAwake(timeoutSeconds: timeout, withReply: $1) } }
    func heartbeat() async -> Bool { await call { $0.heartbeat(withReply: $1) } }
    func endAwake() async -> Bool { await call { $0.endAwake(withReply: $1) } }
    func armWake(at date: Date) async -> Bool { await call { $0.armWake(atEpoch: date.timeIntervalSince1970, withReply: $1) } }
    func cancelWake() async -> Bool { await call { $0.cancelWake(withReply: $1) } }
    func cancelAllWakes() async -> Bool { await call { $0.cancelAllWakes(withReply: $1) } }

    // MARK: - XPC plumbing

    private func conn() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: WakeHelperConfig.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: WakeHelperProtocol.self)
        c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        c.resume()
        connection = c
        return c
    }

    /// Every call is guarded three ways so it can NEVER hang at 3am: the reply block, the XPC
    /// error handler (fires if the helper is unreachable), and a 30s timeout — all resume-once.
    /// `quiet` softens the error line for probes, where a miss is an expected state, not a fault.
    private func call(quiet: Bool = false,
                      _ body: @escaping (WakeHelperProtocol, @escaping (Bool) -> Void) -> Void) async -> Bool {
        let connection = conn()
        return await withCheckedContinuation { cont in
            let once = Once { cont.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { once.fire(false) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in
                if quiet { Log("WakeHelper probe: no daemon answering") }
                else { Log("WakeHelper XPC error: \(err)") }
                once.fire(false)
            }) as? WakeHelperProtocol else { once.fire(false); return }
            body(proxy) { ok in once.fire(ok) }
        }
    }
}
