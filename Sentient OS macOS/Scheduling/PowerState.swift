//
//  PowerState.swift  ·  Scheduling/
//
//  The overnight run's go/no-go gates (Arch §9 / B6). A lid-shut 3am run holds the Mac fully awake
//  and hammers the GPU, so we only do it when it's safe: on AC power, not in Low Power Mode, and not
//  already thermally critical. Thermal is a START condition only (we don't abort a run that heats up
//  mid-flight — lid-shut runs hotter; we just log it). Pure reads, no side effects.
//

import Foundation
import IOKit.ps

enum PowerState {

    /// True iff the Mac is on AC/wall power (not draining the battery).
    static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String? else {
            return false   // can't tell → treat as NOT on AC (fail safe: don't run overnight on battery)
        }
        return type == kIOPSACPowerValue
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

    /// Overnight go/no-go. Returns the blocking reason, or nil if it's safe to start a run.
    static func overnightBlockReason() -> String? {
        if !onACPower()          { return "on_battery" }
        if lowPowerMode          { return "low_power" }
        if thermalState == .critical { return "thermal_critical" }
        return nil
    }
}
