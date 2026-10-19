#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Bounded visual acceptance recording. No display capture, audio, cursor, provider or frame
/// array. The animation closure runs on MainActor and must honor cooperative cancellation.
@MainActor enum SidekickUIRecording {
    nonisolated enum Failure: String, Error {
        case configuration, permission, ownWindowUnavailable, writerSetup, startTimeout
        case stopTimeout, finishTimeout, captureFailed, invalidFrame, unavailableFrame
        case nonmonotonicFrame, writerAppend, writerFinish, noFrames, writerBackpressure, cancelled
    }

    static func record(window: NSWindow, url: URL, duration: Double = 4,
                       animate: @escaping @MainActor () async -> Void) async throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SENTIENT_SELFTEST"] == "sidekickapp", environment["LAB_SIDEKICK_STAGE"] == "ui",
              let rootPath = environment["LAB_SIDEKICK_ROOT"], rootPath.hasPrefix("/"),
              duration.isFinite, (0.5...4.5).contains(duration), url.isFileURL, url.pathExtension == "mp4",
              window.isVisible, window.windowNumber > 0 else { throw Failure.configuration }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard root == root.resolvingSymlinksInPath(), root.lastPathComponent.hasPrefix("sentient-sidekick-app-"),
              try String(contentsOf: root.appendingPathComponent(".sidekick-app-fixture"), encoding: .utf8) == "1\n",
              url.standardizedFileURL == url.resolvingSymlinksInPath(), url.standardizedFileURL.path.hasPrefix(root.path + "/"),
              !FileManager.default.fileExists(atPath: url.path) else { throw Failure.configuration }
        try Task.checkCancellation()
        // Stage Manager can remove a normal-level window from live updates while it remains
        // isVisible. Keep only this fixture window in front for the bounded clip, then restore
        // its original level. No desktop, Stage Manager or accessibility setting is changed.
        let originalLevel = window.level
        window.level = .floating
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        defer { window.level = originalLevel }
        try await Task.sleep(for: .milliseconds(150))
        window.displayIfNeeded()
        let available = try await SCShareableContent.currentProcess
        guard let owned = available.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
        }) else { throw Failure.ownWindowUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let scale = Double(filter.pointPixelScale)
        guard scale.isFinite, scale > 0, owned.frame.width > 0, owned.frame.height > 0 else { throw Failure.configuration }
        // H.264 encodes even dimensions. At most one padding pixel is added at the trailing edge.
        let width = (Int(ceil(owned.frame.width * scale)) + 1) / 2 * 2
        let height = (Int(ceil(owned.frame.height * scale)) + 1) / 2 * 2
        guard width <= 4096, height <= 4096 else { throw Failure.configuration }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false; configuration.includeChildWindows = false
        configuration.capturesAudio = false; configuration.captureMicrophone = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let sink: Writer
        do { sink = try Writer(url: url, width: width, height: height) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        var animation: Task<Void, Never>?
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await callback(timeout: 5, failure: .startTimeout) { finish in
                stream.startCapture { error in finish(error.map { .failure($0) } ?? .success(())) }
            }
            // Start the animation only after an actual frame reached the writer. This provides
            // the initial still state even when capture startup takes longer than expected.
            let firstDeadline = ProcessInfo.processInfo.systemUptime + 2
            while try await sink.snapshot().written == 0 {
                guard ProcessInfo.processInfo.systemUptime < firstDeadline else { throw Failure.noFrames }
                try await Task.sleep(for: .milliseconds(15))
            }
            let started = ProcessInfo.processInfo.systemUptime
            animation = Task { @MainActor in
                guard !Task.isCancelled else { return }
                await animate()
            }
            while ProcessInfo.processInfo.systemUptime - started < duration {
                try Task.checkCancellation()
                guard window.isVisible else { throw Failure.ownWindowUnavailable }
                _ = try await sink.snapshot()
                try await Task.sleep(for: .milliseconds(20))
            }
            animation?.cancel()
            try await callback(timeout: 5, failure: .stopTimeout) { finish in
                stream.stopCapture { error in finish(error.map { .failure($0) } ?? .success(())) }
            }
            try stream.removeStreamOutput(sink, type: .screen)
            let statistics = try await sink.finish(duration: duration)
            guard statistics.written >= 2, let first = statistics.first, let last = statistics.last,
                  statistics.completed else { throw Failure.noFrames }
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard bytes > 0 else { throw Failure.writerFinish }
            return ["file": url.lastPathComponent, "capture_method": "desktop_independent_own_window",
                "window_id": owned.windowID, "owning_process_id": getpid(),
                "width": width, "height": height, "requested_fps": 60, "requested_duration": duration,
                "recording_wall_seconds": ProcessInfo.processInfo.systemUptime - started,
                "received_frames": statistics.received, "complete_frames": statistics.complete,
                "written_frames": statistics.written, "backpressure_dropped_frames": statistics.dropped,
                "noncontent_frames": statistics.noncontent, "terminal_repeat_frame": statistics.repeated,
                "frame_status_counts": statistics.statusCounts,
                "initial_unavailable_frames": statistics.initialUnavailable,
                "postfirst_unavailable_frames": statistics.postfirstUnavailable,
                "window_temporarily_floating": true,
                "first_pts_seconds": first.seconds, "first_pts_value": first.value, "first_pts_timescale": first.timescale,
                "last_pts_seconds": last.seconds, "last_pts_value": last.value, "last_pts_timescale": last.timescale,
                "media_duration_seconds": statistics.end.map { CMTimeSubtract($0, first).seconds } ?? 0,
                "writer_completed": statistics.completed, "bytes": bytes]
        } catch {
            animation?.cancel()
            // Cleanup intentionally ignores task cancellation, but still has its own deadlines.
            // Writer mutation/abort is queued after any in-flight append, never concurrent with it.
            try? await callback(timeout: 5, failure: .stopTimeout, cancellable: false) { finish in
                stream.stopCapture { error in finish(error.map { .failure($0) } ?? .success(())) }
            }
            try? stream.removeStreamOutput(sink, type: .screen)
            let statistics = await sink.diagnosticSnapshot()
            await sink.abort()
            try? FileManager.default.removeItem(at: url)
            // Fixed categories and counts only, never sample contents, window titles or errors'
            // free-form descriptions. Preserve why capture failed before deleting partial media.
            var failureReceipt: [String: Any] = ["reason": (error as? Failure)?.rawValue ?? "system_error",
                "window_id": owned.windowID, "owning_process_id": getpid(),
                "window_visible": window.isVisible,
                "window_occlusion_visible": window.occlusionState.contains(.visible),
                "window_temporarily_floating": true]
            if let statistics {
                failureReceipt["frame_status_counts"] = statistics.statusCounts
                failureReceipt["received_frames"] = statistics.received
                failureReceipt["complete_frames"] = statistics.complete
                failureReceipt["written_frames"] = statistics.written
                failureReceipt["backpressure_dropped_frames"] = statistics.dropped
                failureReceipt["initial_unavailable_frames"] = statistics.initialUnavailable
                failureReceipt["postfirst_unavailable_frames"] = statistics.postfirstUnavailable
            }
            if let data = try? JSONSerialization.data(withJSONObject: failureReceipt, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: url.deletingPathExtension().appendingPathExtension("failure.json"), options: .atomic)
            }
            throw error
        }
    }

    nonisolated private struct Statistics: Sendable {
        var received = 0, complete = 0, written = 0, dropped = 0, noncontent = 0
        var initialUnavailable = 0, postfirstUnavailable = 0
        var statusCounts: [String: Int] = [:]
        var first: CMTime?, last: CMTime?, end: CMTime?
        var repeated = false, completed = false
    }

    /// Only this serial queue touches writer/input/sample/statistics. The capture framework
    /// owns its small queue; this object retains one last frame, not an in-memory movie.
    nonisolated private final class Writer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "ai.sentient.sidekick-ui-recording", qos: .userInitiated)
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private var statistics = Statistics()
        private var failure: Failure?
        private var accepting = true
        private var sessionStarted = false
        private var lastSample: CMSampleBuffer?

        init(url: URL, width: Int, height: Int) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: min(24_000_000, max(8_000_000, width * height * 6)),
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.writerSetup }
            writer.add(input)
            guard writer.startWriting() else { throw Failure.writerSetup }
            super.init()
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard accepting, failure == nil, type == .screen else { return }
            statistics.received += 1
            guard sample.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else {
                failure = .invalidFrame; return
            }
            let statusName: String
            switch status {
            case .complete: statusName = "complete"
            case .idle: statusName = "idle"
            case .blank: statusName = "blank"
            case .suspended: statusName = "suspended"
            case .started: statusName = "started"
            case .stopped: statusName = "stopped"
            @unknown default: statusName = "unknown"
            }
            statistics.statusCounts[statusName, default: 0] += 1
            switch status {
            case .idle, .started, .stopped: statistics.noncontent += 1; return
            case .blank, .suspended:
                if statistics.written == 0 {
                    // The compositor may first announce a blank/suspended surface. Nothing is
                    // encoded and animation cannot begin until a real frame is written. The
                    // existing two-second first-frame deadline still rejects persistent loss.
                    statistics.initialUnavailable += 1
                } else {
                    statistics.postfirstUnavailable += 1
                    failure = .unavailableFrame
                }
                return
            case .complete: break
            @unknown default: failure = .invalidFrame; return
            }
            statistics.complete += 1
            let timestamp = sample.presentationTimeStamp
            guard timestamp.isNumeric, CMSampleBufferGetImageBuffer(sample) != nil else { failure = .invalidFrame; return }
            if let last = statistics.last, CMTimeCompare(timestamp, last) <= 0 { failure = .nonmonotonicFrame; return }
            guard writer.status == .writing else { failure = .writerAppend; return }
            if !sessionStarted { writer.startSession(atSourceTime: timestamp); sessionStarted = true }
            guard input.isReadyForMoreMediaData else { statistics.dropped += 1; return }
            guard input.append(sample) else { failure = .writerAppend; return }
            statistics.written += 1
            if statistics.first == nil { statistics.first = timestamp }
            statistics.last = timestamp
            lastSample = sample
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            queue.async { if self.accepting { self.failure = .captureFailed } }
        }
        func snapshot() async throws -> Statistics {
            try await SidekickUIRecording.callback(timeout: 2, failure: .writerAppend) { finish in
                self.queue.async {
                    if let failure = self.failure { finish(.failure(failure)) }
                    else { finish(.success(self.statistics)) }
                }
            }
        }
        func diagnosticSnapshot() async -> Statistics? {
            try? await SidekickUIRecording.callback(timeout: 2, failure: .writerAppend, cancellable: false) { finish in
                self.queue.async { finish(.success(self.statistics)) }
            }
        }
        func finish(duration: Double) async throws -> Statistics {
            try await SidekickUIRecording.callback(timeout: 5, failure: .finishTimeout) { finish in
                self.queue.async {
                    self.accepting = false
                    if let failure = self.failure { finish(.failure(failure)); return }
                    guard let first = self.statistics.first, let last = self.statistics.last,
                          let sample = self.lastSample else { finish(.failure(Failure.noFrames)); return }
                    let desiredEnd = CMTimeAdd(first, CMTime(seconds: duration, preferredTimescale: 60_000))
                    // ScreenCaptureKit sends changed frames. A final duplicate extends the last
                    // still state to the requested duration without inventing animation frames.
                    let ending = CMTimeMaximum(desiredEnd, CMTimeAdd(last, CMTime(value: 1, timescale: 60)))
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                        presentationTimeStamp: ending, decodeTimeStamp: .invalid)
                    var repeated: CMSampleBuffer?
                    guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &repeated) == noErr,
                          let repeated else { finish(.failure(Failure.invalidFrame)); return }
                    guard self.input.isReadyForMoreMediaData else { finish(.failure(Failure.writerBackpressure)); return }
                    guard self.input.append(repeated) else { finish(.failure(Failure.writerAppend)); return }
                    self.statistics.repeated = true
                    self.statistics.end = CMTimeAdd(ending, timing.duration)
                    self.lastSample = nil
                    self.input.markAsFinished()
                    self.writer.finishWriting {
                        self.queue.async {
                            self.statistics.completed = self.writer.status == .completed
                            if self.statistics.completed { finish(.success(self.statistics)) }
                            else { finish(.failure(Failure.writerFinish)) }
                        }
                    }
                }
            }
        }
        func abort() async {
            _ = try? await SidekickUIRecording.callback(timeout: 3, failure: .finishTimeout, cancellable: false) { (finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
                self.queue.async {
                    self.accepting = false; self.lastSample = nil
                    self.writer.cancelWriting()
                    finish(.success(()))
                }
            }
        }
    }

    /// One completion wins against API completion, timeout and cancellation. This avoids task
    /// groups waiting forever for a system completion handler that never arrives.
    nonisolated private final class Gate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var finished = false
        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
        func complete(_ result: Result<Value, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; self.result = result
            let continuation = continuation; self.continuation = nil
            lock.unlock(); continuation?.resume(with: result)
        }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }
    nonisolated private static func callback<Value: Sendable>(timeout: Double, failure: Failure, cancellable: Bool = true,
        begin: @escaping @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let gate = Gate<Value>()
        let operation = {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                gate.install(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { gate.complete(.failure(failure)) }
                if !gate.isFinished { begin { gate.complete($0) } }
            }
        }
        if !cancellable { return try await operation() }
        return try await withTaskCancellationHandler(operation: operation,
            onCancel: { gate.complete(.failure(CancellationError())) })
    }
}
#endif
