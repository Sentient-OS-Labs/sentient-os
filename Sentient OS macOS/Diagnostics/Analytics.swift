//
//  Analytics.swift
//  Sentient OS macOS
//
//  TelemetryDeck integration — the app's privacy-safe PRODUCT analytics (how many people use the app,
//  how far they get in onboarding, which features actually fire). The twin of CrashReporting.swift
//  (Sentry, which is crashes/errors). Two gates:
//    1. RELEASE builds only — a no-op in DEBUG, so a dev's day-to-day Debug runs never pollute the
//       real usage numbers. Verify the pipeline from a Release build (same rule as Sentry).
//    2. A TIERED consent switch — `analyticsEnabled` (default ON), the "Share anonymous analytics"
//       toggle in Settings → System, gates the EXTENDED tier: the rich funnel + health signals
//       (onboarding, processing stats, durations, scheduler internals, mirror, plan gates).
//       The always-on tier (`.core`) keeps sending basic usage counts and a reviewed, generalized
//       workflow phrase after Sidekick attempts, even when the extended switch is off. The
//       Sidekick phrase is the sole free-text exception, through recordTaskSummary only.
//       The SDK boots unconditionally in Release. The disclosure beside the switch (SystemPane)
//       explains which reports remain enabled. Crash reports keep their separate switch
//       (CrashReporting's `diagnosticsEnabled`), so a user can keep crash reports on while opting
//       out (or vice versa).
//  Identity is the same anonymous per-install UUID (`CrashReporting.installID`); TelemetryDeck hashes
//  it again on-device and once more on their server. This permits repeat-event association; it
//  does not sanitize payload text. Ordinary signals carry structure only. Sidekick phrases pass
//  local checks and a separate model review; that review reduces disclosure risk, not a proof of anonymity.
//  `floatValue` is TelemetryDeck's one numeric field — dashboards can SUM it, which is how the
//  worldwide totals work (suggestions generated, agent-seconds worked).
//
//  `countInstallOnce()` predates the tiers and stays deliberately harder-line than core: a single
//  "an install exists" ping, at most once per install, carrying a throwaway random hash that is
//  uncorrelatable to anything (not the install id, not the crash-report id) — the one complete,
//  uniform count across every install ever.
//
//  Key members:
//   - start()                          → boot TelemetryDeck (Release-only, unconditional)
//   - signal(_:parameters:floatValue:tier:) → send one product event (.extended = opt-out gated · .core = always)
//   - countInstallOnce()               → the one-off anonymous install count (Release-only, uncorrelatable)
//   - countUninstall()                 → its farewell twin, fired as the uninstall teardown begins
//   - applyEnabledChange()             → react to a mid-session flip of the extended-tier switch
//
//  Doc: Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md
//

import Foundation
import CryptoKit
import TelemetryDeck

enum Analytics {

    /// The TelemetryDeck App ID — dashboard → Set Up → "Your App ID" (org namespace: ai.sentient-os).
    /// NOT a secret: signals only ever write IN, never read anything out, so it ships in source,
    /// open-source-safe — exactly like the Sentry DSN. ⚠️ Swap the placeholder for the real ID.
    private static let appID = "42A2F097-DBB1-4A63-BE45-0092962F36E6"

    private static var started = false

    /// Process-boot timestamp, stamped by `start()` — lets Home.opened tell a window that opened
    /// with the launch apart from a deliberate later reopen (menu bar / Dock).
    static let bootTime = Date()

    // MARK: - The consent tiers

    /// Which consent a signal rides. `.extended` (the default) is the rich picture, gated by the
    /// "Share extended usage analytics" switch; `.core` is the always-on tier, disclosed beside
    /// the switch. It includes basic usage: how many people use Sentient (the install
    /// ping + SDK sessions), Sidekick fires (`Command.submitted`), proactive cards made AND fired
    /// (`Proactive.prepared` + `Proactive.actionFired`), overnight runs (`Scheduler.overnightCompleted`),
    /// and home opens (`Home.opened`), plus `Sidekick.taskSummary` through its typed sink below.
    /// Durations, funnels, and health ride `.extended`.
    enum Tier { case core, extended }

    private static let analyticsKey = "analyticsEnabled"

    /// The extended-tier switch: default ON. Treats an unset key as ON (a bare `bool(forKey:)`
    /// reads a missing key as false → would wrongly read as opted out).
    nonisolated static var analyticsEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: analyticsKey) == nil { return true }
        return d.bool(forKey: analyticsKey)
    }

    // MARK: - Boot

    /// Boot TelemetryDeck for the GUI app — Release-only, UNCONDITIONAL of the analytics switch
    /// (the switch gates the extended tier per-signal; the SDK must run for the core tier and its
    /// automatic launch/session signals). A deliberate no-op in DEBUG and while the App ID is still
    /// the placeholder. Called from main.swift's `.app` branch (NOT the root wake-helper — the
    /// privileged path sends no analytics). Idempotent.
    static func start() {
        guard !started else { return }
        _ = bootTime   // stamp process boot now, so Home.opened's launch-vs-reopen read is true
        #if DEBUG
        Log("Analytics: DEBUG build — TelemetryDeck disabled (Release-only, like Sentry)")
        #else
        guard !appID.hasPrefix("PASTE_") else {
            Log("Analytics: no App ID set — TelemetryDeck disabled")
            return
        }
        let config = TelemetryDeck.Config(appID: appID)
        config.defaultUser = CrashReporting.installID          // the anonymous per-install id (re-hashed by TD)
        config.defaultParameters = { ["model": ModelLocator.fileName] }  // stamps every signal
        TelemetryDeck.initialize(config: config)
        started = true
        Log("Analytics: TelemetryDeck started (extended signals \(analyticsEnabled ? "on" : "off"))")
        #endif
    }

    // MARK: - Signals

    /// Send one product event. Guard-railed to structure only — a dotted name plus count/enum/version
    /// parameters, NEVER user content (TelemetryDeck stores no PII; same clean-at-source rule as
    /// diagnostics). `floatValue` is the SDK's one numeric field — the dashboard can sum/average it
    /// (durations, per-cycle counts). `.extended` signals no-op when the switch is off; `.core`
    /// signals always send once the SDK is up (never in DEBUG — `started` stays false there).
    static func signal(_ name: String, parameters: [String: String] = [:],
                       floatValue: Double? = nil, tier: Tier = .extended) {
        guard started else { return }
        if tier == .extended, !analyticsEnabled { return }
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }

    /// Task descriptions are always-on in Release, independent of the extended toggle.
    /// Debug stays entirely local, including the background privacy review.
    static var taskSummariesEnabled: Bool { started }

    /// Sole free-text analytics entry: Approved can only be created by SidekickTaskSummary's
    /// privacy reviewer. No raw prompt, final response, history or rejection reason is accepted.
    static func recordTaskSummary(_ summary: SidekickTaskSummary.Approved?,
                                  outcome: CommandRunModel.Outcome, source: String, method: String) {
        guard taskSummariesEnabled else { return }
        TelemetryDeck.signal("Sidekick.taskSummary", parameters: taskSummaryParameters(summary,
            outcome: outcome, source: source, method: method))
    }

    static func taskSummaryParameters(_ summary: SidekickTaskSummary.Approved?,
                                      outcome: CommandRunModel.Outcome, source: String, method: String) -> [String: String] {
        var fields = ["source": ["promptBar", "notchTyped", "voice", "command"].contains(source) ? source : "other",
                      "method": ["computer", "mcp"].contains(method) ? method : "other",
                      "outcome": outcome == .success ? "success" : (outcome == .stopped ? "stopped" : "failed"),
                      "summary_status": summary == nil ? "unavailable" : "available",
                      "summary_version": "1"]
        if let summary { fields["summary"] = summary.phrase }
        return fields
    }

    // MARK: - Opt-out

    /// React to a mid-session flip of the "Share anonymous analytics" switch (Settings → System).
    /// The SDK stays up either way (the core tier keeps sending); the per-signal tier gate starts or
    /// stops the extended signals the instant the switch flips, so there's nothing to tear down.
    static func applyEnabledChange() {
        start()   // a first-ever flip on a boot that somehow never started — harmless if already up
        Log("Analytics: extended analytics \(analyticsEnabled ? "on" : "off") — core telemetry unaffected")
    }

    // MARK: - The one-off anonymous install count (uncorrelatable, switch-independent)

    private static let installCountedKey = "analytics.installCounted"
    private static let installSignalType = "App.anonymousInstall"
    private static let uninstallSignalType = "App.anonymousUninstall"
    private static let ingestURL = URL(string: "https://nom.telemetrydeck.com/v2/")!

    /// Send the single anonymous install ping — see the file header. Fires at most once per install
    /// (latched in UserDefaults once it lands), independent of the analytics switch, and harder-line
    /// than even the core tier: where core signals ride the anonymous install id, this one carries a
    /// throwaway hash correlatable to NOTHING — the bare "an install exists" beacon. Release-only
    /// (a dev's Debug launches never inflate the count). It goes NOT through the SDK but as one
    /// direct, minimal POST carrying no identity, no device info, and no content. Fire-and-forget;
    /// called once from main.swift.
    static func countInstallOnce() {
        #if DEBUG
        Log("Analytics: DEBUG build — anonymous install ping skipped (Release-only)")
        #else
        guard !appID.hasPrefix("PASTE_") else { return }
        guard !UserDefaults.standard.bool(forKey: installCountedKey) else { return }   // one-off, forever
        postAnonymousSignal(type: installSignalType) { ok in
            guard ok else { return }   // not latched → retried next launch until it lands exactly once
            UserDefaults.standard.set(true, forKey: installCountedKey)
            Log("Analytics: anonymous install counted (one-off)")
        }
        #endif
    }

    /// The install count's farewell twin: one anonymous "an install left" ping, fired as the
    /// uninstall teardown begins. Same hard line as `countInstallOnce()` — a throwaway hash
    /// correlatable to nothing, an empty payload, one direct POST (the SDK's queue may never
    /// flush this close to quit). Release-only, fire-and-forget: the teardown never waits on the
    /// network, and a lost ping is simply lost (no retry — the app is about to be gone).
    static func countUninstall() {
        #if DEBUG
        Log("Analytics: DEBUG build — anonymous uninstall ping skipped (Release-only)")
        #else
        guard !appID.hasPrefix("PASTE_") else { return }
        postAnonymousSignal(type: uninstallSignalType) { _ in }
        #endif
    }

    /// The direct one-shot ingest POST, matching TelemetryDeck's V2 signal body. `clientUser` is a
    /// throwaway random hash (never stored, never reused — so it ties to nothing), the payload is
    /// empty, and no version/device/content rides along: a truly bare count. TelemetryDeck stores no
    /// IP and salts the hash again, so this stays anonymous end to end.
    private static func postAnonymousSignal(type: String, _ done: @escaping @Sendable (Bool) -> Void) {
        let body: [[String: Any]] = [[
            "receivedAt": ingestDateFormatter.string(from: Date()),
            "appID": appID,
            "clientUser": sha256Hex(UUID().uuidString),
            "sessionID": UUID().uuidString,
            "type": type,
            "payload": [String: String](),
            "isTestMode": "false",
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { done(false); return }
        var req = URLRequest(url: ingestURL)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ok = err == nil && ((resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            done(ok)
        }.resume()
    }

    /// TelemetryDeck's ingest date format (`yyyy-MM-dd'T'HH:mm:ssZ`, GMT) — mirrored so the raw POST
    /// speaks the same wire format as the SDK.
    private static let ingestDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
