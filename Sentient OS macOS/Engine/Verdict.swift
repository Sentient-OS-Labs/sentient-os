//
//  Verdict.swift
//  Sentient OS macOS
//
//  The on-device triage verdict — the "bouncer" decision for each artifact (Triage.decide maps a
//  model reply onto it). Was the last survivor of the old Store/Models.swift; the live database is
//  CycleStore (Ingestion/CycleStore.swift), which owns its own @Models.
//

import Foundation

/// The on-device model's per-artifact verdict. Survivors get a summary kept for the cloud step;
/// junk/sensitive save NOTHING (zero trace — judged on-device, dropped, gone).
enum Verdict: Int, Codable, Sendable {
    case survivor = 0   // useful + not sensitive → kept, enters the vault (Stage 2)
    case junk      = 1   // not worth keeping      → zero trace
    case sensitive = 2   // must never leave device → zero trace
}
