//
//  ComputerUseDriver.swift
//  Sentient OS macOS  ·  Driver/
//
//  WHICH driver moves the mouse and types when Sentient acts on the Mac. Two today:
//    · .codex — OpenAI's own computer-use plugin + native helper inside ~/.codex (the shipped
//               path; drives the REAL cursor, takes the foreground, needs the helper's own two
//               TCC grants). Bootstrapped by Cloud/ComputerUseSetup.
//    · .cua   — cua-driver (MIT, trycua/cua): the same actions delivered per-window in the
//               BACKGROUND (no cursor warp, no focus steal), registered with codex as an MCP
//               server. Runs inside Sentient's own TCC chain, so Sentient's grants are the ones
//               that count. Acquired by Driver/CuaDriverSetup.
//
//  Read fresh at fire time (like ComputerUseSpeed) so flipping the dev picker applies to the very
//  next command with no restart. Default = .codex — the experiment never changes what ships until
//  the eval says it should.
//  Producer: the dev tools' driver picker · Consumers: CodexCLI.runAgentCommand (which flags to
//  build) and ComputerUseGate (which grants are REQUIRED).
//
//

import Foundation

enum ComputerUseDriver: String, CaseIterable, Sendable {
    case codex, cua

    /// The UserDefaults key the dev picker writes. A production key from day one (renaming it
    /// later needs a migration), even though only the dev cockpit writes it today.
    static let key = "computerUse.driver"

    /// The live choice. Unknown/absent → `.codex`, the shipped default.
    static var current: ComputerUseDriver {
        ComputerUseDriver(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .codex
    }

    /// Flip the active driver (the dev picker's setter).
    static func select(_ driver: ComputerUseDriver) {
        UserDefaults.standard.set(driver.rawValue, forKey: Self.key)
        Log("ComputerUseDriver: switched to \(driver.rawValue)")
        // Don't leave a daemon running for a driver nobody is using — it holds the user's
        // Accessibility grant and an idle cursor session for nothing. The next cua command starts a
        // fresh one in well under a second.
        if driver != .cua { Task { await CuaDriverHost.shared.stop() } }
    }

    /// The picker's readout.
    var label: String {
        switch self {
        case .codex: "Codex computer use"
        case .cua:   "Cua driver"
        }
    }

    /// One honest line under the picker — what changes for the user when this one drives.
    var note: String {
        switch self {
        case .codex: "OpenAI's helper. Takes over the real cursor and the foreground."
        case .cua:   "Background input: acts inside one window without moving the cursor."
        }
    }
}
