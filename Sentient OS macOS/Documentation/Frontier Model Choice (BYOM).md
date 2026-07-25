# Frontier Model Choice — bring your own frontier model

**What this is:** how Sentient runs its cloud ~10% on an engine of the user's choosing — their
ChatGPT subscription (the default), or ANY endpoint that speaks the OpenAI **Responses API**
(OpenRouter, LM Studio, a self-hosted server). Same `codex exec` spine, same computer use, no
OpenAI account required anywhere in the chain.

Code: `Cloud/ModelBackend.swift` (the source of truth) · `Cloud/ResponsesTranslator.swift` (the
local-endpoint translator) · `Views/Settings/FrontierModelPane.swift` (the pane) ·
`Cloud/CodexCLI.swift` (`backendTuned`, the probe, the arg builder).
Related: `CodexCLI (codex exec Compute Spine).md` · `Plan Gate (CodexAuth & Knowledge-Base-Only).md`.

---

## 1. The shape

```
Settings → Frontier Model Choice
  ChatGPT Subscription  (recommended — the only engine with Gmail/Calendar)
  Claude Subscription   (coming soon — `claude -p` as the harness)
  OpenRouter            (base URL pinned; Kimi K3 pre-entered)
  LM Studio    (local)  (runs through the translator)
  Custom       (local)  (any /v1/responses endpoint)
```

**A custom engine unlocks the full experience** — knowledge base, proactive cards, Sidekick and
computer use — **minus the hosted Gmail/Calendar connectors**, which ride ChatGPT-account auth
inside codex and cannot exist elsewhere. `CodexAuth.knowledgeBaseOnly` therefore reads false on a
custom backend (the stored free/go flag is preserved, so switching back restores that experience),
and `CodexAuth.connectorsLocked` is the one predicate every connector chip consults.

State lives in UserDefaults (`model.backend`, `model.custom.*`) except the API key, which uses the
existing Keychain helper (`model.custom.apiKey`). **Uninstall destroys it; FactoryReset keeps it** —
a setup choice, not a learning, so a rebuild comes back on the same engine.

## 2. The invocation recipe (live-verified, codex 0.145.0)

Per-run `-c` overrides only; the user's `~/.codex/config.toml` is never written.

```
model_providers.sentient={ name = "Sentient Custom", base_url = "<wire URL>",
                           wire_api = "responses", env_key = "SENTIENT_MODEL_API_KEY",
                           requires_openai_auth = false }
model_provider=sentient
web_search="disabled"        # codex's web_search is an OpenAI-server-side tool
features.apps=false          # see §2.1
model_context_window=<63000 local | 120000 remote>
```
plus `-m <the user's model>`, an explicit `model_reasoning_effort`, and
`SENTIENT_MODEL_API_KEY` in the child environment (both spawn paths inject it).

**Hard rules, each learned the hard way:**
- ⚠️ **Always set `env_key`.** With no `env_key`/bearer, codex falls through to the ChatGPT token in
  `auth.json` and would send the user's real credentials to their custom base URL. A dummy value
  covers keyless local servers.
- ⚠️ **Never use codex's built-in `openai`/`lmstudio`/`ollama` provider ids** — reserved (a hard
  startup error), no auth fields, fixed ports. Always our own `sentient` table.
- ⚠️ **Responses API only.** `wire_api = "chat"` was REMOVED from codex (not deprecated); there is
  no Chat Completions path left. Chat-only endpoints cannot be supported.
- ⚠️ **`--output-schema` is unreliable off-OpenAI** (endpoints accept the schema and return prose).
  Custom runs fold the schema into the prompt and decode through `Envelope.jsonResult`, which
  extracts the outermost JSON value; callers keep their fail-closed decoding.

### 2.1 Why `features.apps=false`
Hosted-connector (`codex_apps`) tools attach via **`auth.json`, not config.toml** — so on a
ChatGPT-logged-in Mac every custom run dragged hundreds of KB of connector schemas along (and
Gemini's strict validator 400s on one of them). Apps off is the custom-mode ground state: leaner
prompts, no phantom failures. Connectors are ChatGPT-only anyway.

## 3. One reasoning level, free-form

The pane's **REASONING** field is free text (`low`, `none`, `xhigh`, `adaptive`… — codex passes any
token through; it is sanitized to a bare lowercase token). `CodexCLI.backendTuned` applies it to
**every** custom run — vault, judge, research, gift, Sidekick, card fires, and the probe — because
providers have hard, opposite quirks: Claude-class endpoints break with reasoning ON (thinking-block
signatures break multi-turn), Gemini rejects OFF, Kimi wants low. Per-call effort tuning and the
Speed vs Intelligence slider are **ChatGPT's alone**; on a custom backend that slider is dimmed with
a hover explanation. Editing the level re-arms the vision gate (§4), so a bad value fails at
Test & Select instead of at 3 AM.

## 4. The vision gate (Test & Select)

Computer use feeds the model screenshots, so **vision is a hard requirement, verified rather than
self-reported**. `CodexCLI.probeCustomEndpoint()` renders a random 4-digit code into a PNG, attaches
it with `-i`, and demands the model read it back. Passing sets `CustomProvider.visionVerified` **and
activates the engine in the same action** (that is what "Test & Select" means). Any edit to base
URL / model / key / reasoning clears the verdict — and drops the backend back to ChatGPT if that
engine was live, so Sentient is never left pointed at an unproven model. The probe catches both a
blind endpoint and an "accepts images but ignores them" model.

## 5. The translator (`ResponsesTranslator`)

Naive Responses servers (LM Studio, and by construction anything similar) **silently drop codex's
proprietary `{"type":"namespace"}` tool bundles and reject its array-valued tool outputs** — so
computer use was impossible there. The translator is a loopback proxy Sentient starts on demand;
codex dials it, it forwards to the user's real endpoint, rewriting in flight:

| Direction | Rewrite |
|---|---|
| Request | namespace bundles → plain `ns__tool` functions · history `function_call.namespace` merged into the flattened name · array tool outputs → a string, with images relocated into a following user message · `reasoning` replay items and `include` dropped · server-side-only tools dropped |
| Request | **stale screenshots pruned** — only the newest image survives; older ones become a one-line note |
| Response (SSE) | streamed `function_call` items un-flattened back into the `{name, namespace}` shape codex routes on; frames preserved |

`CustomProvider.needsTranslator` is true for every preset **except OpenRouter**, whose server speaks
the dialect natively. A failed bind falls back to dialing direct: degraded (tools invisible on naive
servers) but honest.

**Why pruning matters:** local engines skip prompt caching entirely once vision content is in the
prompt, so a screenshot-per-turn agent loop re-prefills its whole growing history every call
(10–30s per turn by turn 15 on a 35B). Keeping only the latest view holds the prompt near-constant.
The model acts on the newest screenshot by rule, so nothing is lost.

## 6. Prompt rules for custom models

Codex only *advertises* the computer-use skill (one line + a path to `SKILL.md`); GPT-5.6 goes and
reads that file, weaker models measurably don't. So `CustomProvider.computerUsePromptRules` injects
8 operating rules into the two app-authored computer-use prompts (`CommandRunModel.commandPrompt`,
`ProactiveExecutor.computerWrapper`) **on the custom backend only** — the shipped ChatGPT prompts
stay byte-identical. The rules: call `get_app_state` first · click by element_index only when the
tree really lists it, else x/y with element_index OMITTED (never an empty string) · verify after
every action · the SCREENSHOT is the source of truth, not the tree · verify the goal state before
declaring done · a compressed confirmation policy (stop before deletions, payments, credentials) ·
the screenshot IS the coordinate space (never aim against an assumed screen size) · and KEEP GOING
UNTIL DONE (ending the turn early counts as failure).

Rules 1–6 fixed measured failures (empty `element_index`, panic-clicking, abandoning correct
clicks); 7 fixed aiming at an imagined canvas; 8 fixed one-call quitting.

## 7. Model reality (survey, 2026-07-24)

Computer use is a much harder bar than chat or coding — it is barely in any model's training data.
Of ~10 models driven through real tasks on a real Mac:

| Model | Verdict |
|---|---|
| **GPT-5.6 Sol** (low) | The shipped ChatGPT baseline |
| **Claude Sonnet 5** (reasoning **off**) | Clean, precise |
| **Kimi K3** (low) | Clean first try — the first open-weights model to clear the bar (~2.8T params, so not laptop-runnable) |
| Qwen 3.6 35B A3B (local, via the translator) | Completed a real multi-step Notes task through Sidekick; slow, and weak at verifying dark UI |
| MiniMax M3 · Qwen 3.6 27B · Inkling | Partial: tool-mechanic or stamina failures |
| Qwen 3.6 Plus · Gemini 3.6 Flash · Nemotron 3 Ultra (text-only) · Gemma 4 31B (not agentic) | Not viable |

Two failure families: **tool mechanics** (fixable by the rules above, proven) and **agentic stamina
+ spatial precision** (not fixable by prompting — the real dividing line). Hence the pane's honest
copy and the "A note on local frontier models" popup on the LM Studio tab.

## 8. Health, gates, and telemetry

- **Health pane:** in custom mode the ChatGPT account/plan rows are replaced by a "Frontier model"
  row that deep-links back to this pane (`SettingsView.switchPane`); `accountHealthy` means "logged
  in + non-limited plan" on ChatGPT, "endpoint configured" on custom.
- **Cautions:** the `.loggedOut` rungs (HealthCaution, OvernightCaution) are ChatGPT-only — on a
  custom endpoint a 401 means a rejected API key, so "log back in" would be wrong advice.
- **Corpus slicing:** 700 KB (ChatGPT) / 280 KB (remote custom) / 130 KB (local) per part.
- **Telemetry:** custom runs tag the model as the literal `"custom"` — a user's model slug or
  private deployment name is free text and never leaves the Mac.
