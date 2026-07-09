//
//  Engine.swift
//  Sentient OS macOS
//
//  The on-device inference wrapper around LiteRT-LM (Gemma 4 E4B) — written fresh against
//  the LiteRTLM 0.13.1 Swift API (NOT ported from the iOS app). One `Engine` actor owns one
//  native LiteRTLM.Engine for a batch; create/drop a Conversation per artifact.
//
//  Config: GPU (Metal) backend for text AND vision, speculative decoding (MTP) on, low-temp
//  sampling for stable JSON verdicts, and the full GPU-wedge recovery lifecycle (unload →
//  ~1s settle → reload). See the Arch doc §2 for the measured decisions behind each knob.
//
//  Naming note: this module's `Engine` (the wrapper) vs Google's `LiteRTLM.Engine` (the
//  native actor) — the latter is always referenced fully-qualified below.
//

import Foundation
import LiteRTLM

actor Engine {

    /// Result of a single generation. Sendable so it can hop back to the MainActor.
    /// Token stats are populated only when the engine was created with `collectStats: true`
    /// (LiteRT-LM benchmark instrumentation; prefillTokens = the EXACT tokenized prompt size).
    struct Result: Sendable {
        let text: String
        let totalTime: TimeInterval
        var prefillTokens: Int? = nil
        var decodeTokens: Int? = nil
        var prefillTokensPerSecond: Double? = nil
        var decodeTokensPerSecond: Double? = nil
    }

    enum EngineError: Error, CustomStringConvertible {
        case modelNotFound(String)
        case notLoaded

        var description: String {
            switch self {
            case .modelNotFound(let path): return "Model file not found at: \(path)"
            case .notLoaded:               return "Engine.generate() called before load()."
            }
        }
    }

    /// Hard cap on generated tokens per item (decode), passed to the runtime via the wrapper's
    /// `maxOutputTokens` passthrough. A triage reply is a compact JSON summary — even a rich
    /// multi-paragraph keeper for a dense transcript (an investor call, say) sits well under this;
    /// 1024 leaves generous room while bounding a runaway repetition loop to ~1024 tokens (~16s)
    /// instead of letting it decode all the way to the KV ceiling (the ~165s "hang" we measured).
    private static let maxOutputTokens = 1024

    private let modelPath: String
    private let maxNumTokens: Int
    private let collectStats: Bool
    private var native: LiteRTLM.Engine?

    /// `collectStats` turns on LiteRT-LM's benchmark instrumentation (must be decided before
    /// `load()`) so every `Result` carries exact prefill/decode token counts — used by the
    /// token-budget self-test; leave off in production.
    init(modelPath: String, maxNumTokens: Int = 4096, collectStats: Bool = false) {
        self.modelPath = modelPath
        self.maxNumTokens = maxNumTokens
        self.collectStats = collectStats
    }

    var isLoaded: Bool { native != nil }

    /// Loads the model and initializes the native engine. Expensive (~10s) — do it once per batch.
    func load() async throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw EngineError.modelNotFound(modelPath)
        }
        // Must opt in before setting any experimental flag.
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = true   // MTP — Gemma 4 draft heads baked in (~2-3× decode)
        ExperimentalFlags.visualTokenBudget = 560            // Gemma 4 vision detail tier (70/140/280/560/1120)
        ExperimentalFlags.enableBenchmark = collectStats     // token-count instrumentation (self-test only)

        let config = try EngineConfig(
            modelPath: modelPath,
            backend: .gpu,              // Metal on Apple Silicon
            visionBackend: .gpu,        // Metal for vision too — benchmarked ~21% faster than .cpu(), same quality
            maxNumTokens: maxNumTokens, // KV-cache: room for a few pages of document text + reply
            cacheDir: Self.cacheDirectory()
        )
        let native = LiteRTLM.Engine(engineConfig: config)
        try await native.initialize()
        self.native = native
    }

    /// Releases the native engine (frees ~3 GB). Dropping the only strong ref makes ARC run
    /// `LiteRTLM.Engine.deinit` → `litert_lm_engine_delete` → C++ `delete engine` **synchronously**,
    /// which JOINS the GPU worker thread pools and DESTROYS the WebGPU (Dawn/Metal) accelerator
    /// (verified against the runtime source + the teardown logs) — a real device teardown, not a
    /// shallow reset. So by the time this returns, the old engine + its GPU/KV/shader state are gone.
    func unload() {
        native = nil
    }

    /// FULL engine kill + rebuild — the robust way to clear a wedged GPU state ("[Buffer] already has
    /// an outstanding map pending", after which every generate() fails forever on a long run). Order
    /// matters: (1) `unload()` synchronously deletes the engine + tears down the WebGPU device; (2) we
    /// PAUSE ~1s so the Metal/GPU **driver** finishes reclaiming GPU memory *asynchronously* after the
    /// device teardown — allocating into a still-draining device is what makes a too-quick reload
    /// behave "shallow"; (3) load a fresh engine. Costs roughly one `load()` (~10s) + the pause.
    func reload() async throws {
        unload()
        try? await Task.sleep(for: .seconds(1))   // let the GPU driver fully settle after the kill
        try await load()
    }

    /// One stateless generation: fresh Conversation, optional image + prompt → text.
    func generate(prompt: String, imageData: Data? = nil) async throws -> Result {
        guard let native else { throw EngineError.notLoaded }

        // Low temperature (0.15) → near-deterministic, reliable JSON + faithful instruction-following
        // (less "creative" identity-fusion / misattribution in the bouncer). NOT 0/greedy: pure argmax
        // is the LOOPIEST setting, and LiteRT-LM has no repetition penalty, so a sliver of temperature
        // is our only lever to let the model escape gibberish-repeat grooves. `maxOutputTokens` (below)
        // is the hard backstop that bounds any loop that still slips through.
        let sampler = try SamplerConfig(topK: 64, topP: 0.95, temperature: 0.15)
        // Fresh Conversation per call = a CLEAN context: no history bleed, its own KV cache.
        // It deinits at function exit (frees the native handle + KV cache), so per-file memory
        // is fully released — RAM stays flat whether it's file #1 or #500.
        let conversation = try await native.createConversation(
            with: ConversationConfig(samplerConfig: sampler, maxOutputTokens: Self.maxOutputTokens)
        )

        var contents: [Content] = []
        if let imageData { contents.append(.imageData(imageData)) }
        contents.append(.text(prompt))

        let start = Date()
        let response = try await conversation.sendMessage(Message(contents: contents))
        var result = Result(text: response.toString, totalTime: Date().timeIntervalSince(start))
        if collectStats, let info = try? conversation.getBenchmarkInfo() {
            result.prefillTokens = info.lastPrefillTokenCount
            result.decodeTokens = info.lastDecodeTokenCount
            result.prefillTokensPerSecond = info.lastPrefillTokensPerSecond
            result.decodeTokensPerSecond = info.lastDecodeTokensPerSecond
        }
        return result
    }

    /// Writable scratch dir for LiteRT-LM's shader/compilation cache.
    private static func cacheDirectory() -> String {
        let dir = URL.sentientSupport.appendingPathComponent("ModelCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
