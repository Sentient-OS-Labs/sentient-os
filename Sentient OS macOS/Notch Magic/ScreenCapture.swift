//
//  ScreenCapture.swift
//  Sentient OS macOS
//
//  Grabs a still of the user's screen at the moment they invoke a command, so computer use SEES
//  exactly what they're looking at — "finish this form", "reply to this", "complete this" all resolve
//  against the real pixels. The frame is attached to the codex prompt (`codex exec -i <file>`).
//
//  Uses `/usr/sbin/screencapture` (main display, no shutter sound, JPEG) — it rides Sentient's own
//  Screen Recording grant. No grant → returns nil and the command runs text-only (never prompts here).
//  The file is a short-lived temp: the caller passes its path to codex, then calls `discard`. Note: the
//  screen goes to the user's OWN codex/OpenAI (the same trust boundary computer use already crosses).
//  Doc: Documentation/Notch Magic/.
//
//  Key methods: grab() -> URL? · discard(_:).
//

import Foundation

enum ScreenCapture {
    /// Capture the main display to a temp JPEG for computer-use context. nil = no Screen Recording grant
    /// or the capture failed (the command then runs without a screenshot). Never prompts.
    static func grab() async -> URL? {
        guard Permissions.hasScreenRecording() else {
            Log("📸 screenshot skipped — no Screen Recording grant")
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-shot-\(UUID().uuidString).jpg")
        //  -x : silent (no camera sound)   -t jpg : compact vs a multi-MB Retina PNG
        let ok = await runCapture(["-x", "-t", "jpg", url.path])
        guard ok, FileManager.default.fileExists(atPath: url.path) else {
            Log("📸 screenshot capture failed")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let kb = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1024
        Log("📸 screenshot captured (\(kb) KB)")   // size only — never the pixels
        return url
    }

    /// Delete the temp frame once codex has consumed it (safe on nil).
    static func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
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
