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

enum ScreenCapture {
    /// Capture every display to temp JPEGs for computer-use context — the MAIN display always first
    /// (`screencapture -D 1` is the main display by its own contract; a per-display failure just drops
    /// that frame). Empty = no Screen Recording grant or nothing captured (the command then runs
    /// without screenshots). Never prompts.
    static func grab() async -> [URL] {
        guard Permissions.hasScreenRecording() else {
            Log("📸 screenshot skipped — no Screen Recording grant")
            return []
        }
        let tag = UUID().uuidString
        var shots: [URL] = []
        for display in 1...max(NSScreen.screens.count, 1) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sentient-shot-\(tag)-\(display).jpg")
            //  -x : silent (no camera sound)   -t jpg : compact vs a multi-MB Retina PNG
            let ok = await runCapture(["-x", "-t", "jpg", "-D", "\(display)", url.path])
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
    static func grabDisplayUnderCursor() async -> URL? {
        guard Permissions.hasScreenRecording() else {
            Log("📸 screenshot skipped — no Screen Recording grant")
            return nil
        }
        let mouse = NSEvent.mouseLocation
        let display = (NSScreen.screens.firstIndex { $0.frame.contains(mouse) } ?? 0) + 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-shot-\(UUID().uuidString).jpg")
        let ok = await runCapture(["-x", "-t", "jpg", "-D", "\(display)", url.path])
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Delete the temp frames once codex has consumed them (safe on empty).
    static func discard(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Run `screencapture` off the main actor; true iff it exited cleanly. A 5s watchdog kills a
    /// wedged capture (house rule: no un-watchdogged Process) — the run start awaits this, so a hang
    /// here would freeze the command where STOP can't reach; on timeout the command just runs text-only.
    private static func runCapture(_ args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let watchdog = DispatchWorkItem { [weak p] in p?.terminate() }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
                    p.waitUntilExit()
                    watchdog.cancel()
                    cont.resume(returning: p.terminationStatus == 0)
                } catch {
                    Log("📸 screencapture launch failed — \(error.localizedDescription)")
                    cont.resume(returning: false)
                }
            }
        }
    }
}
