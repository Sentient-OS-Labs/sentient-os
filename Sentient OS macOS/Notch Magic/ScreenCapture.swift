//
//  ScreenCapture.swift
//  Sentient OS macOS
//
//  Grabs a still of EVERY display at the moment the user invokes a command, so computer use SEES
//  exactly what they're looking at — "finish this form", "reply to this", "complete this" all resolve
//  against the real pixels, on whichever screen they're on. The frames are attached to the codex
//  prompt (`codex exec -i <file>...` — the flag is variadic).
//
//  Uses `/usr/sbin/screencapture` (no shutter sound, JPEG), one invocation per display so the order is
//  guaranteed by its own contract (`-D 1` IS the main display) — the prompt tells codex the first frame
//  is the main screen. Rides Sentient's own Screen Recording grant (one grant covers all displays); no
//  grant → returns [] and the command runs text-only (never prompts here). The files are short-lived
//  temps: the caller passes their paths to codex, then calls `discard`. Note: the screens go to the
//  user's OWN codex/OpenAI (the same trust boundary computer use already crosses).
//  Doc: the two Documentation - Sidekick - *.md files in this folder.
//
//  Key methods: grab() -> [URL] · grabDisplayUnderCursor() -> URL? · downscaledJPEG(_:maxLongEdge:) · discard(_:).
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

enum ScreenCapture {
    /// Resolve the active app's frontmost ordinary window before the notch becomes key. Quartz
    /// window/display bounds share a coordinate space, including displays above/left of primary.
    @MainActor static func summaryDisplay() -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: {
               ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                   && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
           }), let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), !rect.isEmpty {
            let ranked = screens.map { screen -> (CGDirectDisplayID, CGFloat) in
                let intersection = CGDisplayBounds(screen.displayID).intersection(rect)
                return (screen.displayID, intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            if let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        }
        return (screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? screens.first)?.displayID
    }

    nonisolated enum SummaryFailure: LocalizedError, Equatable {
        case permission, displayGone, capture
        var errorDescription: String? {
            switch self {
            case .permission: "Allow Screen Recording, then return to the content you want summarized and try again."
            case .displayGone: "That display is no longer available. Close this window and summarize your current screen."
            case .capture: "Couldn’t capture this window. Bring it into view and try again."
            }
        }
    }

    /// One memory-only still of the selected document window, even if another app covers it.
    /// Without a window target, capture the chosen display excluding our transient overlays.
    @MainActor static func summaryImage(displayID: CGDirectDisplayID, windowPID: pid_t? = nil,
                                        windowTitle: String? = nil, windowFrame: CGRect? = nil,
                                        maxLongEdge: Int = 3_072) async throws -> Data {
        guard Permissions.hasScreenRecording() else { throw SummaryFailure.permission }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw SummaryFailure.displayGone }
            let excluded = Set(NSApp.windows.filter {
                ["sentient.notch", "sentient.summary", "sentient.proofread"].contains($0.identifier?.rawValue ?? "")
            }.map { CGWindowID($0.windowNumber) })
            // Exclude the app dynamically, except for its ordinary windows. A second Summary
            // opening while capture is pending must not appear inside the first screenshot.
            let ownApps = content.applications.filter { $0.processID == getpid() }
            let ordinaryWindows = content.windows.filter {
                $0.owningApplication?.processID == getpid() && !excluded.contains($0.windowID)
            }
            let filter: SCContentFilter
            if let windowPID, windowTitle != nil || windowFrame != nil {
                let candidates = content.windows.filter {
                    $0.owningApplication?.processID == windowPID && !excluded.contains($0.windowID)
                }
                let selected = SummaryWindowSelection.choose(candidates.map {
                    .init(id: $0.windowID, pid: windowPID, title: $0.title, frame: $0.frame, layer: $0.windowLayer)
                }, pid: windowPID, title: windowTitle, frame: windowFrame,
                   appName: NSRunningApplication(processIdentifier: windowPID)?.localizedName)
                guard let selected, let window = candidates.first(where: { $0.windowID == selected }) else {
                    Log("summary screenshot unavailable: ambiguous or missing target window (candidates=\(candidates.count))")
                    throw SummaryFailure.capture
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else if ownApps.isEmpty {
                filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
            } else {
                filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: ordinaryWindows)
            }
            let config = SCStreamConfiguration()
            let width = filter.contentRect.width * CGFloat(filter.pointPixelScale)
            let height = filter.contentRect.height * CGFloat(filter.pointPixelScale)
            let scale = min(1, CGFloat(max(1, maxLongEdge)) / max(width, height, 1))
            config.width = max(1, Int(width * scale)); config.height = max(1, Int(height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                let out = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw SummaryFailure.capture }
                CGImageDestinationAddImage(destination, frame, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(destination), out.length > 0, out.length <= 4_500_000 else { throw SummaryFailure.capture }
                return out as Data
            }.value
        } catch is CancellationError { throw CancellationError() }
        catch let failure as SummaryFailure { throw failure }
        catch {
            if !Permissions.hasScreenRecording() { throw SummaryFailure.permission }
            throw SummaryFailure.capture
        }
    }

    /// Capture every display to temp JPEGs for computer-use context — the MAIN display always first
    /// (`screencapture -D 1` is the main display by its own contract; a per-display failure just drops
    /// that frame). Empty = no Screen Recording grant or nothing captured (the command then runs
    /// without screenshots). Never prompts.
    static func grab() async -> [URL] {
        guard Permissions.hasScreenRecording() else {
            CaptureDiagnostics(source: .display).record(.skipped, failure: .init(kind: .permission, code: nil, detail: .permissionDenied, stage: .appState), fields: ["sentient_screen_preflight": "false"])
            Log("📸 screenshot skipped — no Screen Recording grant")
            return []
        }
        let tag = UUID().uuidString
        var shots: [URL] = []
        for display in 1...max(NSScreen.screens.count, 1) {
            if Task.isCancelled { break }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sentient-shot-\(tag)-\(display).jpg")
            //  -x : silent (no camera sound)   -t jpg : compact vs a multi-MB Retina PNG
            let ok = await capture(display: display, to: url)
            if ok, FileManager.default.fileExists(atPath: url.path) {
                shots.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard !shots.isEmpty else {
            Log("📸 screenshot capture failed")
            return []
        }
        let kb = shots.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) / 1024) }
        Log("📸 \(shots.count) display screenshot\(shots.count == 1 ? "" : "s") captured (\(kb) KB)")   // sizes only — never the pixels
        return shots
    }

    /// ONE display: the one under the cursor (Double Tap's proxy for keyboard focus), the main
    /// display when the cursor is on none. Same `screencapture` contract as `grab()`; the NSScreen
    /// order is only guaranteed to match `-D` for the main display (index 0 ↔ `-D 1`).
    /// Magic Reply supplies a remembered display ID: resolve it through ScreenCaptureKit instead
    /// of guessing a screencapture index, and exclude the retracting notch from that image.
    static func grabDisplayUnderCursor(displayID: CGDirectDisplayID? = nil) async -> URL? {
        guard Permissions.hasScreenRecording() else {
            CaptureDiagnostics(source: .display).record(.skipped, failure: .init(kind: .permission, code: nil, detail: .permissionDenied, stage: .appState), fields: ["sentient_screen_preflight": "false"])
            Log("📸 screenshot skipped — no Screen Recording grant")
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-shot-\(UUID().uuidString).jpg")
        if let displayID {
            do {
                let image = try await summaryImage(displayID: displayID, maxLongEdge: DoubleTap.screenshotLongEdge)
                try Task.checkCancellation()
                try image.write(to: url, options: .atomic)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        let mouse = NSEvent.mouseLocation
        let display = (NSScreen.screens.firstIndex { $0.frame.contains(mouse) } ?? 0) + 1
        let ok = await capture(display: display, to: url)
        guard ok, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            Log("📸 screenshot capture failed (display \(display))")
            return nil
        }
        return url
    }

    /// A capture shrunk to `maxLongEdge` pixels as JPEG, via an ImageIO thumbnail so the full Retina
    /// frame is never decoded. A model downscales past ~2000 px anyway; shrinking first only saves
    /// upload time (a Retina capture is multi-MB; this is a few hundred KB).
    static func downscaledJPEG(_ url: URL, maxLongEdge: Int, quality: Double = 0.8) -> Data? {
        func failed(_ detail: NativeComputerUseFailure.Detail) -> Data? {
            CaptureDiagnostics(source: .display).record(.failed,
                failure: .init(kind: .capture, code: nil, detail: detail, stage: .imageDecode))
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return failed(.invalidImage) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return failed(.invalidImage) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return failed(.imageEncodingFailed) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return failed(.imageEncodingFailed) }
        return out as Data
    }

    /// Delete the temp frames once codex has consumed them (safe on empty).
    static func discard(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// A cancellable process with bounded termination, followed by actual image validation.
    /// Exit status zero or a file's existence alone does not establish a usable screenshot.
    private static func capture(display: Int, to url: URL) async -> Bool {
        let diagnostics = CaptureDiagnostics(source: .display)
        let started = Date()
        var fields = ["display_index": String(display), "display_count": String(NSScreen.screens.count),
                      "sentient_screen_preflight": String(Permissions.hasScreenRecording())]
        do {
            let out = try await CodexCLI.executeAsync(binary: "/usr/sbin/screencapture",
                args: ["-x", "-t", "jpg", "-D", String(display), url.path], stdinText: nil, cwd: nil,
                timeout: 5, includeCustomProviderKey: false)
            try Task.checkCancellation()
            fields["duration_ms"] = String(Int(Date().timeIntervalSince(started) * 1000))
            guard out.status == 0 else {
                var failure = NativeComputerUseFailure.classify(out.stderr, stage: .appState)
                failure.exitCode = Int(out.status)
                diagnostics.record(.failed, failure: failure, fields: fields)
                return false
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                diagnostics.record(.failed, failure: .init(kind: .capture, code: nil, detail: .missingImage, stage: .imageDecode), fields: fields)
                return false
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
                diagnostics.record(.failed, failure: .init(kind: .capture, code: nil, detail: .invalidImage, stage: .imageDecode), fields: fields)
                return false
            }
            fields["image_valid"] = "true"
            fields["image_width"] = String(image.width); fields["image_height"] = String(image.height)
            diagnostics.record(.passed, fields: fields)
            return true
        } catch {
            fields["duration_ms"] = String(Int(Date().timeIntervalSince(started) * 1000))
            let timedOut: Bool
            if case CodexCLI.CLIError.timedOut = error { timedOut = true } else { timedOut = false }
            fields["watchdog_fired"] = String(timedOut)
            var failure = NativeComputerUseFailure(kind: timedOut ? .timeout : .connection, code: nil,
                detail: timedOut ? .requestTimedOut : .launchFailed, stage: .transport)
            failure.recordSystemError(error)
            diagnostics.record(error is CancellationError || Task.isCancelled ? .cancelled : .failed, failure: failure, fields: fields)
            return false
        }
    }
}
