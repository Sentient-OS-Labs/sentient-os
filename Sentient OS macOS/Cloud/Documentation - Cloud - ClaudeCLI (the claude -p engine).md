# ClaudeCLI: the `claude -p` engine (Cloud/)

Claude subscriptions power Sentient through the user's official Claude Code login. Knowledge-base
creation and updates, research, and dedicated connector tasks enter `FrontierRun.run` and continue
using `claude -p`. Computer tasks enter `FrontierRun.runAgentCommand` and always use `codex exec`.
For Claude users, a local Swift bridge lets the official Claude CLI supply inference while Codex
executes native computer tools and local file commands. No ChatGPT account or Anthropic API key is
required for this path.

The shared `CodexCLI.Invocation`, `Envelope`, and `CLIError` types keep structured callers independent
of the selected engine. Authentication remains owned by the official CLIs; Sentient does not extract
Claude OAuth credentials or send requests directly to Anthropic inference endpoints.

## Files

| File | Job |
|---|---|
| `ClaudeCLI.swift` | The actor: discovery, install, login, validation, `run()` (structured stream-json runs), argument building, envelope parsing, the connector allow rules, failure diagnostics. |
| `ClaudeAuth.swift` | Plan identity from `claude auth status` (clean JSON: `loggedIn`, `subscriptionType`, `email`) plus the cached flags the model choke point reads synchronously. |
| `ClaudeSetup.swift` | The `@Observable` setup engine (install, login, the daily managed-binary update) — CodexSetup's two-step sibling; computer-use installation is owned by ComputerUseSetup. |
| `FrontierRun.swift` | Selects the structured engine and sends every computer task to CodexCLI. |
| `ClaudeSubscriptionBridge.swift` | Per-task Responses provider and MCP relay; correlates tool results, replays retries, and owns inference lifetime. |
| `ClaudeSubscriptionProtocol.swift` | Model metadata, tool schemas, image conversion, and Responses events. |
| `ClaudeSubscriptionProcess.swift` | Runs the official Claude CLI in an owned child; drains it on STOP, timeout, or parent exit. |
| `LoopbackHTTP.swift` | Bounded HTTP framing shared with ResponsesTranslator. |

## The dialect map (codex → claude)

| codex | claude |
|---|---|
| `exec` + prompt on stdin | `-p` + prompt on stdin |
| `--json` JSONL | `--output-format stream-json --verbose`; the last line is a `result` object |
| `--output-schema <file>` | `--json-schema <inline>` (validated server-side; the answer lands in `structured_output`) |
| `-m` + `-c model_reasoning_effort` | `--model sonnet\|opus\|haiku --effort low\|…\|xhigh` (efforts map 1:1) |
| `-s read-only` | `--permission-mode dontAsk` + `--tools Bash,Glob,Grep,Read` (+ web tools when `webSearch`) |
| `-s workspace-write` | `--permission-mode acceptEdits`, cwd = the staging dir, `--add-dir`s |
| `--dangerously-bypass-approvals-and-sandbox` | Computer tasks keep this flag in Codex; the Claude inference process uses `dontAsk` and only the relay MCP tools |
| `--ignore-user-config` | `--setting-sources "" --disable-slash-commands` on EVERY run (the user's own Claude Code settings, hooks, and skills never load), plus `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` when `includeUserConfig` is false (the full hermetic seal: no MCP at all, claude.ai connectors included) |
| usage-limit string scrape | a structured `rate_limit_event` mid-stream (reset epoch + window type, persisted to `claude.rateLimit.*`), with a marker scan of Claude's wording ("hit your session limit" family) as the fallback |
| `exec resume <sid>` | `--resume <sid>` (the session id arrives in the first `system/init` event, so a mid-run usage limit keeps its resume handle — the same guarantee) |

## The two run paths

**`run()`** mirrors codex's structured path: prompt over stdin, stream-json back, reduced to the shared
`Envelope`. A `--json-schema` run's `structured_output` is re-serialized into `Envelope.result`, so
schema consumers keep decoding from `Envelope.jsonResult` unchanged. Sessions persist (resume works);
only probes pass `--no-session-persistence`.

**Computer tasks** use `CodexCLI.runAgentCommand`. It validates Codex CLI and the signed native
helper, starts a private loopback provider, then runs real `codex exec` with a task-local model catalog
and provider configuration. Screenshot attachments remain `-i` inputs. Claude receives them as image
content, and Codex's screenshot-bearing tool results become native MCP images without text encoding.

The bridge starts one official Claude session for the task. Claude can request the advertised native
and prepared direct-MCP tools, plus Codex's local shell tools for knowledge-base and file work. Each
request becomes a namespaced Responses function call. Codex performs it and returns the actual result
to the waiting Claude MCP call. Claude's built-in executors and hosted connectors are disabled in
this inference session. Dedicated connector tasks keep their existing Claude runner and policy.

Repeated Responses requests return the same response bytes and call IDs. Repeated MCP calls return
the same result; conflicting requests are refused. The bridge bounds request bodies, connections,
retained results and tool counts. It never starts another inference session to recover a lost place.
Claude owns its session's compaction; Codex-side compaction is disabled for this provider. Computer
tasks start fresh rather than resuming a previous bridge session.

The per-task listener binds only to loopback, authenticates before reading large bodies, and rejects
browser-origin requests. Model metadata, MCP configuration and prompt files live in an owned private
temporary directory. STOP closes the endpoint, cancels Codex and drains Claude. A lightweight mode of
the same signed app monitors its parent and stops Claude after an unexpected app exit. Shared process
plumbing escalates termination for a child that ignores SIGTERM. Temporary files are removed on exit.
No Node runtime, router daemon, permanent provider entry, or user-configuration edit is needed.

The bridge preserves Claude's quota errors and final usage envelope. It streams human progress while
retaining only completion metadata rather than the repeated screenshot transcript. Success still
requires the normal task's verified `STATUS: DONE` result.

## Models and effort

The tier map (`tuned(for:)`, the backendTuned twin): `gpt6astra`/`gpt6sol`/`gpt56terra` → `sonnet`, `gpt6luna` →
`haiku`; a caller that earns Opus says so with `Invocation.claudeModel = .opus` (the vault legs via
`runCodexInStaging`, and proactive research). On a **Pro** plan every Opus pick downshifts to Sonnet
(`ClaudeAuth.isPro` — Pro's Opus window is tiny; the terra-downshift twin; unknown plans fail open).
The Speed slider's Claude mapping (`ComputerUseSpeed.claudeModelAndEffort`): Faster = sonnet·low,
Medium = sonnet·medium, Smarter = opus·medium.

## Hosted connectors and MCP recipes

The registry/census layer supplies per-engine identities and classified tool policy. The
structured builder remains independent of the Codex computer-task provider. The Astra
mapping changes only model resolution; these recipes remain independent of the Codex speed tiers.

- `mcpReadConnectors` keeps `dontAsk`, allows only each registry read list, and walls attachment to those servers. Missing read lists refuse the run.
- `mcpActionServer` requires a classified connector, walls attachment to that server, allows its tools, and denies destructive tools by name. The sandboxed recipe never bypasses permissions.
- `mcpAttachServer` walls in one server with zero tool allows for classifier inventory.
- Claude-hosted connectors remain available to dedicated connector tasks. Computer tasks advertise only the tools attached to their Codex run; prepared direct MCP accounts retain their existing policy.

The existing unclassified Gmail/Calendar card fallback still uses its shipped approval preset.
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` must remain absent because it suppresses claude.ai connector
fetches. Codex's `service_tier` override is not passed to Claude processes.

## Availability, login, plan

`validate()` costs no model tokens: binary found + `claude auth status` (via `ClaudeAuth.refresh()`,
which also caches `subscriptionType`). Claude Code has **no free tier**, so logged-in IS the plan gate
— there is no knowledge-base-only branch, and `CodexAuth.knowledgeBaseOnly` reads false on this
backend. The login is **shared with any Claude Code the user already runs** (`~/.claude` + the macOS
Keychain; decided 2026-08-21): a terminal `/logout` breaks Sentient's engine too, which the health
ladder (`.claudeMissing` / `.claudeSignedOut`) and the morning caution both classify, and Uninstall
never touches `~/.claude` or the Keychain credential. Only a good availability verdict is cached.

## Setup (`ClaudeSetup`)

Claude Code remains a two-step, lazy setup: its CLI downloads when the user commits to Claude,
never just from browsing tabs. Shared Codex CLI and native computer-use setup already start in the
background at app launch for every backend. Claude Code install runs Anthropic's official
installer (`claude.ai/install.sh`, non-interactive, lands at `~/.local/bin/claude` — the same
managed-binary convention as codex) with codex-parity retries and the give-up panel; login is
`claude auth login` (browser OAuth, auto-noticed by polling). The daily update
(`ClaudeSetup.updateIfDue`) rides the same idle tick as codex's, guarded to the managed binary AND to
Claude being the live backend — an engine out of service earns no background downloads. Every spawn
sets `DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`.

## Sharp edges (each one field-found; do not re-learn them)

- **Claude's tool flags are VARIADIC** (`--allowedTools`, `--disallowedTools`, `--mcp-config` keep
  consuming space-separated values), so a bare positional prompt after one gets eaten as a flag value
  and the run dies with "Input must be provided either through stdin or as a prompt argument". Prompts therefore arrive through stdin; no positional prompt follows a variadic flag.
- **Never `--bare`**: bare mode skips the Keychain OAuth read entirely, so subscription auth dies.
  Hermeticity comes from `--setting-sources "" --disable-slash-commands` + `--strict-mcp-config`.
- **Never `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`** (kills the connector fetch, above).
- **Never `CLAUDE_CONFIG_DIR`**: the Keychain credential is bound to the config dir, so pointing it
  anywhere logs the engine out.
- An unsupported `--effort` on a model without effort tiers (haiku) is tolerated, not an error.
- `CLIError` descriptions name the live engine at render time (a Claude failure must never print
  "codex exited 1" in the notch).

## Rules

- Everything cloud goes through `FrontierRun` — no caller may reach either engine directly.
- Connector WRITE tools are never in a read run's allow rules; curate `ConnectorTools` by hand from a
  live tool-list capture, reads only.
- Both engines share the process plumbing (`CodexCLI.executeAsync` / `executeStreaming`); never fork it.
- Structure-only telemetry: `claude.failure` / `claude.agent_command` carry the case name, feature,
  model, plan, and the shared closed-vocabulary reason — never output, prompts, or account material.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` (the reference engine and the shared
types/plumbing), `Cloud/Documentation - Cloud - Codex Setup.md` (the lazy-install flow and the shared
driver step), `Driver/Documentation - Native Computer Use.md` (the shared computer runtime),
`Sources/Documentation - Sources - Cloud (Gmail, Calendar).md` (the engine-aware connect flow),
`Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md` (the picker and the Claude tab).
