// Offline collaborator for existing subscription regression fixtures. The production hosted
// client and lease behavior are exercised separately by test_hosted_inference_client.py.
import Foundation

nonisolated enum HostedInference {
    enum Purpose: Sendable { case sidekick, background, bootstrap }
    enum Failure: Error { case unavailable; var isUsageLimit: Bool { false } }
    final class Run: Sendable {
        func pause() async throws {}
        func resume() async throws {}
    }
    /// Simulates asynchronous lease/process cleanup after a provider outcome, including the
    /// non-cancellable drain that must retain the foreground task lock until it completes.
    @TaskLocal static var afterOperation: (@Sendable () async -> Void)?
    static func withRun<T: Sendable>(purpose: Purpose,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let result: Result<T, Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        await afterOperation?()
        return try result.get()
    }
}
