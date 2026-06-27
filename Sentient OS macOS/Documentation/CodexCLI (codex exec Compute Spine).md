# CodexCLI — the `codex exec` compute spine

One actor (`CodexCLI.swift`), the spine EVERY cloud feature calls: knowledge-base creation
(`VaultGenerator`), knowledge-base updates (`VaultCloud`), the Gmail connector reads, the
welcome briefing, and proactive intelligence. It piggybacks on the user's own Codex CLI
(their ChatGPT subscription pays). It is the app's ONLY cloud-model path — there is no
direct-Anthropic-API route (deleted, along with `Secrets.swift`) and no free tier yet.
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
- `validate(force:)` — ping (`Reply with exactly: PIGGYBACK_OK`, 30 s), cached per app launch;
  `force: true` re-probes (the installer flow).
- `run(Invocation) → Envelope` — one headless call, typed errors.

`Invocation`: `prompt` (always over **stdin**, never argv) · `model` (`.gpt55` = `gpt-5.5`, the
default for knowledge-base work and everything else / `.gpt54mini` = `gpt-5.4-mini`, the Gmail
tier) · `effort` (`.low` / `.medium` / `.high` / `.xhigh`; **default `.high`** — the initial vault
build overrides to `.xhigh`, the Gmail tier to `.medium`) · `sandbox` (`.readOnly` default / `.workspaceWrite`) · `cwd` · `addDirs`
(extra writable roots) · `webSearch` (**default `true`** — web search is available to every call)
· `includeUserConfig` (**default `true`** — loads `~/.codex` + the user's MCP servers, e.g. their
Gmail MCP, on every call; set `false` for a hermetic run) · `bypassApprovals` (default `false`;
`true` → `--dangerously-bypass-approvals-and-sandbox`, the only way a hosted-connector WRITE tool
like Gmail `send_email` fires headless — TRUSTED prompts only, no sandbox) · `outputSchema`
(JSON-Schema string → temp file → `--output-schema`) · `resumeSessionID` · `timeout` (default 1 h)
· `customEnv` (extra env vars merged into the sanitized child env, e.g.
`PLAYWRIGHT_MCP_STORAGE_STATE`; PATH is reserved) · `extraPathDirs` (dirs prepended to the child
PATH so codex's shell can find tools it shells out to).

`Envelope`: `result` (final agent message) · `sessionID` (thread id — the resume handle) ·
`numTurns` (completed items) · `durationMS` (wall clock, measured here) · `inputTokens` /
`cachedInputTokens` / `outputTokens` · `raw` (full JSONL).

## Flags we always pass, and why

| Flag | Why |
|---|---|
| `--json` | JSONL events → the envelope. `thread.started` carries the thread id in the FIRST event, so the resume handle survives mid-run failures. |
| `--skip-git-repo-check` | staging dirs and the vault aren't git repos; codex refuses to run otherwise |
| `--ignore-user-config` | **Default OFF (we DON'T pass it):** `Invocation.includeUserConfig` defaults `true`, so every call loads the user's `~/.codex` config + MCP servers (their Gmail MCP, etc.). We pass `--ignore-user-config` ONLY for an explicitly hermetic run (`includeUserConfig = false`). |
| `-c tools.web_search=true` | added whenever `Invocation.webSearch` is true — now the **default**, so web search is an available tool on every call |
| `-m <model>` + `-c model_reasoning_effort=…` | the per-call `Invocation.model` (`gpt-5.5` for KB work / `gpt-5.4-mini` for Gmail) and `Invocation.effort` — explicit beats the binary's drifting default |
| `-c approval_policy="never"` (default path) | headless `exec` can't ask a human, so without it codex would stall on shell/file approvals. `never` = don't prompt; the Seatbelt sandbox (`-s`) stays the real guardrail. **Caveat:** for hosted-connector WRITE tools this resolves to auto-CANCEL, not auto-allow (`gmail.send_email` → "user cancelled MCP tool call") — that needs `bypassApprovals` instead |
| `--dangerously-bypass-approvals-and-sandbox` (`bypassApprovals`) | the ONLY lever that makes an approval-gated connector write (Gmail `send_email`) fire headless. Removes BOTH approvals AND the sandbox, so it's mutually exclusive with `-s`/`approval_policy`. Used for the For You "send it" action. **TRUSTED, app-authored prompts only** — there's no sandbox left |
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
| Context | GPT-5.5: 1M API context, **400k input limit through codex** — covers the 10k-summary corpus (200–400k tokens) over stdin (the Gmail tier on `gpt-5.4-mini` chunks weekly to stay well under its own cap) |
| Overhead | ~25k input tokens per call (codex system prompt + tools), almost fully cached |

## Notes

- Sessions persist in `~/.codex/sessions/` (on-device, user-owned — same story as Claude
  Code's `~/.claude/`). `--ephemeral` exists if a job should ever skip persistence; nothing
  uses it today because resume is worth more.
- This spine is the ONLY cloud-model path in the app (the old direct-Anthropic-API fallback
  and `Secrets.swift` were deleted June 11 — git history has them). No codex = no cloud
  organize until the free tier ships.

## Self-test

```sh
SENTIENT_SELFTEST=codexcli "<app>/Contents/MacOS/Sentient OS"
# binary → availability → SPINE_OK run → envelope (session id, items, ms, token triple)
```
