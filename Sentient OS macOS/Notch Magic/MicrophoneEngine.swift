//
//  MicrophoneEngine.swift
//  Sentient OS macOS
//
//  The process's microphone `AVAudioEngine`, made safe against input-device changes. Both speech
//  engines (SpeechAnalyzerEngine on macOS 26+, SFSpeechRecognizerEngine on 15) tap the input node
//  through this file instead of touching AVFAudio's tap API directly.
//
//  Why it exists: `installTap(format:)` SETS the input node's output-bus format, and after the input
//  hardware changes (AirPods on, headset unplugged, a Bluetooth mic dropping across sleep) AVFAudio
//  keeps the nodes "with previously set formats". One long-lived engine then hands back a stale bus
//  format, the next tap install is a bus-vs-hardware mismatch, and AVFAudio raises an ObjC exception
//  Swift can't catch (`Failed to create tap due to format mismatch`) — the app dies on the press.
//  Sometimes the mismatch is silent instead: the tap installs and delivers zero buffers.
//  Field-found across 28 users, 2026-08 (Sentry SENTIENT-OS-47).
//
//  The rules here: compare the hardware format with the bus format before every tap and rebuild the
//  engine on any difference; treat a 0 Hz / 0 ch hardware format as "no microphone"; rebuild after an
//  `AVAudioEngineConfigurationChange` or a failed start; on macOS 27+ use the throwing tap API so a
//  residual mismatch is an error, not a crash; stop + reset after every capture.
//
//  Key members:
//   - shared()                → the process engine, rebuilt if stale (call per capture)
//   - validatedInputFormat(of:) → the tap format for an engine's input node, or throws
//   - installTap(on:format:block:) → the safe tap install (throws on macOS 27+, guarded below)
//   - stop(_:)                → remove the tap, stop, reset
//   - markDirty()             → the next shared() builds a fresh engine
//
//  Doc: Notch Magic/Documentation - Sidekick - General.md
//

import Foundation
import os
@preconcurrency import AVFAudio

enum MicrophoneEngine {

    // MARK: The shared engine

    /// ONE engine for the process, reused across captures: a fresh AVAudioEngine per capture opens a
    /// new HAL IO proc each press, and rapid press/cancel churn wedges CoreAudio input into
    /// delivering zero buffers (field-proven). It is rebuilt only when it has gone stale.
    private static var engine = AVAudioEngine()

    /// Set from AVFAudio's configuration-change notification (an internal queue) and from a failed
    /// start; read on the next `shared()`. A lock, not an isolated var, so the notification handler
    /// can flip it without hopping actors.
    private nonisolated static let dirty = OSAllocatedUnfairLock(initialState: false)

    private static var observing = false

    /// The process engine, fresh if the previous one is known-stale. Call once per capture.
    static func shared() -> AVAudioEngine {
        startObservingIfNeeded()
        if dirty.withLock({ let was = $0; $0 = false; return was }) {
            Log("voice: rebuilding the audio engine (device change / failed start)")
            engine = AVAudioEngine()
        }
        return engine
    }

    /// The next `shared()` builds a fresh engine.
    static func markDirty() { dirty.withLock { $0 = true } }

    /// AVFAudio stops the engine itself when the input/output hardware changes and posts this; the
    /// nodes keep their previously set formats, so the engine must be rebuilt before the next tap.
    /// The engine is never deallocated inside the handler (the header warns it can deadlock).
    private static func startObservingIfNeeded() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: nil, queue: nil) { _ in
            dirty.withLock { $0 = true }
        }
    }

    // MARK: The tap

    /// The format to tap `engine`'s input node with. Compares the HARDWARE format
    /// (`inputFormat(forBus:)`) with the node's output-bus format (`outputFormat(forBus:)`): a
    /// difference means the engine outlived a device change and its bus format is stale, so the
    /// caller must rebuild (`markDirty()` + `shared()` again) — this throws `.deviceChanged` for
    /// that. A 0 Hz / 0 ch hardware format is "no microphone" (`.noMicrophone`).
    static func validatedInputFormat(of engine: AVAudioEngine) throws -> AVAudioFormat {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw VoiceError.noMicrophone
        }
        let bus = input.outputFormat(forBus: 0)
        guard bus.sampleRate == hardware.sampleRate, bus.channelCount == hardware.channelCount else {
            Log("voice: input device changed (\(Int(bus.sampleRate)) Hz/\(bus.channelCount) ch → \(Int(hardware.sampleRate)) Hz/\(hardware.channelCount) ch)")
            throw VoiceError.deviceChanged
        }
        return bus
    }

    /// The shared engine with a validated tap format, rebuilding once on a stale bus format. The
    /// one call both speech engines make per capture.
    static func acquire() throws -> (engine: AVAudioEngine, format: AVAudioFormat) {
        var engine = shared()
        do {
            return (engine, try validatedInputFormat(of: engine))
        } catch VoiceError.deviceChanged {
            markDirty()
            engine = shared()
            return (engine, try validatedInputFormat(of: engine))
        }
    }

    /// Install the tap. On macOS 27+ (when built with the macOS 27 SDK) the throwing tap API turns
    /// a residual format mismatch into an error the caller can recover from; on 26.x only the raising
    /// API exists, and `validatedInputFormat` is the guard. `block` receives a mutable PCM buffer on
    /// both paths (the read-only buffer of the new API is copied — 4096 frames, negligible).
    static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                           block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        input.removeTap(onBus: 0)   // defensive: a stale tap from an interrupted capture must not linger
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { readOnly, _ in
                block(AVAudioPCMBuffer(copying: readOnly))
            }
            return
        }
        #endif
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in block(buffer) }
    }

    /// End a capture: remove the tap, stop, and reset the nodes so nothing carries over.
    static func stop(_ engine: AVAudioEngine, tapInstalled: Bool) {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        if engine.isRunning { engine.stop() }
        engine.reset()
    }
}
