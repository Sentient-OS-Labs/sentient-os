// UI-free peer for native transport/readiness tests. Never tracks windows or launches apps.
import Foundation
nonisolated enum NativeHelperPermissionNote {
    static func withGuide(appURL: URL,
        operation: @Sendable () async throws -> NativePermissionReadiness.Snapshot) async throws -> NativePermissionReadiness.Snapshot {
        try await operation()
    }
}
