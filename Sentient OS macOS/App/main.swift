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

if CommandLine.arguments.contains(WakeHelperConfig.helperFlag) {
    CrashReporting.start(.wakeHelper)   // crash reporting for the root overnight path
    WakeHelper.run()                    // root LaunchDaemon mode — never returns
} else {
    CrashReporting.start(.app)          // crash reporting for the GUI app
    Analytics.start()                   // product analytics (TelemetryDeck) — GUI app only
    Analytics.countInstallOnce()        // the one anonymous install ping — fires even when opted out
    // Language instructions live in ResponseLanguage (computed per AI call). Clear any copy that
    // was mistakenly pasted into the editable Proactive text field so deleting that field can
    // never "lose" localization.
    CustomInstructions.stripMisplacedLanguageInstructionsIfNeeded()
    SentientOSApp.main()                // normal GUI app
}
