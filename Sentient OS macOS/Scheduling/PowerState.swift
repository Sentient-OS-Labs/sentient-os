//
//  PowerState.swift  ·  Scheduling/
//
//  The overnight run's go/no-go gates (B6; doc: Scheduling/Documentation - Overnight Scheduler & Wake Helper.md).
//  A lid-shut 3am run holds the Mac fully awake
//  and hammers the GPU, so we only do it when it's safe: on AC power (not in Low Power Mode), or on
//  battery above a charge floor when the user has opted in; never thermally critical. Thermal is a
//  START condition only (we don't abort a run that heats up mid-flight — lid-shut runs hotter; we
//  just log it). Pure reads, no side effects.
//

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

    /// The charge floor for a battery night: below this we don't start (a heavy night can drain
    /// 15–30%, and waking up to a near-dead Mac would be worse than a skipped run).
    static let batteryFloorPercent = 40

    /// Overnight go/no-go. Returns the blocking reason, or nil if it's safe to start a run.
    /// `allowBattery` is the user's opt-in (the home's Analysis dropdown): with it, a battery night
    /// runs above the charge floor, and Low Power Mode doesn't gate it — LPM is commonly set to
    /// "Only on Battery", which would silently kill every battery night; the run just goes slower.
    static func overnightBlockReason(allowBattery: Bool) -> String? {
        if !onACPower() {
            guard allowBattery else { return "on_battery" }
            guard let pct = batteryPercent(), pct >= batteryFloorPercent else { return "battery_low" }   // unreadable → fail safe
        } else if lowPowerMode {
            return "low_power"
        }
        if thermalState == .critical { return "thermal_critical" }
        return nil
    }
}
