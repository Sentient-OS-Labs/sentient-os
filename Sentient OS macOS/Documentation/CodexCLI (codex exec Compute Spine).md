# CodexCLI — default-deny compute spine

`Cloud/CodexCLI.swift` is the only process wrapper used for Codex-backed model work. Every JSONL
run is constructed with a `CodexDataAccessPolicy`; there is no initializer that omits the policy
and callers cannot append raw access-related config.

## Authentication is not data authorization

`codex login` authenticates model access through the user's ChatGPT account. Sentient does **not**
import ordinary ChatGPT conversations, saved memories, custom instructions, projects, or uploaded
files. A login also does not authorize every account app.

Every invocation passes `--strict-config`, `--ignore-user-config`, and `--ignore-rules`. Codex
memories, user MCP servers, plugins, account apps, and web search are explicitly disabled unless
the named policy enables a narrower capability. Authentication remains available from Codex's auth
store while configuration and inherited instructions are ignored.

Codex CLI **0.146.0 or newer** is required. The version is checked before a prompt is sent; an older
or unparseable version fails closed with an update message.

## Policy matrix

| Purpose | Allowed external data | Session |
|---|---|---|
| validation | none | ephemeral |
| Gmail probe | Gmail `get_profile` | ephemeral |
| Gmail import | Gmail `search_emails`, `read_email` | ephemeral |
| Calendar probe | Calendar `get_profile` | ephemeral |
| Calendar import | Calendar `search_events`, `read_event` | ephemeral |
| Calendar proactive context | Calendar `search_events` | ephemeral |
| vault build/update/resume | none | resumable |
| proactive judge / welcome gift | none | ephemeral |
| proactive research | live web; Gmail read tools only when Gmail is authorized | ephemeral |
| Gmail action | exact `send_email` tool | ephemeral |
| Calendar action | exact `create_event` or `update_event` tool for the confirmed action | ephemeral |
| computer use | exact bundled computer-use plugin | ephemeral |

For hosted apps the global app default is disabled, default tools are disabled, and only the exact
connector ID and tool names are enabled. Destructive tools stay disabled. Connector write failure
does not retry with broader permissions.

Custom model backends are isolated from hosted ChatGPT apps and OpenAI web search. A policy asking
for those capabilities on a custom backend is rejected before execution.

## Invocation and resume

`Invocation(prompt:policy:)` also carries model, effort, sandbox, cwd, extra writable directories,
output schema, timeout, and structured diagnostics. Its feature tag is derived from the policy.

All non-vault JSONL runs pass `--ephemeral`. Vault operations use resumable sessions because their
staging directory is the durable work product. A persisted `VaultGenerator.ResumeToken` contains
the complete policy and a fingerprint. Tokens created before policy persistence, tokens with a
mismatched fingerprint, and non-vault policies are discarded with their staging directory and the
operation restarts under the current restricted vault policy.

Resumed executions receive the same strict config and access policy. Because `exec resume` does not
accept the normal sandbox/cwd flags, the process cwd is restored and the sandbox is set through
`sandbox_mode`.

## Access receipts and runtime enforcement

`CodexAccessLedger` stores at most 250 local receipts. Each receipt contains only timestamp,
policy version/fingerprint, feature, declared capability categories, canonical observed app/tool
categories and lifecycle, outcome, and session type. It never stores prompts, model output, web
queries, MCP arguments/results, raw server/tool names, file paths, recipients, titles, or JSONL.

JSONL parsing recognizes web-search and MCP lifecycle items. Known tools are converted to canonical
Gmail/Calendar names; unknown MCP activity is recorded only as `unknown`. Any observed web or MCP
activity outside the policy throws `CLIError.policyViolation`, and the model result is discarded
before a caller can consume it. Successes, failures, cancellations, launch/parse failures, and
policy violations each create one receipt.

Computer use is the sole non-JSONL path. It must receive `.computerUse`, uses
`--dangerously-bypass-approvals-and-sandbox` because headless MCP elicitation otherwise cannot be
answered, and loads only the app-owned bundled marketplace/plugin under ignored user config. Its
receipt says that computer use was declared and detailed observation was unavailable. The path is
restricted to user-initiated actions and retains the live STOP/cancellation control.

## Diagnostics and privacy

Failure telemetry contains the policy purpose, model category, effort, duration, and typed error
case only. It never transmits the prompt, stdout/stderr, policy arguments, connector identifiers,
or user data. The access ledger itself remains local under Sentient's Application Support folder.

## Verification

Use synthetic JSONL and policy fixtures only. The self-test must cover argument compilation,
original/resume equality, legacy-token rejection, authorized and unauthorized MCP/web events,
receipt redaction/retention, and the isolated computer-use config. Never read a real inbox,
calendar, memory, or account app to test this layer.

## Configuration references

The compiler and documentation follow OpenAI's official [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference),
[non-interactive mode documentation](https://learn.chatgpt.com/docs/noninteractive), and
[memory controls](https://learn.chatgpt.com/docs/customization/memories.md). Policy flags and config
keys must be revalidated against those references before raising the minimum CLI version.
