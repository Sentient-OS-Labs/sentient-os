//
//  SentientUpdateDriver.swift
//  Sentient OS macOS
//
//  Our custom Sparkle user driver — Sentient renders its OWN OLED update UI instead of Sparkle's
//  stock AppKit windows. Sparkle's internal drivers call these callbacks to say "show checking",
//  "an update was found", "download progress", etc.; we translate each into UpdateModel state that
//  UpdateGateView draws, and stash the reply/acknowledge closures for the user's tap.
//
//  MANDATORY updates: `showUpdateFound…` only ever replies `.install` (never skip/dismiss), and
//  `showReady(toInstallAndRelaunch:)` auto-installs — so a found update is one tap to update, with
//  no way to defer. Nothing here can hard-lock an offline user: with no reachable feed, Sparkle
//  simply never calls `showUpdateFound…`, so the gate never appears.
//
//  The method names/labels below MUST match Sparkle's imported Swift signatures exactly (Swift
//  matches these protocol witnesses by signature). Doc: Documentation/Auto-Update (Sparkle).md
//

import Foundation
import Sparkle

final class SentientUpdateDriver: NSObject, SPUUserDriver {
    private let model: UpdateModel

    init(model: UpdateModel) {
        self.model = model
        super.init()
    }

    // MARK: Permission (normally unused — SUEnableAutomaticChecks is set in Info.plist)

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Updates are mandatory, so there's nothing to opt out of: accept checks, send no profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.beganCheck(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.foundUpdate(version: appcastItem.displayVersionString, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The gate shows a short "what's new" from the appcast version, not fetched HTML notes.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        model.notFound(acknowledge: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // If we were mid-update, keep the gate (Try Again / Quit). If it's just a check that couldn't
        // reach the feed, it stays quiet unless the user asked — fail-open, never lock anyone out.
        model.failed(friendly(error), duringUpdate: model.isMidUpdate, acknowledge: acknowledgement)
    }

    // MARK: Downloading & extracting

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        model.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        model.expected(bytes: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        model.received(bytes: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        model.extractingStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.extracting(progress)
    }

    // MARK: Installing & relaunching

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Mandatory: no second confirmation — install and relaunch immediately.
        model.installingNow()
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        model.installingNow()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // The old bundle is gone; just acknowledge so Sparkle finishes.
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        model.reset()
    }

    // MARK: Optional

    func showUpdateInFocus() {
        // Our gate window already floats above everything; nothing to bring forward.
    }

    // MARK: - Helpers

    /// A short, human message from a Sparkle NSError (its recovery suggestion if present).
    private func friendly(_ error: any Error) -> String {
        let nsError = error as NSError
        if let recovery = nsError.localizedRecoverySuggestion, !recovery.isEmpty {
            return recovery
        }
        return nsError.localizedDescription
    }
}
