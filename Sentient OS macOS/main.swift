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
    WakeHelper.run()        // root LaunchDaemon mode — never returns
} else {
    SentientOSApp.main()    // normal GUI app
}
