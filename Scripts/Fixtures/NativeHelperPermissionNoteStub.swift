// UI-free peer for native transport/readiness tests. Never tracks windows or launches apps.
import Foundation
nonisolated enum NativeHelperPermissionNote {
    static func withGuide<Result: Sendable>(appURL: URL,
        operation: @Sendable () async throws -> Result) async throws -> Result {
        try await operation()
    }
}
