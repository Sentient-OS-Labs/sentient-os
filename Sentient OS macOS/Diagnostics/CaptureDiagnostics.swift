// Content-free capture evidence shared by native tasks, the health probe and display screenshots.
// Correlates capture outcomes in Sentry and the bounded local export ledger.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import AppKit

nonisolated struct CaptureDiagnostics: Sendable {
    enum Source: String, Sendable { case native, healthProbe = "health_probe", display }
    enum Outcome: String, Sendable { case started, passed, failed, recovered, cancelled, skipped }
    let id = UUID()
    let source: Source
    private let operation: Diagnostics.Operation?
    private let correlation: [String: String]

    init(source: Source, context: CaptureDiagnostics? = nil) {
        self.source = source
        operation = context?.operation ?? Diagnostics.current
        correlation = context?.correlation ?? CrashReporting.correlationFields
    }

    func record(_ outcome: Outcome, attempt: Int = 1, failure: NativeComputerUseFailure? = nil,
                fields: [String: String] = [:]) {
        var evidence = correlation.merging(fields) { _, new in new }
        evidence.merge(["capture_id": id.uuidString, "capture_source": source.rawValue,
                        "capture_outcome": outcome.rawValue, "capture_attempt": String(attempt),
                        "helper_build": String(CodexRuntime.release.helperBuild),
                        "helper_version": CodexRuntime.release.helper.version,
                        "diagnostic_schema": "3", "cli_version": CodexRuntime.release.cli.version]) { _, new in new }
        if let failure { evidence.merge(failure.fields) { _, new in new } }
        Diagnostics.$current.withValue(operation) {
            CrashReporting.diagnosticBreadcrumb("computer_use.capture", data: evidence)
            // Keep capture evidence locally, even when Sentry is disabled.
            DiagnosticHistory.recordCapture(evidence)
            if outcome == .failed {
                CrashReporting.captureEvent("computer_use.capture_failed", level: source == .native ? .info : .warning,
                    tags: ["capture_source": source.rawValue, "failure_stage": failure?.stage.rawValue ?? "unknown",
                           "native_detail": failure?.detail.rawValue ?? "unspecified", "diagnostic_schema": "3"],
                    extra: evidence,
                    fingerprint: ["computer_use.capture_failed", source.rawValue, failure?.stage.rawValue ?? "unknown",
                                  failure?.detail.rawValue ?? "unspecified"], cooldown: 0,
                    includeInformational: source == .native, affectsOperation: false)
            }
        }
    }

    /// Process/window metadata only. Titles, app paths and accessibility text never enter evidence.
    @MainActor static func environment(target: NSRunningApplication? = nil) -> [String: String] {
        let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID).filter { !$0.isTerminated }
        var fields = ["helper_process_count": String(helpers.count),
            "helper_expected_path": String(helpers.count == 1 && helpers.first?.bundleURL?.standardizedFileURL == OpenAIComputerUse.appURL.standardizedFileURL),
            "helper_screen_granted_cached": String(ComputerUseGate.shared.helperScreen),
            "helper_accessibility_granted_cached": String(ComputerUseGate.shared.helperAccessibility),
            "sentient_screen_preflight": String(CGPreflightScreenCaptureAccess()),
            "display_count": String(NSScreen.screens.count)]
        // Best-effort context only, never a gate or a reason to stop an agent.
        if let enabled = UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "GloballyEnabled") as? Bool {
            fields["stage_manager_enabled_cached"] = String(enabled)
        }
        if let target {
            fields["target_running"] = String(!target.isTerminated)
            fields["target_hidden"] = String(target.isHidden)
            fields["target_active"] = String(target.isActive)
            // Do not request titles or persist the returned window dictionaries.
            let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(target.processIdentifier)
                    && ($0[kCGWindowLayer as String] as? Int) == 0 }
            fields["target_window_count"] = String(windows.count)
            fields["target_onscreen_count"] = String(windows.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }.count)
        }
        return fields
    }
}
