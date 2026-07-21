import Foundation

struct ComputerUseSkyInstallCoordinator {
    enum Outcome: Equatable {
        case alreadyReady
        case configOnly
        case fullInstall
    }

    let payloadIsValid: () -> Bool
    let isReady: () -> Bool
    let patchConfig: () throws -> Void
    let performFullInstall: () async throws -> Void

    func install(force: Bool) async throws -> Outcome {
        if !force, payloadIsValid() {
            if isReady() { return .alreadyReady }
            try patchConfig()
            if isReady() { return .configOnly }
        }

        try await performFullInstall()
        return .fullInstall
    }
}
