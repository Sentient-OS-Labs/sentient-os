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
// Native computer-use validation starts before AppState or any production startup side effect.
if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "nativecua",
   CommandLine.arguments.count == 1 {
    NSApplication.shared.setActivationPolicy(.regular)
    Task { await NativeComputerUseLab.run(); exit(0) }
    NSApplication.shared.run()
    exit(0)
}
// Helper/wake invocations must retain their dedicated entry even if a child inherits lab env.
if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "connectorlab",
   CommandLine.arguments.count == 1 {
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

if CommandLine.arguments.dropFirst().first == "--outlook-tool-policy" {
    exit(OutlookToolPolicy.runHelper(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--slack-tool-policy" {
    exit(SlackToolPolicy.runHelper(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first.map({ ["--direct-mcp-headers", "--direct-mcp-policy"].contains($0) }) == true {
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
