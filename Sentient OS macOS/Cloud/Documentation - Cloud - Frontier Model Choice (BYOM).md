# Frontier Model Choice: bring your own model (Cloud/)

Sentient separates local understanding from the model that puts it to work. Choose your ChatGPT
subscription (the default), your **Claude subscription**, or a compatible **Responses API** endpoint
such as OpenRouter, LM Studio or a self-hosted server. Claude uses `claude -p` for structured work
and its subscription bridge for computer tasks; ChatGPT and custom models use the Codex runtime.
All three choices power knowledge organization, proactive intelligence and Sidekick through the same
computer-use runtime. **A ChatGPT or Claude subscription is optional:** Apple Mail and Apple Calendar
supply locally analyzed email and schedule context on every backend.

Hosted Gmail/Calendar connectors still require their supported subscription account. Direct MCP
connections have their own service and backend support. A local model's capability, context capacity
and speed determine the quality of the experience; shared features do not promise identical model
performance. Double Tap has an independent provider setting, and cloud knowledge sharing is a
separate opt-in.

Useful summaries, task context and screenshots are processed by the selected model. Choose a
compatible local endpoint to keep that inference on the Mac, or use a hosted model under your chosen
provider's settings. API keys are stored in Keychain, not in knowledge notes.

## Files

| File | Job |
|---|---|
| `ModelBackend.swift` | `ModelBackend` (`.chatgpt` / `.claude` / `.custom`, key `model.backend`) and `CustomProvider` (the saved endpoint: preset, base URL, model name, reasoning level, the Keychain API key, the vision-verified flag, and the per-run `-c` overrides). |
| `LoopbackHTTP.swift` | Shared bounded HTTP framing for the local translator and Claude subscription provider. |
| `ResponsesTranslator.swift` | A loopback HTTP proxy between codex and a naive Responses server, translating codex's proprietary tool dialect both ways so MCP tools (computer use included) work there. |
| `Views/FrontierEnginePicker.swift` | The shared UI (Settings pane and onboarding's frontier-model step): the engine pills and per-engine panels, Test & Select, the local-models warning. |

State lives in UserDefaults (`model.backend`, `model.custom.preset` / `baseURL` / `name` /
`reasoning` / `visionVerified`) except the API key (`Keychain`, account `model.custom.apiKey`).
Uninstall destroys it; FactoryReset keeps it (a setup choice, not a learning).

## The five engines

ChatGPT Subscription (recommended) · Claude Subscription (its own sign-in panel and plan chip; see the ClaudeCLI doc) ·
OpenRouter (base URL pinned; Kimi K3 pre-entered) · LM Studio (local; runs through the translator) ·
Custom (any `/v1/responses` endpoint; runs through the translator). The two subscription engines have
the hosted connectors; `CustomProvider.needsTranslator` is true for every preset except OpenRouter,
whose server speaks codex's dialect natively.

**Codex CLI and native computer use prepare at app launch for every backend.** Browsing tabs starts
no additional installation. Claude Code remains lazy, prepared by the Claude commitment/sign-in
actions. ChatGPT sign-in and Test & Select join or retry shared Codex preparation as needed.

## The invocation recipe

Per-run `-c` overrides only (`CustomProvider.providerOverrides()`); the user's `config.toml` is never
written:

```
model_providers.sentient = { name = "Sentient Custom", base_url = "<wire URL>", wire_api = "responses",
                             env_key = "SENTIENT_MODEL_API_KEY", requires_openai_auth = false }
model_provider = sentient
web_search = "disabled"
features.apps = false
model_context_window = 63000 (local) | 120000 (remote)
```

plus `-m <model>` and an explicit `model_reasoning_effort`, with `SENTIENT_MODEL_API_KEY` injected into
every codex spawn (a dummy value when no key is saved). Rules that were each learned the hard way:

- **Always set `env_key`.** Without it codex falls through to the ChatGPT token in `auth.json` and would send the user's real credentials to their custom base URL. The dummy value also covers keyless local servers (codex hard-errors on an unset variable).
- **Never use codex's built-in `openai` / `lmstudio` / `ollama` provider ids** (reserved, no auth fields, fixed ports). Always our own `sentient` table.
- **Responses API for the main frontier backend.** This Codex path does not support chat-only endpoints. Double Tap has a separate API client with both formats.
- **`features.apps = false`.** Hosted-connector tool schemas attach via `auth.json`, not config, so on a ChatGPT-logged-in Mac every custom run would drag hundreds of KB of connector schemas along (and some strict validators reject them). This disables ChatGPT-hosted tools for custom runs; it does not disable local Apple Mail/Calendar or separately prepared direct MCP connections.
- **`--output-schema` is unreliable off-OpenAI**, so custom runs fold the schema into the prompt and decode through `Envelope.jsonResult`; consumers keep their fail-closed decoding.
- **One free-form reasoning level for everything** (`CustomProvider.reasoning`: `low`, `none`, `xhigh`, `adaptive`, whatever the model speaks, sanitized to a bare token). Providers have hard, opposite quirks (Claude-class breaks with reasoning on, Gemini rejects off, Kimi wants low), so per-call effort tuning and the Speed slider belong to the subscription engines (ChatGPT and Claude); the slider dims on a custom backend.
- Corpus slicing shrinks to the endpoint's tier: 280 KB parts remote, 130 KB local (`corpusSliceBudget`), against 700 KB on ChatGPT.

## The vision gate: Test & Select

Computer use feeds the model screenshots, so vision is required and VERIFIED, never self-reported.
`CodexCLI.probeCustomEndpoint()` renders a random 4-digit code into a PNG (`makeVisionProbeImage`),
attaches it with `-i`, and demands the model read it back. Passing sets `visionVerified` and activates
the engine in the same action. Any edit to base URL, model, key, or reasoning clears the verdict (and
drops the backend back to ChatGPT if that engine was live), so Sentient is never pointed at an unproven
model. `CustomProvider.isUsable` = configured + vision-verified.

## The translator (`ResponsesTranslator`)

Naive Responses servers silently drop codex's `{"type":"namespace"}` tool bundles and reject its
array-valued tool outputs, which made every MCP tool invisible there. The translator is a loopback
`NWListener` Sentient starts on demand (`ensureRunning(upstream:)` returns the port; `wireBaseURL` hands
codex `http://127.0.0.1:<port>/v1`); it forwards to the real endpoint with the Authorization header
untouched and rewrites in flight:

- **Requests:** namespace bundles → plain `ns__tool` functions (a mapping is kept per request); history `function_call.namespace` merged into the flattened name; array tool outputs → a string, with images relocated into a following user message; `reasoning` replay items and `include` dropped; server-side-only tool types dropped; and **stale screenshots pruned** so only the newest image survives (local engines skip prompt caching once vision is in the prompt, so a screenshot-per-turn loop re-prefills its whole history every call; the model acts on the newest view by rule, so nothing is lost).
- **Responses (SSE):** streamed `function_call` items un-flattened back into the `{name, namespace}` shape codex routes on, frames preserved.

A failed bind falls back to dialing the endpoint directly: degraded (tools invisible on naive servers)
but honest.

## Prompt rules for weaker models

Every backend gets the native OpenAI computer-use instructions inline (`OpenAIComputerUse.promptRules`;
see the Native Computer Use doc). `CustomProvider.computerUsePromptRules` adds what weaker custom models measurably need on
top, on the custom backend ONLY: a hard safety stop-list (deleting data, payments, passwords,
accounts, installing software, sending sensitive data anywhere the task did not name → stop with
COULD_NOT) and an anti-stall rule (keep going until done; no narrating turns, no check-ins — nobody
can reply). The ChatGPT-backend prompts carry only the shared manual.

## Model reality

Computer use needs vision, reliable tool calls and the ability to verify a sequence of actions.
Passing Test & Select verifies a small vision task, not every workflow. The local-model explanation
in Settings sets expectations about hardware and performance. Check the configured model against
representative tasks rather than relying on an old model ranking.

The main frontier endpoint currently requires Responses compatibility. Double Tap separately supports
both Responses and Chat Completions, with explicit Ollama and LM Studio presets; those drafting
presets do not imply every server works as the main frontier backend.

## Health, cautions, telemetry

The Health pane's engine group follows the live backend (Set Up Codex / Set Up Claude / on custom,
Set Up Codex with a "Frontier model" row in place of the account rows — codex is the harness there
too); `HealthCaution` and `OvernightCaution`'s "logged out" rungs are subscription-backend-only and
engine-named (a 401 on a custom endpoint means a rejected key, so "log back in" would be wrong
advice); custom runs tag the model as the literal `"custom"` in telemetry so a private deployment
name never leaves the Mac.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` (`backendTuned`, the probe), `Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Views/Settings/Documentation - Settings.md`, `Views/Onboarding/Documentation - Onboarding.md`.
