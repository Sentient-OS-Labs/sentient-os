// Installs the approved complete OpenAI helper into Sentient's private Codex home.
// Shares verified archive delivery and atomic publication with the CLI installer.
// Doc: Driver/Documentation - Native Computer Use.md

import Foundation

enum OpenAIComputerUseSetup {
    static var hasInstallationHistory: Bool {
        OpenAIComputerUse.isInstalled
            || FileManager.default.fileExists(atPath: CodexRuntime.receipt.path)
            || FileManager.default.fileExists(atPath: URL.sentientSupport.appendingPathComponent("native-computer-use.json").path)
    }

    static func install(force: Bool = false,
                        onProgress: @escaping @MainActor @Sendable (ComputerUseSetup.Progress) -> Void,
                        onLine: @escaping @Sendable (String) -> Void) async throws {
        onProgress(.downloading(nil))
        try await CodexRuntimeInstall.install(.helper, force: force) { line in
            onLine(line)
            Task { @MainActor in
                if line.hasPrefix("Verifying") { onProgress(.verifying) }
                else if line.hasPrefix("Preparing") { onProgress(.unpacking) }
                else if line.hasPrefix("Finishing") { onProgress(.installing) }
            }
        }
        onProgress(.ready)
    }
}
