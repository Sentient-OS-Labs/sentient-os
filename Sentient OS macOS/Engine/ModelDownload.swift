//
//  ModelDownload.swift
//  Sentient OS macOS
//
//  Downloads the on-device model (gemma-4-E4B-it.litertlm, 3.66 GB) from Hugging Face —
//  anonymously, no token — into Application Support/SentientOS/Models/, the exact slot
//  ModelLocator resolves. Strictly an onboarding affair: AppState kicks it 2 seconds after the
//  launch that follows the Full Disk Access grant (the one onboarding step that forces a
//  relaunch), so the model is usually most of the way down before the user reaches Start
//  Analysis; OnboardingModelDownloadView covers the remainder.
//
//  The transfer: 8 parallel HTTP Range chunks (~85% of line speed vs ~50% single-stream,
//  measured live — see Our_Stuff/Other Stuff/Tested - Best Model Download Arch.md), each chunk
//  appending to its own part file whose SIZE is its resume bookmark — a quit or crash resumes
//  mid-chunk, never from zero. Parts are then assembled + SHA-256-verified in one streamed pass
//  before the atomic move into place, so a silently-corrupted model can never reach the engine.
//
//  Key entry point: ModelDownload.shared.kickIfNeeded() — a no-op when a model is already
//  findable (dev checkouts, env override, bundle) or a download is in flight; restartable from
//  .failed (the downloading screen's Try Again, or simply the next launch's kick).
//

import Foundation
import CryptoKit

// MARK: - The job (what to fetch, where to land it)

/// One download target. A struct (not constants) so a self-test can run the same machinery
/// against a small file; production values are the only ones the app ever uses.
struct ModelDownloadJob {
    let url: URL
    let sha256: String     // lowercase hex — HF's published LFS hash for the file
    let bytes: Int64
    let modelsDir: URL     // parts + staging live in `.download/` inside it
    let fileName: String

    var destination: URL { modelsDir.appendingPathComponent(fileName) }
    var staging: URL { modelsDir.appendingPathComponent(".download", isDirectory: true) }

    /// The real model, from the official litert-community repo (license-clean; re-hosting Gemma
    /// ourselves would make us the redistributor). Hash + size verified against both HF's LFS
    /// metadata and a local checkout on 2026-07-10.
    static let production = ModelDownloadJob(
        url: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
        sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
        bytes: 3_659_530_240,
        modelsDir: URL.sentientSupport.appendingPathComponent("Models", isDirectory: true),
        fileName: ModelLocator.fileName)
}

// MARK: - The observable (what the UI renders)

@MainActor
@Observable
final class ModelDownload {

    static let shared = ModelDownload()

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying              // parts done; assembling + SHA-256 (seconds)
        case ready                  // model on disk, verified — ModelLocator resolves it
        case failed(String)         // user-facing sentence for the downloading screen
    }

    private(set) var phase: Phase = .idle
    private(set) var bytesDone: Int64 = 0
    let bytesTotal = ModelDownloadJob.production.bytes

    /// True while onboarding's full-screen downloading view is up — the corner whisper
    /// (ModelDownloadWhisper) yields so the signature bar never shows twice on one screen.
    var fullScreenVisible = false

    private init() {}

    /// Start (or resume) the model download if this Mac actually needs one. Safe to call from
    /// anywhere, any number of times: a model findable by ModelLocator (dev repo root, env
    /// override, bundle, an earlier download) short-circuits to .ready, and an in-flight
    /// download is never doubled. `.failed` re-kicks — that's the Try Again path.
    func kickIfNeeded() {
        switch phase {
        case .downloading, .verifying, .ready: return
        case .idle, .failed: break
        }
        guard ModelLocator.resolve() == nil else { phase = .ready; return }

        let job = ModelDownloadJob.production
        // Disk pre-check: the peak footprint is parts + the assembled copy of the tail (~4.2 GB
        // fresh), less whatever staging already holds. Failing here beats a cryptic mid-write error.
        let free = (try? URL.sentientSupport.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        if free < (job.bytes - ModelFetch.stagedBytes(of: job)) + 1_500_000_000 {
            fail("Your Mac is low on disk space. Free up about 6 GB, then hit Try Again.", type: "disk_space")
            return
        }

        Log("ModelDownload: starting (\(ModelFetch.stagedBytes(of: job) / 1_048_576) MB already staged)")
        phase = .downloading
        bytesDone = 0
        Task.detached(priority: .utility) { await Self.run(job) }
    }

    // MARK: Worker → UI (the only writers of the observable state)

    fileprivate func report(bytes: Int64) {
        if case .downloading = phase { bytesDone = min(bytes, bytesTotal) }
    }

    fileprivate func enterVerifying() {
        bytesDone = bytesTotal
        phase = .verifying
    }

    fileprivate func finish(elapsed: TimeInterval) {
        phase = .ready
        Log(String(format: "ModelDownload: ✓ model verified + installed (%.0fs this run)", elapsed))
        Analytics.signal("Model.downloadCompleted", floatValue: elapsed)
    }

    fileprivate func fail(_ reason: String, type: String) {
        phase = .failed(reason)
        Log("ModelDownload: ✗ failed (\(type)) — \(reason)")
        CrashReporting.captureEvent("model.download.failed", level: .error, tags: ["reason": type])
    }

    // MARK: The retry ladder

    /// One download run: up to 4 full attempts with a growing pause. Retries are cheap — every
    /// finished byte range is already on disk, so an attempt only re-fetches what's missing.
    /// Fatal failures (upstream file changed, checksum, disk) skip the ladder: retrying can't fix
    /// them, and the checksum case has already wiped staging for a clean manual retry.
    private nonisolated static func run(_ job: ModelDownloadJob) async {
        let started = Date()
        var lastError: Error = ModelFetchError.badResponse(0)
        for attempt in 1...4 {
            do {
                try await ModelFetch.downloadParts(job) { bytes in
                    Task { @MainActor in ModelDownload.shared.report(bytes: bytes) }
                }
                await MainActor.run { ModelDownload.shared.enterVerifying() }
                try ModelFetch.assembleAndVerify(job)
                await MainActor.run { ModelDownload.shared.finish(elapsed: Date().timeIntervalSince(started)) }
                return
            } catch let error as ModelFetchError where error.isFatal {
                await MainActor.run { ModelDownload.shared.fail(error.userMessage, type: error.tag) }
                return
            } catch {
                lastError = error
                Log("ModelDownload: attempt \(attempt) failed (\(type(of: error))) — retrying")
                try? await Task.sleep(for: .seconds(8 * attempt))
            }
        }
        let message = (lastError as? ModelFetchError)?.userMessage
            ?? "Sentient could not reach the download server. Check your internet connection, then hit Try Again."
        await MainActor.run {
            ModelDownload.shared.fail(message, type: (lastError as? ModelFetchError)?.tag ?? "network")
        }
    }
}

#if DEBUG
extension ModelDownload {
    /// Preview-only: a detached instance frozen at a given state (never downloads anything).
    static func previewInstance(phase: Phase, bytesDone: Int64 = 0) -> ModelDownload {
        let m = ModelDownload()
        m.phase = phase
        m.bytesDone = bytesDone
        return m
    }
}
#endif

// MARK: - Errors

enum ModelFetchError: Error {
    case upstreamChanged(String)   // server file no longer matches our pinned size/hash
    case checksumMismatch
    case badResponse(Int)
    case shortDelivery             // request completed cleanly but bytes are missing — re-fetch
    case diskWrite(String)

    /// Fatal = the retry ladder can't fix it; stop and tell the user.
    var isFatal: Bool {
        switch self {
        case .upstreamChanged, .checksumMismatch, .diskWrite: return true
        case .badResponse, .shortDelivery: return false
        }
    }

    var userMessage: String {
        switch self {
        case .upstreamChanged:
            return "The model file on the server has changed. Please update Sentient, then try again."
        case .checksumMismatch:
            return "The download finished but did not verify cleanly. Hit Try Again for a fresh download."
        case .diskWrite:
            return "Your Mac ran out of disk space during the download. Free up about 6 GB, then hit Try Again."
        case .badResponse(let code):
            return "The download server had a problem (HTTP \(code)). Try again in a few minutes."
        case .shortDelivery:
            return "The connection kept dropping. Check your internet, then hit Try Again."
        }
    }

    var tag: String {
        switch self {
        case .upstreamChanged: return "upstream_changed"
        case .checksumMismatch: return "checksum_mismatch"
        case .badResponse: return "bad_response"
        case .shortDelivery: return "short_delivery"
        case .diskWrite: return "disk_write"
        }
    }
}

// MARK: - The machinery (HEAD → 8 range chunks → assemble → SHA-256)

enum ModelFetch {

    private static let connections = 8      // measured sweet spot; macOS default is 6

    private struct Chunk {
        let index: Int
        let start: Int64
        let end: Int64                       // inclusive
        var length: Int64 { end - start + 1 }
    }

    /// Bytes already sitting in part files — the resume head start (and the disk-check discount).
    static func stagedBytes(of job: ModelDownloadJob) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: job.staging.path) else { return 0 }
        return names.filter { $0.hasPrefix("part_") }
            .reduce(0) { $0 + partSize(job.staging.appendingPathComponent($1)) }
    }

    private static func partSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// Download every missing byte range into staging part files. Throws on the first chunk that
    /// exhausts its own retries; everything already written stays for the next attempt.
    static func downloadParts(_ job: ModelDownloadJob, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: job.staging, withIntermediateDirectories: true)

        // The staging marker pins which file these parts belong to — if the pinned hash ever
        // changes (an app update pointing at a new model), stale parts are wiped, never mixed.
        let marker = job.staging.appendingPathComponent("expected.sha256")
        if let existing = try? String(contentsOf: marker, encoding: .utf8), existing != job.sha256 {
            Log("ModelDownload: staging belongs to a different model file — wiping")
            try? fm.removeItem(at: job.staging)
            try fm.createDirectory(at: job.staging, withIntermediateDirectories: true)
        }
        try job.sha256.write(to: marker, atomically: true, encoding: .utf8)

        // HEAD: confirm the pinned size still holds and whether ranges are served (they are, on
        // HF — this is the defensive path; no ranges collapses to one whole-file "chunk").
        let rangesOK = try await head(job)
        let n = rangesOK ? Int64(connections) : 1
        let per = (job.bytes + n - 1) / n
        let chunks = stride(from: Int64(0), to: job.bytes, by: Int(per)).enumerated().map { i, s in
            Chunk(index: i, start: s, end: min(s + per - 1, job.bytes - 1))
        }

        // Prime the progress with what's already on disk (the resume head start).
        let counter = ProgressCounter(initial: chunks.reduce(0) { total, c in
            total + min(partSize(part(job, c.index)), c.length)
        }, onProgress: onProgress)
        counter.push()

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = connections
        config.timeoutIntervalForRequest = 60            // stall detector: 60s with no bytes → error → resume
        config.timeoutIntervalForResource = 4 * 3600     // ceiling for one chunk on terrible wifi
        config.waitsForConnectivity = true
        let fetcher = ChunkFetcher(configuration: config) { counter.add($0) }
        defer { fetcher.invalidate() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunk in chunks {
                group.addTask {
                    try await fetchChunk(chunk, job: job, fetcher: fetcher, rangesOK: rangesOK, counter: counter)
                }
            }
            try await group.waitForAll()
        }
        counter.push()
    }

    private static func part(_ job: ModelDownloadJob, _ index: Int) -> URL {
        job.staging.appendingPathComponent("part_\(index)")
    }

    /// One chunk, with its own small retry loop: every retry re-reads the part's size and asks
    /// only for the remaining bytes, so a flaky connection converges instead of starting over.
    private static func fetchChunk(_ chunk: Chunk, job: ModelDownloadJob, fetcher: ChunkFetcher,
                                   rangesOK: Bool, counter: ProgressCounter) async throws {
        let fm = FileManager.default
        let partURL = part(job, chunk.index)
        var lastError: Error = ModelFetchError.shortDelivery
        for attempt in 1...3 {
            var have = partSize(partURL)
            // Oversized (stale plan) or unresumable (no range support) parts start clean.
            if have > chunk.length || (!rangesOK && have > 0) {
                counter.add(-(min(have, chunk.length)))
                try? fm.removeItem(at: partURL)
                have = 0
            }
            if have == chunk.length { return }
            do {
                try await fetcher.fetch(job.url,
                                        range: rangesOK ? (chunk.start + have)...chunk.end : nil,
                                        into: partURL)
                guard partSize(partURL) >= chunk.length else { throw ModelFetchError.shortDelivery }
                return
            } catch let error as ModelFetchError where error.isFatal {
                throw error
            } catch {
                lastError = error
                Log("ModelDownload: chunk \(chunk.index) attempt \(attempt) failed (\(type(of: error)))")
                try? await Task.sleep(for: .seconds(3))
            }
        }
        throw lastError
    }

    /// HEAD the source: 200, the pinned byte size, and whether `Range:` requests are honored.
    private static func head(_ job: ModelDownloadJob) async throws -> Bool {
        var request = URLRequest(url: job.url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelFetchError.badResponse(-1) }
        guard http.statusCode == 200 else { throw ModelFetchError.badResponse(http.statusCode) }
        let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        guard length == job.bytes else {
            throw ModelFetchError.upstreamChanged("Content-Length \(length) ≠ pinned \(job.bytes)")
        }
        return (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").contains("bytes")
    }

    /// Stream the parts, in order, through SHA-256 and into the final file — one pass, never
    /// 3.6 GB in RAM. Parts are deleted as they're consumed (halves the peak disk footprint; the
    /// worst a crash mid-assembly costs is re-fetching the consumed chunks). Only a verified
    /// digest moves the file into ModelLocator's slot.
    static func assembleAndVerify(_ job: ModelDownloadJob) throws {
        let fm = FileManager.default
        let assembled = job.staging.appendingPathComponent("assembled.tmp")
        fm.createFile(atPath: assembled.path, contents: nil)   // truncates a stale leftover
        let out: FileHandle
        do { out = try FileHandle(forWritingTo: assembled) }
        catch { throw ModelFetchError.diskWrite("\(type(of: error))") }
        defer { try? out.close() }

        // Consecutive part files, in index order, until they run out; the byte-size gate below is
        // the real completeness check (a missing part can never verify as the full file).
        var hasher = SHA256()
        var index = 0
        while let reader = try? FileHandle(forReadingFrom: part(job, index)) {
            while let block = try reader.read(upToCount: 8 * 1_048_576), !block.isEmpty {
                hasher.update(data: block)
                do { try out.write(contentsOf: block) }
                catch { try? reader.close(); throw ModelFetchError.diskWrite("\(type(of: error))") }
            }
            try? reader.close()
            try? fm.removeItem(at: part(job, index))
            index += 1
        }
        try? out.close()

        guard partSize(assembled) == job.bytes,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == job.sha256 else {
            try? fm.removeItem(at: job.staging)   // poisoned bytes are worthless — a retry starts clean
            throw ModelFetchError.checksumMismatch
        }

        try? fm.removeItem(at: job.destination)
        do { try fm.moveItem(at: assembled, to: job.destination) }
        catch { throw ModelFetchError.diskWrite("\(type(of: error))") }
        try? fm.removeItem(at: job.staging)
    }
}

// MARK: - Progress aggregation (8 chunks → one number, throttled to the MainActor)

fileprivate final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64
    private var lastPush = Date.distantPast
    private let onProgress: @Sendable (Int64) -> Void

    init(initial: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.total = initial
        self.onProgress = onProgress
    }

    func add(_ n: Int) { add(Int64(n)) }

    func add(_ n: Int64) {
        lock.lock()
        total += n
        let now = Date()
        let due = now.timeIntervalSince(lastPush) > 0.2
        if due { lastPush = now }
        let value = total
        lock.unlock()
        if due { onProgress(value) }
    }

    func push() {
        lock.lock(); let value = total; lastPush = Date(); lock.unlock()
        onProgress(value)
    }
}

// MARK: - One URLSession, many range requests (delegate-routed, append-streaming)

/// Streams N concurrent HTTP requests straight into files, appending — the append is what makes
/// a part file's size double as its resume bookmark. Delegate-based (not AsyncBytes) on purpose:
/// data arrives in ready-made slabs with near-zero CPU, where per-byte async iteration burns a
/// core at these sizes. One instance per download run; `invalidate()` breaks the session→delegate
/// retain cycle when the run ends.
fileprivate final class ChunkFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private struct Transfer {
        let handle: FileHandle
        let expectedStatus: Int
        var cont: CheckedContinuation<Void, Error>?
        var failure: Error?
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private let onBytes: @Sendable (Int) -> Void
    private var session: URLSession!

    init(configuration: URLSessionConfiguration, onBytes: @escaping @Sendable (Int) -> Void) {
        self.onBytes = onBytes
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.finishTasksAndInvalidate() }

    /// One request appended into `file`. `range` nil = whole file (expects 200); otherwise a
    /// `Range:` header (expects 206 — a 200 here would mean the server ignored the range and is
    /// sending the whole body, which must never be appended at an offset).
    func fetch(_ url: URL, range: ClosedRange<Int64>?, into file: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()

        var request = URLRequest(url: url)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.dataTask(with: request)
            lock.lock()
            transfers[task.taskIdentifier] = Transfer(handle: handle,
                                                      expectedStatus: range == nil ? 200 : 206,
                                                      cont: cont)
            lock.unlock()
            task.resume()
        }
    }

    // MARK: URLSessionDataDelegate (serial delegate queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        lock.lock(); let expected = transfers[dataTask.taskIdentifier]?.expectedStatus; lock.unlock()
        if status == expected {
            completionHandler(.allow)
        } else {
            setFailure(ModelFetchError.badResponse(status), for: dataTask.taskIdentifier)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let transfer = transfers[dataTask.taskIdentifier]
        lock.unlock()
        guard let transfer, transfer.failure == nil else { return }
        do {
            try transfer.handle.write(contentsOf: data)
            onBytes(data.count)
        } catch {
            setFailure(ModelFetchError.diskWrite("\(type(of: error))"), for: dataTask.taskIdentifier)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        try? transfer?.handle.close()
        // A stored failure (bad status, disk write) outranks the cancellation error it caused.
        if let failure = transfer?.failure { transfer?.cont?.resume(throwing: failure) }
        else if let error { transfer?.cont?.resume(throwing: error) }
        else { transfer?.cont?.resume(returning: ()) }
    }

    private func setFailure(_ error: Error, for id: Int) {
        lock.lock()
        if transfers[id]?.failure == nil { transfers[id]?.failure = error }
        lock.unlock()
    }
}
