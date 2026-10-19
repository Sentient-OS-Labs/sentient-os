//
//  PipelineActivity.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  A tiny "is the pipeline running?" flag, set by IterativeRun and ProactiveCycle (a counter, so
//  overlapping legs nest safely). Coordinates analysis admission and idle-only setup.
//  Reset and Uninstall cancel and drain work through ProcessingCoordinator before wiping data;
//  this activity flag does not lock the user out of either action.
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

    /// The analysis owner holds this synchronously across all legs and cancellation draining.
    func acquire() { activeRuns += 1 }
    func release() { activeRuns = max(0, activeRuns - 1) }

    /// Callable from any actor (the runs live off-main); hops to main for the observable write.
    nonisolated static func begin() { Task { @MainActor in shared.acquire() } }
    nonisolated static func end() { Task { @MainActor in shared.release() } }
}
