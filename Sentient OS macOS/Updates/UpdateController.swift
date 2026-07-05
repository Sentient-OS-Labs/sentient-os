//
//  UpdateController.swift
//  Sentient OS macOS
//
//  Owns the Sparkle updater and wires it to our own UI. Creates one SPUUpdater targeting the app's
//  main bundle, driven by SentientUpdateDriver (our OLED gate) with this object as the (optional)
//  delegate for logging. AppState holds one of these and calls `start()` — GUI path only (never the
//  root wake-helper). The menu bar and Settings call `checkForUpdatesNow()`.
//
//  Config (feed URL, EdDSA key, daily interval, mandatory model) lives in Info.plist — see
//  Documentation/Auto-Update (Sparkle).md. This file is just the runtime glue.
//

import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {

    /// The observable state our OLED update UI (UpdateGateView) reads and drives.
    let model = UpdateModel()

    private let driver: SentientUpdateDriver
    private var updater: SPUUpdater!

    override init() {
        let model = self.model
        driver = SentientUpdateDriver(model: model)
        super.init()
        updater = SPUUpdater(hostBundle: .main,
                             applicationBundle: .main,
                             userDriver: driver,
                             delegate: self)
    }

    /// Start scheduling checks, and immediately do one silent background check so a mandatory update
    /// gates at launch. With no reachable feed this is a no-op (fail-open — nobody gets locked out).
    func start() {
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            Log("Sparkle: updater failed to start — \(error.localizedDescription)")
        }
    }

    /// A user-asked check (menu bar / Settings). Shows the small info card for "checking" and
    /// "you're up to date"; escalates to the full gate if a real update is found.
    func checkForUpdatesNow() {
        guard updater.canCheckForUpdates else { return }
        model.userInitiated = true
        updater.checkForUpdates()
    }

    // MARK: - Read-only surface for Settings

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var lastCheckDate: Date? { updater.lastUpdateCheckDate }

    /// The installed version, formatted for display, e.g. "1.2.0 (42)".
    static var currentVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "\(short) (\(build))" }
        return short
    }

    // MARK: - SPUUpdaterDelegate (optional — logging only)

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        if let error {
            Log("Sparkle: update cycle finished with error — \((error as NSError).localizedDescription)")
        }
    }
}
