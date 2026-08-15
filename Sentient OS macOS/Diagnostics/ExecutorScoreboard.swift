//
//  ExecutorScoreboard.swift
//  Sentient OS macOS
//
//  The health metric for the flagship feature — AI that DOES things (§7.19). One sink, fed from
//  ProactiveExecutor.fire() (the proactive cards) and CommandRunModel.complete() (the command bar /
//  voice). Sentry sees DEFECTS only — failures, refusals, dead fire buttons, and unverifiable
//  "fired" claims (no STATUS sentinel). Verified successes are USAGE, and usage lives in
//  TelemetryDeck (ComputerUse.finished / Proactive.actionFired), never the crash feed — Sentry
//  turned every success into an "issue" and buried the real errors (field-found 2026-07-12).
//
//  ⚠️ `fired` means codex CLAIMED it finished — NOT verified completion. True end-to-end
//  verification (did the email actually leave?) is a separate problem.
//  Structure only — method/source/outcome/duration, never the draft, recipients, or codex output.
//

import Foundation

enum ExecutorScoreboard {
    /// fired = codex claimed done · notFireable = no channel / prereq missing · failed = errored or
    /// timed out · refused = codex cleanly declined (the `STATUS: COULD_NOT` sentinel).
    enum Outcome: String, Sendable { case fired, notFireable, failed, refused }

    static func record(method: String, source: String, outcome: Outcome,
                       durationS: Double, statusPresent: Bool = true, errorClass: String? = nil) {
        // A verified success is not a defect — TelemetryDeck counts it; Sentry stays quiet. A
        // "fired" WITHOUT the STATUS sentinel still reports: that's the false-success RISK the
        // sentinel exists to measure.
        guard outcome != .fired || !statusPresent else { return }
        var extra: [String: String] = [
            "duration_s": String(format: "%.1f", durationS),
            "status_present": String(statusPresent),
        ]
        if let errorClass { extra["error_class"] = errorClass }
        CrashReporting.captureEvent("executor.fire", level: .warning,
            tags: ["method": method, "source": source, "outcome": outcome.rawValue],
            extra: extra, fingerprint: ["executor", "fire", method, outcome.rawValue])
    }
}
