# CodexCLI — the `codex exec` compute spine

One actor (`Cloud/CodexCLI.swift`), the spine EVERY cloud feature calls: knowledge-base creation
(`VaultGenerator`), knowledge-base updates (`VaultCloud`), the Gmail/Calendar connector reads, the
welcome gift letter, proactive intelligence, and every computer-use run (the command bar, Sidekick,
and the executor's `computer` channel). It piggybacks on the user's own Codex CLI
(their ChatGPT subscription pays). It is the app's ONLY cloud-model path — there is no
direct-Anthropic-API route (deleted, along with `Secrets.swift`) and NO Sentient-hosted
fallback: a ChatGPT subscription is a hard requirement of the product.
Replaced `ClaudeCLI`/`claude -p` on June 11 (clean kill — same actor shape, same `Process`
plumbing).

> Codex's bundled **`computer-use`** skill (the confirmation policy that decides when the agent stops
> before sending/clicking) is patched to a relaxed, human-in-the-loop policy — runbook (where the file
> lives, what to search for, what to replace it with) in
> `Documentation/Computer-Use Skill Patch (Confirmation Policy).md`. Re-apply after a plugin update.

## Surface

- `CodexCLI.locateBinary()` — known paths (`~/.local/bin/codex`, `/opt/homebrew/bin/codex`,
  `/usr/local/bin/codex`), then every nvm-managed node version's `bin/codex` (newest first —
  npm-under-nvm hides the binary in a versioned dir), then a login `zsh -lic "which codex"`
  (interactive — `.zshrc` is where nvm/asdf init; `-lc` alone never sources it). Cached in
  UserDefaults (`codexcli.binaryPath`), re-verified on every read.
- `install(onLine:)` — runs OpenAI's official standalone installer (`curl … install.sh |
  CODEX_NON_INTERACTIVE=1 sh`) streaming its output; success = the binary is actually present after
  (a `curl | sh` pipeline can exit 0 with nothing installed). The `CodexSetup` engine's step 1.
- `startLogin(onLine:)` / `loginStatus()` — step 2: spawns `codex login` as a background process (it
  opens the browser + runs the localhost OAuth callback server, self-exits once `~/.codex/auth.json`
  lands); `loginStatus()` is the ground-truth `codex login status` check (exit 0 = logged in).
- `validate(force:)` — ping (`Reply with exactly: PIGGYBACK_OK`, 30 s). **Only a good verdict is
  cached** (per app launch); a failed probe re-checks on every call, so codex fixed mid-session
  (re-login, reinstall) is seen by the very next retry. ⚠️ Never cache the failure: it once made
  the processing takeover's Retry unwinnable until relaunch (field-found 2026-07-12 — a
  server-side-invalidated token 401'd the ping, the user re-logged in, and four more retries
  still failed in 0 ms off the cached verdict). `force: true` re-probes past a good cache too
  (the installer flow).
- `run(Invocation) → Envelope` — one headless `--json` call, typed errors. An optional `onLine:`
  streams a human-readable play-by-play (each JSONL item reduced by `humanLine` — agent messages,
  `$ command`s, `→ mcp.tool`s, `🔎 search`es) for live UIs (the For You cards).
- `runAgentCommand(_:timeout:onLine:)` — **the computer-use spine** (the command bar, Sidekick, and
  the executor's `computer` channel): a raw `codex exec` with the exact flag set measured to make
  Codex's computer use work on the CLI (`--dangerously-bypass-approvals-and-sandbox`, gpt-5.6-sol,
  `model_reasoning_effort=<the user's Speed vs Intelligence slider — `ComputerUseSpeed.current`,
  Cloud/ComputerUseSpeed.swift: Faster/Medium/Smarter → low/medium/high, default low; read fresh
  per run, so the Settings change is live>, NO `--json` — human-readable output, prompt in argv),
  streaming each output line live. ⚠️ It runs with the FULL inherited environment + a rich PATH
  (`richEnvironment`) — computer use's helper IPC socket lives under the real `$TMPDIR`, so the
  sanitized env that's right for every other call would hang it at `list_apps`. `codex login` needs
  the same for its browser launch.
- **Cancellation is real:** cancelling the awaiting Task (a card's STOP, the notch's stop button)
  terminates the codex child process via a `withTaskCancellationHandler` + process holder.

`Invocation`: `prompt` (always over **stdin**, never argv) · `model` (`.gpt56sol` = `gpt-5.6-sol`, the
default for knowledge-base work and everything else / `.gpt56terra` = `gpt-5.6-terra`, the mid model
used as the free/go stand-in for sol, see **plan-tuned models** below / `.gpt56luna` =
`gpt-5.6-luna`, the Gmail tier) · `effort` (`.low` / `.medium` / `.high` / `.xhigh`; **default
`.high`** — the Gmail tier overrides to `.medium`; nothing runs `.xhigh` since 2026-07-10,
gpt-5.6-sol thinks far too long there) · `sandbox` (`.readOnly` default / `.workspaceWrite`) · `cwd` · `addDirs`
(extra writable roots) · `webSearch` (**default `true`** — web search is available to every call)
· `includeUserConfig` (**default `true`** — loads `~/.codex` + the user's MCP servers, e.g. their
Gmail MCP, on every call; set `false` for a hermetic run) · `bypassApprovals` (default `false`;
`true` → `--dangerously-bypass-approvals-and-sandbox` — **computer use only**, see the flags table;
TRUSTED prompts only, no sandbox) · `configOverrides` (raw per-run `-c key=value` TOML overrides,
appended to the one invocation and never persisted into the user's `config.toml`; ships two curated
presets, both [MEASURED 2026-07-18]: **`approveConnectorWrites`** —
`apps._default.default_tools_approval_mode="approve"` pre-approves hosted-connector WRITE tools
while the Seatbelt sandbox stays ON (verified with a real Gmail send under `-s read-only`; id-free,
so it can't break across users or connector-catalog changes) — and **`stripConnectorActionTools`**
— per-app `open_world_enabled=false` + `destructive_enabled=false` remove the sending/destructive
connector tools from the run's tool surface entirely while reads keep working (a stripped tool
fails as "is not a function" — genuinely absent, not merely refused). ⚠️ Strip keys MUST be the
LONG global connector catalog ids (`connector_…`, identical for every user — see
`~/.codex/plugins/cache/openai-curated-remote/<app>/<ver>/.app.json`): friendly slugs (`gmail`)
are silent no-ops, and the `apps._default` variant over-strips — it removes READ tools too, since
an absent `open_world_hint` counts as open-world) · `outputSchema`
(JSON-Schema string → temp file → `--output-schema`) · `resumeSessionID` · `timeout` (default 1 h).

`Envelope`: `result` (final agent message) · `sessionID` (thread id — the resume handle) ·
`numTurns` (completed items) · `durationMS` (wall clock, measured here) · `inputTokens` /
`cachedInputTokens` / `outputTokens` · `raw` (full JSONL).

## Plan-tuned models (`planTuned`)

Both spines — `run()` (every `Invocation`) and `runAgentCommand` (computer use) — pass the model
through `planTuned` right before spawning. On a **positive** free/go plan read (`CodexAuth.isLimited()`),
any `.gpt56sol` call downshifts to **`.gpt56terra` at `.medium`**; the `.luna` Gmail tier is
untouched, and unknown/missing plans keep sol (CodexAuth's fail-open policy, so paid plans see zero
change). Free/go ChatGPT accounts lost `gpt-5.6-sol` access through `codex exec` (a server-side
"model not supported" refusal), so this substitution keeps knowledge-base work answering on those
plans. Living at the spine means every caller — and any future one — is covered without per-call-site
checks, and the plan is re-read per run, so an upgrade to Plus puts the very next call back on sol.
Failure telemetry reports the model that actually ran, so field events show terra for free accounts.

## Input-size guard (`inputTooLarge`)

`codex exec` rejects a single turn's input past ~1 MiB server-side. Both spines reject any prompt
over **`promptByteCap` = 950 KB** *pre-spawn* with a typed `CLIError.inputTooLarge(chars:)` (plus an
output-side sniff as belt-and-suspenders), so an oversized prompt fails cleanly and classifiably
rather than deep inside codex. The knowledge-base path never trips it in normal use — the corpus is
fed as byte-budgeted parts (`CorpusSlicer`, see `Vault Generation (Stage 2).md`); the guard is the
floor beneath that batching. `OvernightCaution` classifies the typed error into honest banner /
takeover copy.

## Flags we always pass, and why

| Flag | Why |
|---|---|
| `--json` | JSONL events → the envelope. `thread.started` carries the thread id in the FIRST event, so the resume handle survives mid-run failures. |
| `--skip-git-repo-check` | staging dirs and the vault aren't git repos; codex refuses to run otherwise |
| `--ignore-user-config` | **Default OFF (we DON'T pass it):** `Invocation.includeUserConfig` defaults `true`, so every call loads the user's `~/.codex` config + MCP servers (their Gmail MCP, etc.). We pass `--ignore-user-config` ONLY for an explicitly hermetic run (`includeUserConfig = false`). |
| `-c tools.web_search=true` | added whenever `Invocation.webSearch` is true — now the **default**, so web search is an available tool on every call |
| `-m <model>` + `-c model_reasoning_effort=…` | the per-call `Invocation.model` (`gpt-5.6-sol` for KB work / `gpt-5.6-luna` for Gmail) and `Invocation.effort` — explicit beats the binary's drifting default |
| `-c approval_policy="never"` (default path) | headless `exec` can't ask a human, so without it codex would stall on shell/file approvals. `never` = don't prompt; the Seatbelt sandbox (`-s`) stays the real guardrail. **Caveat:** for hosted-connector WRITE tools this resolves to auto-CANCEL, not auto-allow (`gmail.send_email` → "user cancelled MCP tool call") — a caller that must fire one adds `approveConnectorWrites` to `configOverrides` (per-run pre-approval, sandbox intact) |
| `-c <configOverrides>` | the invocation's raw per-run overrides (the two curated presets above), appended after the sandbox/approval flags — scoped to the one run, never persisted into the user's `~/.codex/config.toml` |
| `--dangerously-bypass-approvals-and-sandbox` (`bypassApprovals`) | **computer use ONLY.** The computer-use plugin's per-app "allow app X?" elicitations auto-accept only under the full-access profile — under any Seatbelt profile a headless run auto-DENIES them and every action fails ("Computer Use approval denied via MCP elicitation", [MEASURED 2026-07-18]); per-tool approve config does not propagate to elicitations, so this flag is genuinely the only lever there. Removes BOTH approvals AND the sandbox (mutually exclusive with `-s`/`approval_policy`). Connector writes (the For You gmail/calendar fires) do NOT use it — they ride the sandboxed `approveConnectorWrites` path, with a one-shot fallback to bypass if the approve config ever stops taking (detected deterministically: agent `COULD_NOT` + the verbatim cancel marker in the raw JSONL; `codex.fire_fallback` reports it). **TRUSTED, app-authored prompts only** — there's no sandbox left |
| `-s <sandbox>` | OS-level Seatbelt confinement — stronger than a tool allowlist; even model-run shell commands can't escape cwd + addDirs |

Web search = `-c tools.web_search=true` (`--search` exists only on the interactive CLI, not
`exec`) [MEASURED: native `web_search` items in the JSONL].

## Resume semantics [MEASURED — these are receipts, not guesses]

`codex exec resume <thread_id>` accepts only a SUBSET of `exec`'s flags — **no `-s`, no
`--cd`, no `--add-dir`, no `--color`**. Two consequences, both verified live:

1. **A resumed session's workspace root is the PROCESS cwd**, not the remembered one →
   `execute()` setting `Process.currentDirectoryURL` from `Invocation.cwd` is load-bearing.
2. The sandbox rides the config key instead: `-c sandbox_mode="workspace-write"` (verified:
   a resumed session wrote files under it).

## Usage limits

Failure = non-zero exit OR no final agent message. Error text (JSONL `error` /
`turn.failed` events, else stderr) is marker-sniffed ("usage limit", "rate limit", "quota",
…) → typed `usageLimit(message:sessionID:)` so callers reschedule + resume. ⚠️ The real
ChatGPT-plan limit message is still unverified — refine the markers during dogfood.

## Receipts (June 11, a dev's Mac, codex-cli 0.139.0)

| Fact | Receipt |
|---|---|
| GUI-spawnable, sanitized env | `env -i HOME USER PATH=system` + absolute path → PIGGYBACK_OK. Auth = `~/.codex/auth.json` (file, not Keychain), no TTY. |
| Agentic file-writing, headless | `-s workspace-write -C <dir>` wrote exact-content files, zero prompts; `file_change` events stream per-file progress |
| `--add-dir` | wrote outside cwd into the add-dir'd folder (extra writable root) |
| `--output-schema` | clean conforming JSON for the proactive `{time, text}` shape |
| Resume | same thread id, full memory; workspace = process cwd (see above) |
| Web search | `-c tools.web_search=true` → `web_search` items, correct live answer |
| Context | 1M API context, but a **~1 MiB per-turn input cap through `codex exec`** (server-side, `input_too_large`) is the real constraint for a big corpus. Handled by feeding the corpus as byte-budgeted parts (`CorpusSlicer`, 700 KB each) with the 950 KB `inputTooLarge` guard beneath — verified end-to-end on a 2.55 MB real-scale corpus. (The Gmail tier on `gpt-5.6-luna` chunks weekly to stay well under its own cap.) |
| Overhead | ~25k input tokens per call (codex system prompt + tools), almost fully cached |

## Notes

- Sessions persist in `~/.codex/sessions/` (on-device, user-owned — same story as Claude
  Code's `~/.claude/`). `--ephemeral` exists if a job should ever skip persistence; nothing
  uses it today because resume is worth more.
- This spine is the ONLY cloud-model path in the app (the old direct-Anthropic-API fallback
  and `Secrets.swift` were deleted June 11 — git history has them). No codex = no cloud work;
  a ChatGPT subscription is a hard requirement — there is no free tier and never will be.

## Diagnostics

Every failed `run` emits a structured `codex.failure` event and every failed `runAgentCommand` a
`codex.agent_command` event (§7.9) — the CLIError CASE NAME only (never the message/stderr/prompt,
which embed user content), tagged with the calling `Invocation.feature` (gmail / calendar / vault /
proactive / computer / …) so a broken spine is attributable per feature.

## Self-test

*(Recreate the harness first — see `Self-Testing (Eval Harness).md`; `Self Tests - Temp/` is kept empty.)*

```sh
SENTIENT_SELFTEST=codexcli "<app>/Contents/MacOS/Sentient OS"
# binary → availability → SPINE_OK run → envelope (session id, items, ms, token triple)
```
