//
//  Analytics.swift
//  Sentient OS macOS
//
//  TelemetryDeck integration — the app's privacy-safe PRODUCT analytics (how many people use the app,
//  how far they get in onboarding, which features actually fire). The twin of CrashReporting.swift
//  (Sentry, which is crashes/errors) and it deliberately reuses that file's two gates and identity so
//  there is ONE opt-out and ONE anonymous identity, never a second consent surface:
//    1. RELEASE builds only — a no-op in DEBUG, so a dev's day-to-day Debug runs never pollute the
//       real usage numbers. Verify the pipeline from a Release build (same rule as Sentry).
//    2. The shared opt-OUT switch — `CrashReporting.diagnosticsEnabled` (default ON) gates everything.
//  Identity is the same anonymous per-install UUID (`CrashReporting.installID`); TelemetryDeck hashes
//  it again on-device and once more on their server, and stores no PII and no IP address by design —
//  so this upholds the Privacy Constitution (no accounts, nothing personal leaves the Mac). Signals
//  carry structure only (names + counts/enums/versions), never user content — clean at the source.
//
//  Key members:
//   - start()                 → boot TelemetryDeck (Release-only, opt-out gated)
//   - signal(_:parameters:)   → send one product event (no-op until started / when opted out)
//   - applyEnabledChange()    → react to a mid-session flip of the shared opt-out switch
//
//  Doc: Documentation/Crash Reporting (Sentry).md (the twin) — an Analytics doc lands once wired end-to-end.
//

import Foundation
import TelemetryDeck

enum Analytics {

    /// The TelemetryDeck App ID — dashboard → Set Up → "Your App ID" (org namespace: ai.sentient-os).
    /// NOT a secret: signals only ever write IN, never read anything out, so it ships in source,
    /// open-source-safe — exactly like the Sentry DSN. ⚠️ Swap the placeholder for the real ID.
    private static let appID = "42A2F097-DBB1-4A63-BE45-0092962F36E6"

    private static var started = false

    // MARK: - Boot

    /// Boot TelemetryDeck for the GUI app — Release-only, and only if diagnostics are on. A deliberate
    /// no-op in DEBUG and while the App ID is still the placeholder. Called from main.swift's `.app`
    /// branch (NOT the root wake-helper — the privileged path sends no analytics). Idempotent.
    static func start() {
        guard !started else { return }
        guard CrashReporting.diagnosticsEnabled else {
            Log("Analytics: diagnostics opted out — TelemetryDeck disabled")
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
    /// diagnostics). No-op until started and whenever diagnostics are opted out.
    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard started, CrashReporting.diagnosticsEnabled else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    // MARK: - Opt-out

    /// React to a mid-session flip of the shared "Share anonymous diagnostics" switch (Settings). On →
    /// boot; off → latch off so nothing more is sent (TelemetryDeck has no explicit teardown, and the
    /// per-signal gate already blocks sends the instant the switch is off).
    static func applyEnabledChange() {
        if CrashReporting.diagnosticsEnabled {
            start()
        } else {
            started = false
            Log("Analytics: diagnostics turned off — TelemetryDeck silenced")
        }
    }
}
