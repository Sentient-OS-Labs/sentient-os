//
//  ExecutorScoreboard.swift
//  Sentient OS macOS
//
//  The health metric for the flagship feature — AI that DOES things (§7.19). One sink, fed from
//  ProactiveExecutor.fire() (the proactive cards) and CommandRunModel.complete() (the command bar /
//  voice), records the outcome of every executed action so the Sentry dashboard can answer "how
//  often does computer-use / Gmail-send actually work?".
//
//  ⚠️ `fired` means codex CLAIMED it finished — NOT verified completion. The dashboard reads it as
//  "claimed done"; true end-to-end verification (did the email actually leave?) is a separate problem.
//  Structure only — method/source/outcome/duration, never the draft, recipients, or codex output.
//

import Foundation

enum ExecutorScoreboard {
    /// fired = codex claimed done · notFireable = no channel / prereq missing · failed = errored or
    /// timed out · refused = codex cleanly declined (the `STATUS: COULD_NOT` sentinel).
    enum Outcome: String, Sendable { case fired, notFireable, failed, refused }

    static func record(method: String, source: String, outcome: Outcome,
                       durationS: Double, statusPresent: Bool = true, errorClass: String? = nil) {
        let level: CrashReporting.DiagLevel = (outcome == .failed || outcome == .refused) ? .warning : .info
        var extra: [String: String] = [
            "duration_s": String(format: "%.1f", durationS),
            // false = codex omitted the STATUS sentinel → we can't confirm it, so "fired" here is a
            // false-success RISK. Tracking this rate is the whole point of the sentinel.
            "status_present": String(statusPresent),
        ]
        if let errorClass { extra["error_class"] = errorClass }
        CrashReporting.captureEvent("executor.fire", level: level,
            tags: ["method": method, "source": source, "outcome": outcome.rawValue],
            extra: extra, fingerprint: ["executor", "fire", method, outcome.rawValue])
    }
}
