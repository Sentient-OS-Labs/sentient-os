# CodexCLI — the `codex exec` compute spine

One actor (`CodexCLI.swift`), the spine EVERY cloud feature calls: initial vault generation,
the day's-end updater, the welcome briefing, the proactive judge and tier-2 briefings. It
piggybacks on the user's own Codex CLI (their ChatGPT subscription pays). Replaced
`ClaudeCLI`/`claude -p` on June 11 (clean kill — same actor shape, same `Process` plumbing).

## Surface

- `CodexCLI.locateBinary()` — known paths (`~/.local/bin/codex`, `/opt/homebrew/bin/codex`,
  `/usr/local/bin/codex`) then `zsh -lc "which codex"`; cached in UserDefaults
  (`codexcli.binaryPath`), re-verified on every read.
- `validate(force:)` — ping (`Reply with exactly: PIGGYBACK_OK`, 30 s), cached per app launch;
  `force: true` re-probes (the installer flow).
- `run(Invocation) → Envelope` — one headless call, typed errors.

`Invocation`: `prompt` (always over **stdin**, never argv) · `effort` (`.high` = initial gen,
`.medium` = everything daily) · `sandbox` (`.readOnly` default / `.workspaceWrite`) · `cwd` ·
`addDirs` (extra writable roots) · `webSearch` · `outputSchema` (JSON-Schema
string → temp file → `--output-schema`) · `resumeSessionID` · `timeout` (default 1 h).

`Envelope`: `result` (final agent message) · `sessionID` (thread id — the resume handle) ·
`numTurns` (completed items) · `durationMS` (wall clock, measured here) · `inputTokens` /
`cachedInputTokens` / `outputTokens` · `raw` (full JSONL).

## Flags we always pass, and why

| Flag | Why |
|---|---|
| `--json` | JSONL events → the envelope. `thread.started` carries the thread id in the FIRST event, so the resume handle survives mid-run failures. |
| `--skip-git-repo-check` | staging dirs and the vault aren't git repos; codex refuses to run otherwise |
| `--ignore-user-config` | hermetic runs — the user's personal `~/.codex/config.toml` (personality, plugins, MCP servers) must never leak into our jobs |
| `-m gpt-5.5` + `-c model_reasoning_effort=…` | explicit beats the binary's drifting default |
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

## Receipts (June 11, Aryaman's Mac, codex-cli 0.139.0)

| Fact | Receipt |
|---|---|
| GUI-spawnable, sanitized env | `env -i HOME USER PATH=system` + absolute path → PIGGYBACK_OK. Auth = `~/.codex/auth.json` (file, not Keychain), no TTY. |
| Agentic file-writing, headless | `-s workspace-write -C <dir>` wrote exact-content files, zero prompts; `file_change` events stream per-file progress |
| `--add-dir` | wrote outside cwd into the add-dir'd folder (extra writable root) |
| `--output-schema` | clean conforming JSON for the proactive `{time, text}` shape |
| Resume | same thread id, full memory; workspace = process cwd (see above) |
| Web search | `-c tools.web_search=true` → `web_search` items, correct live answer |
| Context | GPT-5.5: 1M API context, **400k input limit through codex** — covers the 10k-summary corpus (200–400k tokens) over stdin |
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
