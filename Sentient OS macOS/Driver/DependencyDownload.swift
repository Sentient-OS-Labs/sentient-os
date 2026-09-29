// A cancellable dependency download with byte progress and an HTTP success check.
// Shared by the CUA and OpenAI installers; never buffers an installer in memory.
// Doc: Driver/Documentation - Native Computer Use.md

import Foundation

nonisolated enum DependencyDownload {
    enum DownloadError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self { case .http(let status): "Download failed (HTTP \(status)). Try again." }
        }
    }

    static func run(_ url: URL, to destination: URL, timeout: TimeInterval = 900,
                    onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        configuration.timeoutIntervalForRequest = 60
        let delegate = DependencyDownloadProgress(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }
}

/// URLSession retains this delegate for its async download. Byte counts are real; an unknown
/// content length stays indeterminate. Only the UI consumer hops to the main actor.
private final class DependencyDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed: Result<Void, Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let completed {
            lock.unlock()
            continuation.resume(with: completed)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0
            ? min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                throw DependencyDownload.DownloadError.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            // The delegate's temporary file is only valid until this callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
