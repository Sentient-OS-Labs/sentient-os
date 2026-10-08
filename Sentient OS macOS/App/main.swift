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

// Browser helper arguments contain an OAuth URL. Handle them before any diagnostics or UI.
if CommandLine.arguments.dropFirst().first == ClaudeLoginBrowser.helperArgument {
    exit(ClaudeLoginBrowser.runHelper(arguments: CommandLine.arguments))
}

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

let childDiagnostics = ChildProcessDiagnostics.Role.from(CommandLine.arguments.dropFirst().first).flatMap { ChildProcessDiagnostics.begin(role: $0) }

if CommandLine.arguments.dropFirst().first == ClaudeSubscriptionProcess.argument {
    Task.detached {
        let status = await ClaudeSubscriptionProcess.run()
        childDiagnostics?.finish(status); exit(status)
    }
    dispatchMain()
} else if CommandLine.arguments.dropFirst().first == "--outlook-tool-policy" {
    let status = OutlookToolPolicy.runHelper(arguments: CommandLine.arguments)
    childDiagnostics?.finish(status); exit(status)
} else if CommandLine.arguments.dropFirst().first == "--slack-tool-policy" {
    let status = SlackToolPolicy.runHelper(arguments: CommandLine.arguments)
    childDiagnostics?.finish(status); exit(status)
} else if CommandLine.arguments.dropFirst().first.map({ ["--direct-mcp-headers", "--direct-mcp-policy"].contains($0) }) == true {
    let arguments = CommandLine.arguments
    Task.detached {
        let status = await DirectMCPRuntime.runHelper(arguments: arguments)
        childDiagnostics?.finish(status); exit(status)
    }
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
