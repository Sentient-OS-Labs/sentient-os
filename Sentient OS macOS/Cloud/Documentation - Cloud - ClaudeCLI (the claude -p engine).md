# ClaudeCLI: the `claude -p` engine (Cloud/)

The second frontier harness: the user's own **Claude subscription** (Pro, Max, or Team) powering
Sentient through Claude Code's command line, exactly the way their ChatGPT subscription powers it
through codex. `FrontierRun` is the one dispatch seam: every caller that used to talk to
`CodexCLI.shared` talks to `FrontierRun.run` / `.runAgentCommand`, and a switch on
`ModelBackend.current` picks the harness (`.claude` → this engine; `.chatgpt` and `.custom` → codex).
Both engines speak the SAME types — `CodexCLI.Invocation` in, `CodexCLI.Envelope` out,
`CodexCLI.CLIError` thrown — so callers, their catch blocks, resume handling, and the diagnostics
classifiers never care which harness ran. Deliberately a concrete sibling with a dispatcher, not a
protocol (decided 2026-08-21).

## Files

| File | Job |
|---|---|
| `ClaudeCLI.swift` | The actor: discovery, install, login, validation, `run()` (stream-json runs) and `runAgentCommand()` (computer use), argument building, envelope parsing, the connector allow rules, failure diagnostics. |
| `ClaudeAuth.swift` | Plan identity from `claude auth status` (clean JSON: `loggedIn`, `subscriptionType`, `email`) plus the cached flags the model choke point reads synchronously. |
| `ClaudeSetup.swift` | The `@Observable` setup engine (install, login, the daily managed-binary update) — CodexSetup's two-step sibling; computer-use installation is owned by ComputerUseSetup. |
| `FrontierRun.swift` | The dispatch switch (`run`, `runAgentCommand`, `validate`). |

## The dialect map (codex → claude)

| codex | claude |
|---|---|
| `exec` + prompt on stdin | `-p` + prompt on stdin (`run()`); prompt as the argument DIRECTLY after `-p` (`runAgentCommand`) |
| `--json` JSONL | `--output-format stream-json --verbose`; the last line is a `result` object |
| `--output-schema <file>` | `--json-schema <inline>` (validated server-side; the answer lands in `structured_output`) |
| `-m` + `-c model_reasoning_effort` | `--model sonnet\|opus\|haiku --effort low\|…\|xhigh` (efforts map 1:1) |
| `-s read-only` | `--permission-mode dontAsk` + `--tools Bash,Glob,Grep,Read` (+ web tools when `webSearch`) |
| `-s workspace-write` | `--permission-mode acceptEdits`, cwd = the staging dir, `--add-dir`s |
| `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` (same law: computer use and the connector self-heal only) |
| `--ignore-user-config` | `--setting-sources "" --disable-slash-commands` on EVERY run (the user's own Claude Code settings, hooks, and skills never load), plus `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` when `includeUserConfig` is false (the full hermetic seal: no MCP at all, claude.ai connectors included) |
| usage-limit string scrape | a structured `rate_limit_event` mid-stream (reset epoch + window type, persisted to `claude.rateLimit.*`), with a marker scan of Claude's wording ("hit your session limit" family) as the fallback |
| `exec resume <sid>` | `--resume <sid>` (the session id arrives in the first `system/init` event, so a mid-run usage limit keeps its resume handle — the same guarantee) |

## The two run paths

**`run()`** mirrors codex's structured path: prompt over stdin, stream-json back, reduced to the shared
`Envelope`. A `--json-schema` run's `structured_output` is re-serialized into `Envelope.result`, so
schema consumers keep decoding from `Envelope.jsonResult` unchanged. Sessions persist (resume works);
only probes pass `--no-session-persistence`.

**`runAgentCommand()`** retains the CUA driver, daemon, shim and
`CuaDriverSkill` manual: `--strict-mcp-config --mcp-config` registers the four MCP eyes
(`CuaDriver.claudeMcpConfig`), the driver's other ~52 MCP tools are denied by name
(`CuaDriver.claudeDisallowedMcpTools` — Claude Code has no per-server `enabled_tools` filter),
`--tools Bash,Read` (Bash for the shim's one-shot action calls, Read for screenshots), and
`--dangerously-skip-permissions`. There is no `-i` flag: screenshot paths are appended to the prompt
with an instruction to Read them (Claude Code's Read tool ingests images natively). MCP budgets ride
env vars: `MAX_MCP_OUTPUT_TOKENS=50000` (a full-display look outgrows the 25k default),
`MCP_TIMEOUT=30000`, `MCP_TOOL_TIMEOUT=120000`. Cancellation is the shared plumbing's (a STOP
terminates the child), and both paths reuse `CodexCLI.executeAsync` / `executeStreaming` verbatim.

## Models and effort

The tier map (`tuned(for:)`, the backendTuned twin): `gpt6astra`/`gpt56sol`/`gpt56terra` → `sonnet`, `gpt56luna` →
`haiku`; a caller that earns Opus says so with `Invocation.claudeModel = .opus` (the vault legs via
`runCodexInStaging`, and proactive research). On a **Pro** plan every Opus pick downshifts to Sonnet
(`ClaudeAuth.isPro` — Pro's Opus window is tiny; the terra-downshift twin; unknown plans fail open).
The Speed slider's Claude mapping (`ComputerUseSpeed.claudeModelAndEffort`): Faster = sonnet·low,
Medium = sonnet·medium, Smarter = opus·medium.

## Hosted connectors and MCP recipes

The registry/census layer supplies per-engine identities and classified tool policy. Both the
structured builder and the computer-use builder remain available to the connector lab. The Astra
mapping changes only model resolution; these recipes remain independent of the Codex speed tiers.

- `mcpReadConnectors` keeps `dontAsk`, allows only each registry read list, and walls attachment to those servers. Missing read lists refuse the run.
- `mcpActionServer` requires a classified connector, walls attachment to that server, allows its tools, and denies destructive tools by name. The sandboxed recipe never bypasses permissions.
- `mcpAttachServer` walls in one server with zero tool allows for classifier inventory.
- Computer use retains the cua vision server plus the registry's permitted connector attachments and destructive deny lists. With no attachments it uses the strict cua-only wall. Screenshot paths remain in the prompt's Read instructions.

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

Two steps, lazy: **nothing installs at first launch** (decided 2026-08-21) — each engine's CLI
downloads at a COMMITMENT action only (the Claude panel's "Sign in with Claude", ChatGPT's sign-in /
"Use ChatGPT", a custom tab's Test & Select), never on tab browsing. Install runs Anthropic's official
installer (`claude.ai/install.sh`, non-interactive, lands at `~/.local/bin/claude` — the same
managed-binary convention as codex) with codex-parity retries and the give-up panel; login is
`claude auth login` (browser OAuth, auto-noticed by polling). The daily update
(`ClaudeSetup.updateIfDue`) rides the same idle tick as codex's, guarded to the managed binary AND to
Claude being the live backend — an engine out of service earns no background downloads. Every spawn
sets `DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`.

## Sharp edges (each one field-found; do not re-learn them)

- **Claude's tool flags are VARIADIC** (`--allowedTools`, `--disallowedTools`, `--mcp-config` keep
  consuming space-separated values), so a bare positional prompt after one gets eaten as a flag value
  and the run dies with "Input must be provided either through stdin or as a prompt argument". The
  agent path's prompt therefore sits DIRECTLY after `-p`; no positional ever follows a variadic flag.
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
driver step), `Driver/Documentation - Driver (cua-driver).md` (the hybrid transport this engine reuses),
`Sources/Documentation - Sources - Cloud (Gmail, Calendar).md` (the engine-aware connect flow),
`Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md` (the picker and the Claude tab).
