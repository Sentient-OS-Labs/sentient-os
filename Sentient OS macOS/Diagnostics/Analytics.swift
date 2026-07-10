//
//  Analytics.swift
//  Sentient OS macOS
//
//  TelemetryDeck integration — the app's privacy-safe PRODUCT analytics (how many people use the app,
//  how far they get in onboarding, which features actually fire). The twin of CrashReporting.swift
//  (Sentry, which is crashes/errors). Two gates, mirroring Sentry's:
//    1. RELEASE builds only — a no-op in DEBUG, so a dev's day-to-day Debug runs never pollute the
//       real usage numbers. Verify the pipeline from a Release build (same rule as Sentry).
//    2. Its OWN opt-OUT switch — `analyticsEnabled` (default ON), the "Share anonymous analytics"
//       toggle in Settings → System. Crash reports keep their separate switch (CrashReporting's
//       `diagnosticsEnabled`) — the two consents split when the real Settings shipped, so a user
//       can keep crash reports on while opting out of usage analytics (or vice versa).
//  Identity is the same anonymous per-install UUID (`CrashReporting.installID`); TelemetryDeck hashes
//  it again on-device and once more on their server, and stores no PII and no IP address by design —
//  so this upholds the Privacy Constitution (no accounts, nothing personal leaves the Mac). Signals
//  carry structure only (names + counts/enums/versions), never user content — clean at the source.
//
//  The ONE thing the opt-out switch does NOT silence: `countInstallOnce()`, a single, totally
//  anonymous "an install exists" ping that fires at most once per install EVEN when analytics are
//  off, so we can always count how many people use Sentient. It carries no identity (a throwaway
//  random hash, never stored, uncorrelatable to the install id or the crash-report id), no device
//  info, and no content — just a bare count. It is disclosed in the opt-out's own Settings copy, so
//  the switch is never a lie. All richer product analytics remain fully behind the opt-out.
//
//  Key members:
//   - start()                 → boot TelemetryDeck (Release-only, opt-out gated)
//   - signal(_:parameters:)   → send one product event (no-op until started / when opted out)
//   - countInstallOnce()      → the one-off anonymous install count (Release-only, opt-out-INDEPENDENT)
//   - applyEnabledChange()    → react to a mid-session flip of the shared opt-out switch
//
//  Doc: Documentation/Product Analytics (TelemetryDeck).md · twin: Documentation/Crash Reporting (Sentry).md
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

    // MARK: - Opt-out gate

    private static let analyticsKey = "analyticsEnabled"

    /// The opt-OUT switch: default ON, gates all TelemetryDeck sends. Treats an unset key as ON
    /// (a bare `bool(forKey:)` reads a missing key as false → would wrongly read as opted out).
    nonisolated static var analyticsEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: analyticsKey) == nil { return true }
        return d.bool(forKey: analyticsKey)
    }

    // MARK: - Boot

    /// Boot TelemetryDeck for the GUI app — Release-only, and only if analytics are on. A deliberate
    /// no-op in DEBUG and while the App ID is still the placeholder. Called from main.swift's `.app`
    /// branch (NOT the root wake-helper — the privileged path sends no analytics). Idempotent.
    static func start() {
        guard !started else { return }
        guard analyticsEnabled else {
            Log("Analytics: analytics opted out — TelemetryDeck disabled")
            return
        }
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
        Log("Analytics: TelemetryDeck started")
        #endif
    }

    // MARK: - Signals

    /// Send one product event. Guard-railed to structure only — a dotted name plus count/enum/version
    /// parameters, NEVER user content (TelemetryDeck stores no PII; same clean-at-source rule as
    /// diagnostics). No-op until started and whenever analytics are opted out.
    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard started, analyticsEnabled else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    // MARK: - Opt-out

    /// React to a mid-session flip of the "Share anonymous analytics" switch (Settings → System). On →
    /// boot; off → latch off so nothing more is sent (TelemetryDeck has no explicit teardown, and the
    /// per-signal gate already blocks sends the instant the switch is off).
    static func applyEnabledChange() {
        if analyticsEnabled {
            start()
        } else {
            started = false
            Log("Analytics: analytics turned off — TelemetryDeck silenced")
        }
    }

    // MARK: - The one-off anonymous install count (opt-out-INDEPENDENT)

    private static let installCountedKey = "analytics.installCounted"
    private static let installSignalType = "App.anonymousInstall"
    private static let ingestURL = URL(string: "https://nom.telemetrydeck.com/v2/")!

    /// Send the single anonymous install ping — see the file header. Fires at most once per install
    /// (latched in UserDefaults once it lands), and — unlike everything else here — does so even when
    /// analytics are OPTED OUT: it's the bare "an install exists" beacon that lets us count how many
    /// people use Sentient, and it's disclosed in the opt-out's Settings copy so the switch stays
    /// honest. Release-only (a dev's Debug launches never inflate the count). It goes NOT through the
    /// SDK (which would spin up ongoing session tracking) but as one direct, minimal POST carrying no
    /// identity, no device info, and no content. Fire-and-forget; called once from main.swift.
    static func countInstallOnce() {
        #if DEBUG
        Log("Analytics: DEBUG build — anonymous install ping skipped (Release-only)")
        #else
        guard !appID.hasPrefix("PASTE_") else { return }
        guard !UserDefaults.standard.bool(forKey: installCountedKey) else { return }   // one-off, forever
        postAnonymousInstall { ok in
            guard ok else { return }   // not latched → retried next launch until it lands exactly once
            UserDefaults.standard.set(true, forKey: installCountedKey)
            Log("Analytics: anonymous install counted (one-off)")
        }
        #endif
    }

    /// The direct one-shot ingest POST, matching TelemetryDeck's V2 signal body. `clientUser` is a
    /// throwaway random hash (never stored, never reused — so it ties to nothing), the payload is
    /// empty, and no version/device/content rides along: a truly bare count. TelemetryDeck stores no
    /// IP and salts the hash again, so this stays anonymous end to end.
    private static func postAnonymousInstall(_ done: @escaping @Sendable (Bool) -> Void) {
        let body: [[String: Any]] = [[
            "receivedAt": ingestDateFormatter.string(from: Date()),
            "appID": appID,
            "clientUser": sha256Hex(UUID().uuidString),
            "sessionID": UUID().uuidString,
            "type": installSignalType,
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
