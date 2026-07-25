//
//  ModelBackend.swift
//  Sentient OS macOS
//
//  The ONE source of truth for the user's frontier-model choice (Settings → Frontier Model
//  Choice): their ChatGPT subscription (the default), or a custom OpenAI-Responses-compatible
//  endpoint (OpenRouter, a local server, any base URL + model name + key). A Claude-plan backend
//  (`claude -p` as the harness) is planned; it gets its enum case when it's real.
//
//  Key surface:
//   - ModelBackend.current            → .chatgpt | .custom (read fresh; Settings is live, no restart)
//   - CustomProvider.current          → the saved endpoint (preset, base URL, model, vision, key)
//   - CustomProvider.providerOverrides() → the per-run `-c` recipe CodexCLI injects (never persisted
//     into the user's config.toml)
//   - CustomProvider.apiKeyEnvValue   → the env var value for codex's `env_key` auth
//   - ModelBackend.connectorsAvailable → hosted Gmail/Calendar ride ChatGPT auth only
//
//  Invariants (live-verified 2026-07-24, receipts to land in the feature doc):
//   - The provider table ALWAYS carries `env_key` — codex otherwise falls through to the ChatGPT
//     bearer in auth.json and would send the user's real token to the custom base URL.
//   - We never use codex's built-in `lmstudio`/`ollama` provider ids (reserved, no auth fields,
//     fixed ports) — always our own `sentient` provider table.
//   - `web_search` is disabled on custom runs (codex's web_search is an OpenAI-server-side tool;
//     emitting it to a foreign endpoint is noise at best).
//   - An explicit reasoning effort is always sent (some endpoints hard-reject reasoning-off).
//
import Foundation
import AppKit

/// Which frontier engine powers the cloud ~10% of Sentient (the on-device model does the rest).
enum ModelBackend: String, Sendable {
    case chatgpt   // the user's own ChatGPT subscription through their codex login (default)
    case custom    // a user-supplied OpenAI-Responses-compatible endpoint

    static let key = "model.backend"

    /// The live choice — read fresh per use so the Settings pane applies to the very next run.
    static var current: ModelBackend {
        ModelBackend(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .chatgpt
    }

    /// Hosted Gmail/Calendar connectors ride ChatGPT-account auth inside codex — they don't exist
    /// on a custom endpoint. (Everything else — vault, proactive, Sidekick/computer use — does.)
    static var connectorsAvailable: Bool { current == .chatgpt }
}

/// The saved custom endpoint. All fields live in UserDefaults except the API key (Keychain).
struct CustomProvider: Sendable {

    /// The endpoint flavors. OpenRouter is a tab of its own; LM Studio is a preset under the
    /// pane's Custom tab that prefills the base URL (and carries the honest local-models
    /// warning) — the flavor also picks the context/corpus tier via `isLocal`. (Ollama was cut
    /// pre-ship: the translator should cover it identically, but untested options don't ship.)
    enum Preset: String, CaseIterable, Sendable {
        case openRouter = "openrouter"
        case lmStudio = "lmstudio"
        case custom = "custom"

        var defaultBaseURL: String {
            switch self {
            case .openRouter: "https://openrouter.ai/api/v1"
            case .lmStudio: "http://127.0.0.1:1234/v1"   // the URL LM Studio's own UI advertises
            case .custom: ""
            }
        }

        /// Local servers get the conservative 63k context assumption; remote endpoints ~120k.
        var isLocal: Bool { self == .lmStudio }
    }

    var preset: Preset
    var baseURL: String
    var modelName: String

    // UserDefaults keys (the CustomInstructions one-source-of-truth pattern).
    static let presetKey = "model.custom.preset"
    static let baseURLKey = "model.custom.baseURL"
    static let modelNameKey = "model.custom.name"
    /// Set only by a PASSING vision probe (see CodexCLI.probeCustomEndpoint), cleared the moment
    /// the endpoint or model changes. Sentient refuses to activate a custom model until this is
    /// true: computer use is the product, it feeds the model screenshots, and a model that can't
    /// see them fails the whole run ("404 No endpoints found that support image input" —
    /// measured on a text-only model, 2026-07-24). Verified, never self-reported.
    static let visionVerifiedKey = "model.custom.visionVerified"
    /// The endpoint's ONE reasoning level — free text the user types in the pane (`none`,
    /// `low`, `xhigh`, `adaptive`, whatever their model speaks; codex passes any token
    /// through), applied by backendTuned to EVERY custom run (vault, judge, research, gift,
    /// Sidekick, card fires, the probe): per-call effort tuning and the Speed slider are
    /// ChatGPT's alone. One level, not per-call, because providers have hard quirks either
    /// direction (Claude-class breaks with reasoning on; Gemini rejects off; Kimi wants low).
    /// Sanitized to a bare lowercase token (it rides inside a quoted `-c` TOML value); empty
    /// falls back to `low`.
    static let reasoningKey = "model.custom.reasoning"
    static var reasoning: String {
        let cleaned = (UserDefaults.standard.string(forKey: reasoningKey) ?? "")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return cleaned.isEmpty ? "low" : cleaned
    }

    /// Keychain account for the endpoint's API key (service `ai.sentient-os.app`, same helper as
    /// the mirror password). Cleared by FactoryReset and Uninstall.
    static let apiKeyAccount = "model.custom.apiKey"
    /// The env var the provider table's `env_key` names; injected into every codex spawn.
    static let apiKeyEnvName = "SENTIENT_MODEL_API_KEY"

    static var current: CustomProvider {
        let d = UserDefaults.standard
        let preset = Preset(rawValue: d.string(forKey: presetKey) ?? "") ?? .openRouter
        return CustomProvider(
            preset: preset,
            baseURL: (d.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: (d.string(forKey: modelNameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(preset.rawValue, forKey: Self.presetKey)
        d.set(baseURL, forKey: Self.baseURLKey)
        d.set(modelName, forKey: Self.modelNameKey)
    }

    /// The verified-can-see-screenshots verdict for the CURRENTLY saved endpoint + model.
    /// Any edit to either clears it, so a swapped model must re-prove itself.
    static var visionVerified: Bool {
        get { UserDefaults.standard.bool(forKey: visionVerifiedKey) }
        set { UserDefaults.standard.set(newValue, forKey: visionVerifiedKey) }
    }

    /// A base URL and model name exist — the minimum for a run (the key is optional: local
    /// servers don't check it).
    var isConfigured: Bool { !baseURL.isEmpty && !modelName.isEmpty }

    /// Every custom preset EXCEPT OpenRouter rides the local translator (ResponsesTranslator):
    /// OpenRouter's server speaks codex's namespace dialect natively (measured), naive servers
    /// (LM Studio, Ollama, vLLM, anything self-hosted) drop it. Routing everything-but-OpenRouter
    /// through the translator is safe either way — it only rewrites what it recognizes.
    var needsTranslator: Bool { preset != .openRouter }

    /// The base URL codex actually dials: the translator's loopback port when this endpoint
    /// needs it (started lazily here), the real URL otherwise. A translator that fails to bind
    /// falls back to dialing direct — degraded (tools invisible on naive servers) but honest,
    /// and the run itself still speaks.
    var wireBaseURL: String {
        guard needsTranslator,
              let port = ResponsesTranslator.shared.ensureRunning(upstream: baseURL) else {
            return baseURL
        }
        return "http://127.0.0.1:\(port)/v1"
    }

    /// Ready to actually power Sentient: reachable shape AND a proven pair of eyes.
    var isUsable: Bool { isConfigured && Self.visionVerified }

    /// The API key (Keychain), or nil when none is saved.
    static var apiKey: String? {
        let v = Keychain.read(apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    /// The value `SENTIENT_MODEL_API_KEY` carries into the codex process. Never empty: codex
    /// hard-errors on an unset/empty `env_key` var, and a real value here is also what BLOCKS
    /// the ChatGPT-token fallthrough on keyless local servers.
    static var apiKeyEnvValue: String { apiKey ?? "sentient-local-no-key" }

    /// The assumed context window: local endpoints 63k tokens, remote 120k. Sent as
    /// `model_context_window` so codex compacts honestly instead of assuming its 272k fallback.
    var contextWindow: Int { preset.isLocal ? 63_000 : 120_000 }

    /// The vault CorpusSlicer's per-part byte budget for this endpoint (ChatGPT mode uses the
    /// original 700 KB): sized so one part + instructions + tool chatter + the model's own
    /// writing fit the context window with room to breathe (~4 chars/token, ~half the window
    /// for corpus).
    var corpusSliceBudget: Int { preset.isLocal ? 130_000 : 280_000 }

    /// The per-run `-c` overrides that make codex talk to this endpoint — layered over the
    /// user's config at highest precedence, never written to disk. Shape live-verified against
    /// LM Studio and OpenRouter on codex 0.145.0. Naive endpoints get the translator in the
    /// middle (wireBaseURL); the API key still rides Authorization end-to-end (the translator
    /// forwards it untouched).
    func providerOverrides() -> [String] {
        let table = "model_providers.sentient={ name = \"Sentient Custom\", "
            + "base_url = \"\(Self.tomlEscaped(wireBaseURL))\", wire_api = \"responses\", "
            + "env_key = \"\(Self.apiKeyEnvName)\", requires_openai_auth = false }"
        return [table,
                "model_provider=sentient",
                "web_search=\"disabled\"",
                // The hosted-connector (codex_apps) tools attach via auth.json, NOT config.toml —
                // a ChatGPT-logged-in Mac would drag every connector's tool schemas into every
                // custom run (hundreds of KB, and Gemini's strict validator 400s on one of them
                // via OpenRouter — measured 2026-07-24). Apps off is the custom-mode ground state.
                "features.apps=false",
                "model_context_window=\(contextWindow)"]
    }

    /// Escape a user-supplied string for a TOML basic string (quotes, backslashes; control
    /// characters dropped — none belong in a URL or model id).
    static func tomlEscaped(_ s: String) -> String {
        s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map { scalar -> String in
                switch scalar {
                case "\\": return "\\\\"
                case "\"": return "\\\""
                default: return String(scalar)
                }
            }.joined()
    }

    /// Renders a throwaway PNG carrying a random 4-digit code in big white type on black, and
    /// returns (file URL, code). The vision probe asks the model to read the code back: that
    /// tests the capability computer use actually needs — reading text off a screenshot — not
    /// merely whether the endpoint tolerates an image part. Caller deletes the file.
    static func makeVisionProbeImage() -> (url: URL, code: String)? {
        let code = String(format: "%04d", Int.random(in: 1000...9999))
        let size = NSSize(width: 420, height: 220)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let text = code as NSString
        let height = text.size(withAttributes: attrs).height
        text.draw(in: NSRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height),
                  withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-vision-\(UUID().uuidString).png")
        do { try png.write(to: url) } catch { return nil }
        return (url, code)
    }

    /// Tool-usage + safety rules injected into the app-authored computer-use prompts
    /// (Sidekick's commandPrompt, the executor's computerWrapper) ON THE CUSTOM BACKEND ONLY —
    /// empty on ChatGPT, so the shipped, field-proven prompts stay byte-identical there.
    /// Why: codex only ADVERTISES the computer-use skill (one line + a file path); GPT-5.6 goes
    /// and reads SKILL.md, but weaker custom models measurably don't (2026-07-24: MiniMax sent
    /// `element_index: ""`, got `invalidElementID`, "fixed" it with the window element, clicked
    /// the window center 15 times, then claimed success off an accidental spacebar play). So the
    /// operating rules AND a compressed confirmation policy ride inline for custom models.
    static var computerUsePromptRules: String {
        guard ModelBackend.current == .custom else { return "" }
        return """

        COMPUTER-USE TOOL RULES (follow exactly):
        1. Before interacting with an app each turn, call get_app_state once and study BOTH the \
        screenshot and the accessibility tree it returns.
        2. To click something the accessibility tree ACTUALLY lists, pass element_index alone \
        (omit x/y). If the tree does not list what you can see in the screenshot (many apps \
        expose only the window frame and menu bar), aim with the screenshot instead: pass x and \
        y alone and OMIT the element_index field completely — never send it as an empty string, \
        and never fall back to clicking a window/container element.
        3. After each click or keystroke, call get_app_state again and confirm the screen \
        changed the way you expected before taking the next step.
        4. The SCREENSHOT is the source of truth, not the accessibility tree. Many apps list \
        only their sidebar or window frame in the tree and never show the main content pane, so \
        a tree that looks empty or unchanged does NOT mean your click failed. Judge what \
        happened from the screenshot, and never abandon a correctly targeted click to start \
        guessing at other coordinates.
        5. Before declaring the task done, verify from the LATEST screenshot that the goal \
        state is actually visible. If you cannot verify it, report honestly that you could not.
        6. Safety, non-negotiable: do the user's stated task without re-asking, but STOP (end \
        with STATUS: COULD_NOT and ask the user to take over) before any of these: deleting \
        data, payments or other financial transactions, changing passwords or security \
        settings, creating accounts or API keys, installing software, or sending sensitive \
        personal data (passwords, financials, government IDs) anywhere the task did not \
        explicitly name.
        7. The screenshot you receive IS the coordinate space, and it is only as large as the \
        app's window, often much smaller than the screen. Read its actual pixel dimensions from \
        the image before aiming, keep every coordinate inside those bounds, and never estimate \
        against an assumed screen size. If a click reports that no window was found at that \
        position, your coordinates were outside the image, so re-read its size rather than \
        nudging your guess.
        8. KEEP GOING UNTIL IT IS DONE. This is a multi-step task and you run autonomously: \
        after every tool call, immediately make the next one. Do NOT end your turn to narrate \
        what you are about to do, do not stop to check in, and do not stop until the task is \
        actually complete (or you have genuinely failed). Ending your turn early counts as \
        failure. You cannot ask questions; nobody will reply.
        """
    }

    /// Wipe every stored field + the Keychain key (FactoryReset / Uninstall).
    static func destroy() {
        let d = UserDefaults.standard
        [ModelBackend.key, presetKey, baseURLKey, modelNameKey, visionVerifiedKey,
         reasoningKey].forEach {
            d.removeObject(forKey: $0)
        }
        Keychain.delete(apiKeyAccount)
    }
}
