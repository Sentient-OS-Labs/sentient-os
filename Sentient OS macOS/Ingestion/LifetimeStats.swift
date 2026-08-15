//
//  LifetimeStats.swift
//  Sentient OS macOS
//
//  Tiny UserDefaults-backed lifetime counters ("12,438 things understood"). With the ledger
//  gone, junk/sensitive items leave zero trace — these counters are the only memory that an
//  item was ever looked at, and they're numbers, not records. Bumped by IterativeRun per
//  item; reset by FactoryReset.
//

import Foundation

enum LifetimeStats {
    private static let key = "stats.lifetime"   // [String: Int]

    static func bump(_ verdict: Verdict) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        d["analyzed", default: 0] += 1
        switch verdict {
        case .survivor:  d["survivors", default: 0] += 1
        case .junk:      d["junk", default: 0] += 1
        case .sensitive: d["sensitive", default: 0] += 1
        }
        UserDefaults.standard.set(d, forKey: key)
    }

    static var analyzed: Int { value("analyzed") }
    static var survivors: Int { value("survivors") }
    static var junk: Int { value("junk") }
    static var sensitive: Int { value("sensitive") }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    private static func value(_ name: String) -> Int {
        ((UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:])[name] ?? 0
    }
}
