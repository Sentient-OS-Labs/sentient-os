// Reads Mac power and thermal state and applies shared analysis admission/stop rules.
// Overnight work starts at 50% initially and 30% for updates; manual runs ignore battery level.
// Doc: Documentation - Overnight Scheduler & Wake Helper.md

import Foundation
import IOKit.ps

enum PowerState {

    /// True iff the Mac is on AC/wall power (not draining the battery).
    static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return false   // can't tell → treat as NOT on AC (fail safe: don't run overnight on battery)
        }
        return type == kIOPMACPowerKey
    }

    /// The internal battery's charge, 0–100. Nil when there's no readable battery (desktop Macs).
    static func batteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (current * 100) / max
        }
        return nil
    }

    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

    /// A short, stable label for logs/diagnostics (never a raw enum print).
    static var thermalLabel: String {
        switch thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static let initialBatteryFloor = 50
    static let iterativeBatteryFloor = 30
    static let reserveBatteryFloor = 20

    struct Snapshot: Sendable {
        let onAC: Bool
        let percent: Int?
        let critical: Bool
    }

    static func snapshot() -> Snapshot {
        Snapshot(onAC: onACPower(), percent: batteryPercent(), critical: thermalState == .critical)
    }

    enum Block: String, Codable, Sendable {
        case onBattery = "on_battery", batteryLow = "battery_low", unknown = "power_unknown"
        case thermal = "thermal_critical"
    }

    /// Explicit Run now bypasses power requirements. Thermal protection applies to every run.
    static func block(_ power: Snapshot, initial: Bool, allowBattery: Bool = true, scheduled: Bool = true) -> Block? {
        if power.critical { return .thermal }
        guard scheduled else { return nil }
        if power.onAC { return nil }
        if !allowBattery { return .onBattery }
        guard let percent = power.percent else { return .unknown }
        return percent < (initial ? initialBatteryFloor : iterativeBatteryFloor) ? .batteryLow : nil
    }

    /// Only unattended runs pause at the battery reserve; manual work continues at any charge.
    static func shouldPause(_ power: Snapshot, scheduled: Bool = true) -> Bool {
        power.critical || (scheduled && !power.onAC && (power.percent.map { $0 <= reserveBatteryFloor } ?? true))
    }

    /// Diagnostic compatibility for callers that need a stable blocking reason.
    static func overnightBlockReason(allowBattery: Bool) -> String? {
        block(snapshot(), initial: ProcessingPlan.initialCompletedAt() == nil,
              allowBattery: allowBattery)?.rawValue
    }
}
