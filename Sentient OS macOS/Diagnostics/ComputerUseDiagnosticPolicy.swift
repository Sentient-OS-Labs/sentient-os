import Foundation

/// Eligibility only limits diagnostic offers. It never stops or limits the original task.
nonisolated struct ComputerUseDiagnosticPolicy {
    struct Target: Sendable { let id: String; let isBrowser: Bool }
    private var failedReads = 0
    private var failedDiscovery = 0
    private var targets: Set<String> = []
    private var hasNonBrowser = false
    var eligible: Bool {
        failedDiscovery >= 3 || (failedReads >= 3 && targets.count >= 2 && hasNonBrowser)
    }

    mutating func observe(tool: String, target: Target?, failure: NativeComputerUseFailure?) {
        guard let failure else {
            if tool == "list_apps" { failedDiscovery = 0 }
            else { self = Self() } // Any usable UI read/action means computer use is working.
            return
        }
        guard tool == "get_app_state" || tool == "list_apps" else { self = Self(); return }
        let broadFailure: Bool
        switch failure.detail {
        case .unexpectedEOF, .processExited, .writeFailed, .disconnected,
             .requestTimedOut, .screenshotCaptureFailed, .screenCaptureFailed,
             .unknownCaptureFailed, .missingImage, .invalidImage:
            broadFailure = failure.kind == .connection || failure.kind == .capture || failure.kind == .timeout
        default: broadFailure = false
        }
        guard broadFailure else { self = Self(); return }
        if tool == "list_apps" {
            failedDiscovery = min(3, failedDiscovery + 1)
        } else if let target {
            failedReads = min(3, failedReads + 1)
            if targets.count < 2 { targets.insert(target.id) }
            hasNonBrowser = hasNonBrowser || !target.isBrowser
        }
    }

    static func isBrowser(_ identity: String) -> Bool {
        let identity = identity.lowercased()
        let bundles = ["com.apple.safari", "com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac",
            "org.mozilla.firefox", "com.brave.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "company.thebrowser.browser", "company.thebrowser.dia", "com.kagi.kagimacos"]
        if bundles.contains(where: { identity == $0 || identity.hasPrefix($0 + ".") }) { return true }
        let name = URL(fileURLWithPath: identity).deletingPathExtension().lastPathComponent
        return ["safari", "safari technology preview", "google chrome", "google chrome canary", "chromium",
            "microsoft edge", "microsoft edge beta", "microsoft edge dev", "microsoft edge canary", "firefox",
            "firefox developer edition", "brave browser", "opera", "vivaldi", "arc", "dia", "orion"].contains(name)
    }
}
