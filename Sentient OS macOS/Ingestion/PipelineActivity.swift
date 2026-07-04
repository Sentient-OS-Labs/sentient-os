//
//  PipelineActivity.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  A tiny "is the pipeline running?" flag, set by IterativeRun and ProactiveCycle (a counter, so
//  overlapping legs nest safely). First user: Settings → System disables Reset while a run is
//  active — wiping the store mid-run would leave high-water marks pointing past erased notes
//  (history silently skipped forever). UI guard only; the hard generation-counter guarantee is
//  the deferred Layer-2 hardening.
//

import Foundation
import Observation

@MainActor
@Observable
final class PipelineActivity {
    static let shared = PipelineActivity()
    private init() {}

    private(set) var activeRuns = 0
    var isRunning: Bool { activeRuns > 0 }

    /// Callable from any actor (the runs live off-main); hops to main for the observable write.
    nonisolated static func begin() { Task { @MainActor in shared.activeRuns += 1 } }
    nonisolated static func end() { Task { @MainActor in shared.activeRuns = max(0, shared.activeRuns - 1) } }
}
