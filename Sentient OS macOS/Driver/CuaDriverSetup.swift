//
//  CuaDriverSetup.swift
//  Sentient OS macOS  ·  Driver/
//
//  Puts the pinned cua-driver binary on the user's Mac — step 3 of Codex setup (CodexSetup owns
//  the flow; onboarding arms it in the background two minutes into the first analysis).
//
//  The chain, in order, each step able to say no:
//    1. Download the pinned release tarball straight from Cua's GitHub release (~40 MB).
//    2. SHA-256 the bytes against the pin. Upstream's own installer does not checksum; we do.
//    3. Extract ONLY `cua-driver` from it (the tarball also carries SDK artifacts we never run).
//    4. Verify the extracted Mach-O still satisfies a codesign requirement naming Cua AI's team —
//       so we run their signature, unmodified, or nothing.
//    5. Smoke-run `--version` and require the pinned string back: proof it actually executes here.
//    6. Atomic move into `…/SentientOS/CuaDriver/<version>/`, then sweep older versions.
//  Any failure leaves the previous install untouched and the staging directory swept.
//
//  Key entry points: install(force:onLine:) · removeAll()
//
//

import CryptoKit
import Foundation

enum CuaDriverSetup {

    enum Progress: Sendable, Equatable {
        case downloading(Double?), verifying, unpacking, checkingSignature, checkingVersion, installing, ready

        var message: String {
            switch self {
            case .downloading: "Downloading…"
            case .verifying, .checkingSignature, .checkingVersion: "Verifying update…"
            case .unpacking: "Preparing computer use…"
            case .installing: "Finishing up…"
            case .ready: "Computer use is up to date."
            }
        }
    }

    enum SetupError: LocalizedError {
        case download(String), integrity(String), extract(String), signature(String), smoke(String), install(String)
        var errorDescription: String? {
            switch self {
            case .download(let m):  return "Download failed: \(m)"
            case .integrity(let m): return "The Cua driver download did not match its checksum (\(m))."
            case .extract(let m):   return "Couldn't unpack the Cua driver: \(m)"
            case .signature(let m): return "The Cua driver's signature did not verify (\(m))."
            case .smoke(let m):     return "The Cua driver did not run on this Mac (\(m))."
            case .install(let m):   return "Couldn't put the Cua driver in place: \(m)"
            }
        }
    }

    // MARK: The bootstrap

    /// Download, verify, and install the pinned cua-driver. Idempotent: a no-op when the pinned
    /// version is already in place (pass `force` to re-fetch it). Streams human-readable progress to
    /// `onLine`, the same convention as every other setup step.
    static func install(force: Bool = false,
                        onProgress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in },
                        onLine: @escaping @Sendable (String) -> Void) async throws {
        if !force, CuaDriver.isInstalled { onLine("✓ Cua driver already installed"); return }

        let fm = FileManager.default
        let staging = CuaDriver.installRoot.appendingPathComponent(".download-\(UUID().uuidString.prefix(8))",
                                                                   isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1) Download. Whole-file: at ~40 MB a clean retry costs less than resume bookkeeping (the
        //    3.66 GB model is the one that earns chunked resume).
        onLine("Downloading the Cua driver (~\(CuaDriver.tarballBytes / 1_048_576) MB)…")
        onProgress(.downloading(nil))
        let tarball = staging.appendingPathComponent("cua-driver.tar.gz")
        try await download(CuaDriver.tarballURL, to: tarball) { fraction in
            Task { @MainActor in onProgress(.downloading(fraction)) }
        }
        try Task.checkCancellation()

        // 2) The pin. Poisoned bytes stop here, before anything is unpacked or run.
        onLine("Verifying checksum…")
        onProgress(.verifying)
        let digest = try sha256(of: tarball)
        guard digest == CuaDriver.tarballSHA256 else {
            throw SetupError.integrity("expected \(CuaDriver.tarballSHA256.prefix(12))…, got \(digest.prefix(12))…")
        }

        // 3) Just the one member — the SDK dylib and node runtime in the same tarball are for
        //    embedding hosts we are not, and there is no reason to write 48 MB we never load.
        onLine("Unpacking…")
        onProgress(.unpacking)
        let extracted = staging.appendingPathComponent("cua-driver")
        let untar = try await sh("/usr/bin/tar", ["-xzf", tarball.path, "-C", staging.path, "cua-driver"])
        guard untar.status == 0, fm.fileExists(atPath: extracted.path) else {
            throw SetupError.extract(untar.out.lastLine)
        }
        // A file we downloaded ourselves carries no quarantine today; strip it anyway so a future
        // macOS that disagrees can't turn this into a mystery "cannot be opened" at fire time.
        _ = try? await sh("/usr/bin/xattr", ["-d", "com.apple.quarantine", extracted.path])

        // 4) Provenance. The hash proves these are the bytes we pinned; this proves Cua signed them
        //    and nothing has touched the binary since.
        onLine("Checking signature…")
        onProgress(.checkingSignature)
        let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(CuaDriver.signingTeamID)\""
        let verify = try await sh("/usr/bin/codesign",
                                  ["--verify", "--strict", "--test-requirement=\(requirement)", extracted.path])
        guard verify.status == 0 else { throw SetupError.signature(verify.out.lastLine) }

        // 5) It exists, it's Cua's, it's intact — but does it RUN here? One cheap exec answers the
        //    architecture, Gatekeeper, and truncation questions at setup time instead of mid-command.
        onProgress(.checkingVersion)
        let probe = try await sh(extracted.path, ["--version"])
        let reported = probe.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.status == 0, reported == "cua-driver \(CuaDriver.version)" else {
            throw SetupError.smoke(probe.status == 0 ? "reported \"\(reported)\"" : "exit \(probe.status)")
        }

        // 6) Into place. The version directory is built beside the live one and swapped last, so an
        //    interrupted install can never leave a half-written binary where a run would find it.
        let dest = CuaDriver.binaryURL
        try Task.checkCancellation()
        onProgress(.installing)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Same-volume rename atomically replaces even a force-reinstalled binary. Never
            // remove the working destination before its verified replacement is ready.
            guard rename(extracted.path, dest.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch { throw SetupError.install("\(error)") }
        guard CuaDriver.isInstalled else { throw SetupError.install("post-install check failed") }

        do { try CuaDriver.recordInstallation(CuaDriver.version, at: CuaDriver.installRoot) }
        catch { Log("CuaDriverSetup: installation is ready; receipt write failed (\(ErrorLabel(error)))") }
        sweepOtherVersions()
        onProgress(.ready)
        Log("CuaDriverSetup: installed cua-driver \(CuaDriver.version) (verified: sha256 + Cua signature + --version)")
        onLine("✓ Cua driver ready")
    }

    /// Remove every installed driver version — the Uninstall path's explicit sweep. (Uninstall also
    /// removes the whole `SentientOS` support root, so this is belt-and-braces, and the one call a
    /// future "remove the driver" affordance would use.)
    static func removeAll() {
        try? FileManager.default.removeItem(at: CuaDriver.installRoot)
    }

    /// Drop version directories that aren't the pinned one — an app update that bumps the pin
    /// shouldn't leave 60 MB of the previous driver behind forever.
    private static func sweepOtherVersions() {
        let fm = FileManager.default
        let keep = CuaDriver.version
        for name in CuaDriver.installedVersions where name != keep {
            try? fm.removeItem(at: CuaDriver.installRoot.appendingPathComponent(name))
        }
    }

    // MARK: Plumbing

    /// Download with byte progress. The delegate moves the temporary file before returning from
    /// its completion callback, then resumes the awaiting installer.
    private static func download(_ url: URL, to dest: URL,
                                 onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 900   // 15 min ceiling for a ~40 MB transfer
        cfg.timeoutIntervalForRequest = 60
        let delegate = DownloadProgress(destination: dest, onProgress: onProgress)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    delegate.begin(continuation)
                    session.downloadTask(with: url).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.download((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Streamed SHA-256 — the file never lands in memory whole.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reuse the engine-neutral process runner's deadline and cancellation behavior. A wedged
    /// signature check or smoke process cannot hold a command or Uninstall indefinitely.
    @discardableResult
    private static func sh(_ launch: String, _ args: [String]) async throws -> (status: Int32, out: String) {
        let result = try await CodexCLI.executeAsync(binary: launch, args: args, stdinText: nil,
            cwd: nil, timeout: 45,
            extraEnv: ["CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
                       "CUA_TELEMETRY_ENABLED": "false", "CUA_DRIVER_RS_UPDATE_CHECK": "false"])
        return (result.status, result.stdout + result.stderr)
    }

}

/// URLSession retains this delegate for its async download. Byte counts are real; an unknown
/// content length stays indeterminate. Only the UI consumer hops to the main actor.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
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
                throw CuaDriverSetup.SetupError.download("HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)")
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

private extension String {
    /// Last non-empty line — compact error surfacing from multi-line tool output.
    var lastLine: String {
        split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? self
    }
}
