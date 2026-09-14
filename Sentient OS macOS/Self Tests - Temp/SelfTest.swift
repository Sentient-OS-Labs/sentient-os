#if DEBUG
//
//  SelfTest.swift
//  Sentient OS macOS
//
//  The headless eval harness dispatcher: reads SENTIENT_SELFTEST, routes to a test, exits
//  before any window opens. Scaffolding — this whole folder is deleted when the connector
//  work is field-tested (Step 4).
//
//  Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation

enum SelfTest {
    @MainActor static func runIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] else { return }
        Task {
            switch mode {
            case "connectorlab": await ConnectorLab.run()
            default: Log("SELFTEST: unknown mode '\(mode)'")
            }
            exit(0)
        }
    }
}

#endif
