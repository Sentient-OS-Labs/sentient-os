//
//  DiskSpace.swift
//  Sentient OS macOS
//
//  The free-space guard for everything Sentient writes under Application Support. Two jobs, one
//  place: (1) the capacity read every pre-flight uses (the "important usage" number Apple
//  recommends for "can I write this now"; it counts purgeable space, so it never under-reports
//  a healthy Mac), and (2) the after-the-fact classifier that recognizes a disk-full failure no
//  matter how the layer spelled it (SQLite's SQLITE_FULL, Cocoa's out-of-space code, POSIX
//  ENOSPC, or Core Data's wrapped sqlite code) so a run can stop at the FIRST one instead of
//  grinding through hundreds. Used by the model download pre-check (ModelDownload), the analysis
//  run's pre-flight (IterativeRun), CycleStore's per-item commit, and OvernightCaution's classifier.
//
//  Key members: available() · runFloor · isDiskFull(_:) · openStorageSettings()
//  Doc: System/Documentation - System (Permissions, Health, Uninstall).md
//

import AppKit
import Foundation

nonisolated enum DiskSpace {

    /// Bytes available for important usage on the volume that holds our Application Support root.
    /// nil = the read itself failed; callers fail OPEN (a glitched capacity read never blocks a
    /// healthy Mac).
    static func available() -> Int64? {
        try? URL.sentientSupport.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Below this, an analysis run does not start. A run writes the WAL-safe copies of the chat
    /// databases (up to a couple of GB for a heavy iMessage history), the cycle store, and later
    /// the knowledge-base staging copy; at 2 GB macOS is already warning the user itself. Well
    /// under the model download's 10 GB floor on purpose: that one stages a ~3 GB file, this
    /// one just needs room to save its notes.
    static let runFloor: Int64 = 2_000_000_000

    /// Does this error mean "the disk is full"? Walks the underlying-error chain, so a Core Data
    /// save error wrapping SQLite's SQLITE_FULL (which Core Data also stamps into userInfo under
    /// the `NSSQLiteErrorDomain` key) reads as disk-full at the top.
    static func isDiskFull(_ error: Error) -> Bool {
        var seen = 0
        var current: NSError? = error as NSError
        while let ns = current, seen < 8 {
            seen += 1
            switch (ns.domain, ns.code) {
            case ("NSSQLiteErrorDomain", 13):        return true   // SQLITE_FULL
            case (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue): return true
            case (NSPOSIXErrorDomain, Int(ENOSPC)):  return true
            default: break
            }
            if let sqlite = ns.userInfo["NSSQLiteErrorDomain"] as? Int, sqlite == 13 { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// System Settings → General → Storage: the one place the user can actually free space. Falls
    /// back to opening System Settings if the deep link isn't honored.
    @MainActor
    static func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }
}
