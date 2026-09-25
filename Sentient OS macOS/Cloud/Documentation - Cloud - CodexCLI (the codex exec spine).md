# CodexCLI: the `codex exec` spine (Cloud/)

`CodexCLI` is one of the two frontier harnesses (the other is `ClaudeCLI`, the `claude -p` engine —
see its doc). Every cloud feature — the knowledge base build and updates, the Gmail/Calendar reads,
the gift letter, the proactive judge and research, and every computer-use run — calls
**`FrontierRun`**, the one dispatch switch on `ModelBackend.current`: `.chatgpt` and `.custom` land
here, `.claude` lands on ClaudeCLI. This file is also the REFERENCE engine: the shared types
(`Invocation`, `Envelope`, `CLIError`) and the engine-neutral process plumbing (`executeAsync` /
`executeStreaming` — sanitized env, watchdog, cancellation, line streaming) live here and ClaudeCLI
reuses them verbatim. It runs the user's own Codex CLI as a subprocess; their ChatGPT subscription
(or their own endpoint, see the BYOM doc) pays. There is no Sentient-hosted compute and no API key in
the app.

## Files

| File | Job |
|---|---|
| `CodexCLI.swift` | The actor: binary discovery, install, login, validation, `run()` (structured JSONL runs) and `runAgentCommand()` (computer use), argument building, JSONL parsing, process plumbing, failure diagnostics. |
| `AgentStatus.swift` | Parses the `STATUS: DONE` / `STATUS: COULD_NOT` sentinel every app-authored wrapper prompt demands, shared by the executor and Sidekick. |
| `ComputerUseSpeed.swift` | The Speed vs Intelligence slider value (Settings → Proactive & Sidekick): Faster / Medium / Smarter → Sol low / Astra low / Astra medium for computer-use runs on Codex; on the Claude engine the tier picks model + effort (see the ClaudeCLI doc). |

## The two run paths

**`run(_ invocation:) → Envelope`** is the structured path. The prompt goes over **stdin** (never argv;
prompts can be hundreds of KB), `--json` streams JSONL events back, and the reply is reduced to an
`Envelope` (final message, thread id, item count, wall-clock duration, token counts, raw JSONL). It runs
with a **sanitized environment** (just HOME, USER, a system PATH led by the binary's own directory, and
the custom-endpoint key variable). Optional `onLine:` streams a humanized play-by-play (agent messages,
`$ command`s, `→ tool` calls, `🔎` searches) for live UIs.

**`runAgentCommand(prompt, imagePaths:, timeout:, onLine:) → String`** is the computer-use path. The
prompt rides in **argv**, output is human-readable (no `--json`), and every line is pumped to `onLine`
as it arrives. `ComputerUseSetup` prepares the selected runtime. On ChatGPT, the signed OpenAI
helper is validated and its native client is registered directly as the required `sentient_native`
MCP server. Custom endpoints retain `CuaDriverHost` and its four-tool vision registration plus CLI
shim. Claude's sibling runner continues to use CUA.

The run remains hermetic (`--ignore-user-config`) and preserves its hosted/direct connector policies.
`FrontierRun` adds exactly one runtime manual after capturing the selected backend. Native setup
writes no plugin or global Codex configuration. See `Driver/Documentation - Native Computer Use.md`
for installation, permissions and compatibility checks. Computer-use flags remain
`--dangerously-bypass-approvals-and-sandbox`, the selected model and effort, optional `-i` screenshots,
and `--skip-git-repo-check`; structured connector runs retain their separate permission policy.

**Cancellation is real on both paths:** cancelling the awaiting Swift Task terminates the codex child
process (a process holder inside `withTaskCancellationHandler`). Every STOP button in the app reaches
this.

## `Invocation`

| Field | Default | Meaning |
|---|---|---|
| `prompt` | | over stdin |
| `model` | `.gpt56sol` | Sol remains the structured default; `.gpt6astra` is the upper computer-use tier, `.gpt56luna` the light tier, and `.gpt56terra` the limited-plan fallback |
| `effort` | `.high` | reasoning effort; the connector reads use `.medium`; nothing uses `.xhigh` |
| `sandbox` | `.readOnly` | Seatbelt profile: `read-only` or `workspace-write` (writes confined to `cwd` + `addDirs`) |
| `cwd`, `addDirs` | | the agent's working root and extra writable roots |
| `webSearch` | `true` | adds `-c tools.web_search=true` |
| `includeUserConfig` | `true` | load the user's `~/.codex` config and MCP servers; `false` passes `--ignore-user-config` (a hermetic run) |
| `bypassApprovals` | `false` | `--dangerously-bypass-approvals-and-sandbox`: no approvals AND no sandbox. Computer use only. |
| `configOverrides` | `[]` | raw per-run `-c key=value` TOML overrides, never persisted into the user's `config.toml` |
| `outputSchema` | | a JSON Schema string → temp file → `--output-schema` (the ChatGPT backend enforces it server-side) |
| `resumeSessionID` | | continue a prior thread (usage-limit recovery) |
| `timeout` | 3600 s | watchdog |
| `feature`, `diag` | | diagnostics tags only (which caller; structured extras) |
| `claudeModel` | `nil` | Claude model override, ignored by Codex; the heavy legs can select Opus. Connector access uses the MCP recipe fields below. |

The MCP recipe fields are mutually exclusive: `mcpReadConnectors` for unattended reads,
`mcpActionServer` for a user-fired connector task, and `mcpAttachServer` for classifier inventory
(the latter changes Claude attachment only). `imagePaths` adds optional structured-run screenshots.
Both engines retain internal argument builders so the connector lab can inspect recipes without runs.

- Unattended reads keep the read-only sandbox and strip both action and destructive tools from requested connectors and every other detected ChatGPT connector, using catalog IDs.
- Fired connector tasks keep the sandbox and approve the selected server's tools per invocation, with its destructive tools stripped. An unresolved ID retains the existing id-free `approveConnectorWrites` fallback.
- Computer use keeps its extracted `agentArguments` builder, selected-runtime registration, bypass posture, and destructive-tool strips for pinned and detected connectors. Custom-provider overrides still apply afterward.
- Classifier attachment keeps its existing engine-specific restrictions. No fast-tier or model change broadens any recipe's permissions.

The older `approveConnectorWrites` and `stripConnectorActionTools` presets remain available for their
existing callers. Never replace a server-scoped recipe with a global approval as part of model tuning.

## Model resolution: `backendTuned`

Both run paths resolve the model string and the effort string through one function right before
spawning:

- **Custom backend** (Settings → Frontier Model Choice): the user's endpoint model rides EVERY call and their single free-form reasoning level replaces the caller's effort. `run()` also injects the provider overrides, turns web search off, forces a hermetic run (`includeUserConfig = false`, since hosted-connector schemas would bloat every prompt), and turns `--output-schema` into a prompt instruction (naive endpoints ignore the schema); consumers then decode from `Envelope.jsonResult`.
- **ChatGPT backend:** on a positive free/go plan read (`CodexAuth.isLimited()`), a Sol or Astra call downshifts to Terra at medium. Unknown plans retain the requested model, asserted Plus preserves the existing override, and Luna is untouched. Re-read per run.

The computer-use slider reads `sidekick.speed` at each run: `faster` selects `gpt-5.6-sol`/low,
`medium` selects `gpt-6-astra`/low, and `smarter` selects `gpt-6-astra`/medium. Stored values and the
Faster default are unchanged. Custom model/reasoning settings override that tuple.

MCP-only tasks retain their caller policy: routed Sidekick uses structured Sol/medium, connector
cards use Sol/high, and the router uses Luna/low. A connector failure that falls back to computer use
gets the current slider tuple on that fallback leg. Knowledge, research, and ingestion keep their own
model choices. Requested model IDs do not imply measured latency or account availability.

## Discovery, install, login, validation

- **`locateBinary()`**: the managed install `~/.local/bin/codex` first, unconditionally (the standalone installer's symlink, the one copy the setup engine keeps current; a dangling link falls through), then the UserDefaults cache (`codexcli.binaryPath`, re-verified), then `/opt/homebrew/bin`, `/usr/local/bin`, every nvm node version's `bin/codex`, then an interactive login shell `zsh -lic "which codex"` (only an interactive shell sources `.zshrc`, where nvm/asdf init).
- **`install(onLine:)`**: OpenAI's official installer, `curl … install.sh | CODEX_NON_INTERACTIVE=1 sh`, with a `sed` that injects an `Accept: application/json` header and curl speed-limits into the script's own downloads (GitHub's API serves minified JSON without the header, which the script cannot parse; the speed limits make a stalled transfer fail in ~30 s while a slow one still finishes; per-attempt budget 900 s). Success is "the binary exists afterward", not the pipeline's exit code.
- **`startLogin(onLine:)`** spawns `codex login` in the background (browser OAuth, localhost callback; it self-exits once `~/.codex/auth.json` lands). **`loginStatus()`** is the ground truth (`codex login status`, exit 0). **`isRunnable()`** runs `codex --help` (a pure path check can be fooled by a broken symlink).
- **`validate(force:)`**: a 30 s ping (`Reply with exactly: PIGGYBACK_OK`, hermetic, read-only). Only a GOOD verdict is cached, keyed by the backend fingerprint; a failed probe re-checks on every call so a fix mid-session (re-login, reinstall, an endpoint coming online) is seen by the very next retry. **`probeCustomEndpoint()`** is the pane's Test & Select: it attaches a rendered 4-digit code and demands the model read it back (vision is required for computer use).

## Arguments (`arguments(for:)`) and resume

`exec [resume <sid>] -c service_tier="fast" --json --skip-git-repo-check -m <model> -c model_reasoning_effort=… [--ignore-user-config]`,
then either the bypass flag (+ `--cd`), or `-c approval_policy="never"` + `-s <sandbox>` + `--cd` +
`--add-dir`s, then the config overrides, `-c tools.web_search=true`, `--output-schema`, and `-` (stdin).

`codex exec resume` accepts only a subset of flags (no `-s`, `--cd`, `--add-dir`): a resumed session's
workspace root is the PROCESS cwd (so `Process.currentDirectoryURL` is set from `Invocation.cwd`), and
the sandbox rides `-c sandbox_mode=…` instead. Verified live.

Every Codex exec builder starts with `execArguments`: probes, fresh/resumed structured runs, and
computer use. Fast service tier is a per-invocation configuration override, never a global config edit.
The resume ID precedes the fast override. Caller/provider overrides, sandbox differences, and the
flag terminating the variadic image list retain their ordering.

The override also reaches custom-provider invocations. A localhost Responses fixture with managed
Codex 0.154.0 accepted it, kept the selected custom model/reasoning and provider credential, and omitted
`service_tier` from the custom-provider wire request. Endpoint support and actual service speed are
separate from accepting the CLI configuration; no provider-side acceleration is promised.

## Failures

`CLIError`: `notAvailable`, `launchFailed`, `timedOut`, `exitFailure`, `badEnvelope`,
`usageLimit(message, sessionID)` (marker-sniffed from the JSONL error text; the thread id from the first
event survives as the resume handle), and `inputTooLarge(chars)`. codex rejects a single turn over
~1 MiB server-side, so both paths refuse any prompt over **`promptByteCap` = 950 KB before spawning**;
every prompt path is byte-budgeted below that (the vault's `CorpusSlicer`, proactive's window trim), so
this is a canary. `OvernightCaution` classifies the typed errors into honest banner copy.

Every real failure emits one structured Sentry event (`codex.failure` / `codex.agent_command`) carrying
the CLIError CASE NAME only, the calling `feature`, model, effort, and duration. A cancelled Task (the
user's STOP) and `usageLimit` never report.

## `AgentStatus`

Every app-authored wrapper prompt demands a final `STATUS: DONE` or `STATUS: COULD_NOT` line.
The final nonempty line must match the exact sentinel grammar. Earlier quoted output, prompt echoes,
and negated status do not count. Missing or malformed status is unconfirmed and surfaces as a failed
attempt rather than a completed action. Process exit zero is necessary but does not establish task
success. The legacy opening `COULD NOT` form is still recognized as failure.

## Rules

- `bypassApprovals` is for computer use ONLY. Connector writes retain their server-scoped recipe (or existing unresolved-ID fallback) with the sandbox on.
- Never cache a failed availability verdict.
- Every prompt path must be byte-budgeted under `promptByteCap`.
- Never log codex output or stderr in a Release breadcrumb; log `ErrorLabel(error)` and lengths.

## Related docs

`Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md` (the sibling engine and the dispatch), `Cloud/Documentation - Cloud - Codex Setup.md`, `Driver/Documentation - Driver (cua-driver).md`, `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Cloud/Documentation - Cloud - Plan Gate (CodexAuth).md`, `Proactive/Documentation - Proactive Intelligence.md`, `Notch Magic/Documentation - Sidekick - General.md`.
