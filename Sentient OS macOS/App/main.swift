//
//  main.swift
//  Sentient OS macOS
//
//  The process entry point. The SAME binary is reused as the root wake helper: launchd relaunches
//  it with --wake-helper, and we branch into helper mode HERE — before SwiftUI exists — so the
//  privileged path never touches the UI. Without the flag, this is the normal app.
//  (This is why SentientOSApp no longer carries @main: an explicit main.swift replaces it.)
//

import Foundation
import SwiftUI

#if DEBUG
if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "connectorlab",
   ProcessInfo.processInfo.environment["LAB_CMD"]?.hasPrefix("direct") == true {
    if ProcessInfo.processInfo.environment["LAB_CMD"] == "directrender" {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await ConnectorLab.run(); exit(0) }
        NSApplication.shared.run()
        exit(0)
    }
    Task { await ConnectorLab.run(); exit(0) }
    dispatchMain()
}
#endif

if CommandLine.arguments.dropFirst().first.map({ ["--direct-mcp-headers", "--direct-mcp-policy"].contains($0) }) == true {
    let arguments = CommandLine.arguments
    Task.detached { exit(await DirectMCPRuntime.runHelper(arguments: arguments)) }
    dispatchMain()
} else if CommandLine.arguments.contains(WakeHelperConfig.helperFlag) {
    CrashReporting.start(.wakeHelper)   // crash reporting for the root overnight path
    WakeHelper.run()                    // root LaunchDaemon mode — never returns
} else {
    CrashReporting.start(.app)          // crash reporting for the GUI app
    Analytics.start()                   // product analytics (TelemetryDeck) — GUI app only
    Analytics.countInstallOnce()        // the one anonymous install ping — fires even when opted out
    SentientOSApp.main()                // normal GUI app
}
