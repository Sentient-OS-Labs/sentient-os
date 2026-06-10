//
//  ModelLocator.swift
//  Sentient OS macOS
//
//  Finds the on-device model file (gemma-4-E4B-it.litertlm) without per-machine hardcoded
//  paths. Resolution order:
//   1. SENTIENT_MODEL_PATH env override (headless/self-test runs)
//   2. The app bundle (so a bundled build "just works")
//   3. Application Support/SentientOS/Models/ (where the onboarding downloader will put it)
//   4. DEBUG only: the repo root next to the .xcodeproj — the standard dev checkout layout —
//      located via #filePath, so it works on every dev's Mac.
//

import Foundation

enum ModelLocator {
    static let fileName = "gemma-4-E4B-it.litertlm"

    /// Absolute path to the model, or nil if it can't be found on this machine.
    static func resolve() -> String? {
        let fm = FileManager.default

        if let env = ProcessInfo.processInfo.environment["SENTIENT_MODEL_PATH"],
           fm.fileExists(atPath: env) {
            return env
        }

        if let bundled = Bundle.main.path(forResource: "gemma-4-E4B-it", ofType: "litertlm") {
            return bundled
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentientOS/Models/\(fileName)").path
        if fm.fileExists(atPath: appSupport) { return appSupport }

        #if DEBUG
        // This file lives at <repo>/Sentient OS macOS/ModelLocator.swift; the model sits at the
        // repo root next to the .xcodeproj (per the team onboarding checklist).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/<repo>/Sentient OS macOS/
            .deletingLastPathComponent()   // …/<repo>/
        let dev = repoRoot.appendingPathComponent(fileName).path
        if fm.fileExists(atPath: dev) { return dev }
        #endif

        return nil
    }
}
