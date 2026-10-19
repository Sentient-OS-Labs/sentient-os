# Diagnostics (Diagnostics/): crash reporting, structured events, and product analytics

Basic usage counts, AI-written Sidekick workflow descriptions and optional technical reports help us
improve this open-source app. **Sentry** reports crashes, hangs and structured errors.
**TelemetryDeck** reports usage and locally format-validated workflow phrases, plus optional timings, setup progress
and app health. Raw task content is not an analytics payload; the phrase checks and their limits are
described below.

Both run in Release builds. Crash reports and extended analytics have separate Settings → System
controls, enabled by default. Turning crash reports off stops Sentry. Turning extended analytics off
leaves basic usage, launch/session and install/uninstall counts and format-validated task descriptions enabled.
Onboarding and Settings show that disclosure beside the extended-analytics switch. The services use a generated
per-install identifier, separate from the mirror secret and feedback list, rather than a name or email.

## Files

| File | Job |
|---|---|
| `Log.swift` | `Log()`: the codebase-wide replacement for `print()`. Console output, a Sentry breadcrumb, and in DEBUG a timestamped tee to `/tmp/sentient-dev.log`. Plus `ErrorLabel(error)`: the content-safe way to log an error. |
| `CrashReporting.swift` | Sentry: the two gates, `captureEvent`, `capture(error)`, breadcrumbs, the PII scrubber, the forced-off SDK defaults. |
| `Analytics.swift` | TelemetryDeck: `start`, `signal` (with the two consent tiers), the one minimal install-count ping and its uninstall twin. |
| `Diagnostics.swift` | Operation scopes, parent/root correlation, error classification, expected blockers and bounded reporting fields. |
| `AgentRunDiagnostics.swift` | Parses Codex and Claude tool events into a bounded timeline and distinguishes process exit, model completion claims and tool results. |
| `ChildProcessDiagnostics.swift` | Collects owned helper exit metadata through a private temporary channel, excluding intentional stops and cancelled collection. |
| `Notch Magic/SidekickTaskSummary.swift` | Retains intent/final workflow phrases through interruption, validates their format locally and emits one typed report at task end. |
| `ExecutorScoreboard.swift` | Records action outcomes, with fallback diagnostics for paths not already reported by the frontier boundary. Expected blockers use informational events; successes go to TelemetryDeck. |
| `SourceHealth.swift` | The sensors' memory: run-over-run listing counts per source (a healthy count that craters to zero = `<source>.listing_collapsed`) and a rolling 7-day file-extraction rate. |

## The gates

Nothing reaches Sentry unless BOTH hold: a **Release build** (`start` no-ops in DEBUG; there is no
debug bypass, so verify from a Release build) and the **crash-reports opt-out** (`diagnosticsEnabled`,
default on, the "Share crash reports" toggle). TelemetryDeck boots in Release
unconditionally, because its always-on core tier must send; the "Share extended usage analytics" toggle
(`analyticsEnabled`, default on) gates the extended tier per signal. Flipping either toggle calls
`applyEnabledChange()` live. `main.swift` configures both process roles (GUI app and root wake helper).
The helper starts reporting only after a verified GUI client supplies consent and an installation
UUID; its own defaults cannot enable reporting. TelemetryDeck runs in the GUI role only.

## Keeping content out of reports

The reporting contract permits structured technical fields: counts, ratios, booleans, enums, durations, byte buckets, HTTP / exit /
sqlite codes, error type or case names, versions, fingerprints. Never message or note text, file names
or paths, contact names, chat ids, drafts, codex output, transcripts, or the mirror token. This is the
technical-event and ordinary-signal contract. Format-validated task descriptions have one separate, typed
entry point; they do not relax the contract for other reporting. The implementation uses these defenses:

- **Clean at the source.** `captureEvent` takes only enums and counts the caller controls. Content-bearing `Log()` lines are `#if DEBUG` (Sentry never boots in DEBUG, so they can never become a breadcrumb). Error paths log `ErrorLabel(error)`, never `\(error)` or `localizedDescription`: in Release it renders the enum case or type name only ("CLIError.exitFailure"), because error payloads embed content (codex stderr, note titles in file paths). The pipeline logs only a bucket key's scheme (`CycleStore.scheme`), never the key.
- **The scrubber backstop** (`beforeSend` / `beforeBreadcrumb`): redacts URLs, home-directory and external-volume paths, mirror-password segments, emails, phone runs and long tokens. It covers message and exception text, tags, extras, context and nested breadcrumb data. Sensitive field names are redacted; validated app-generated correlation UUIDs are retained. Reporting fields still must be clean at their source; this text filter cannot recognize every identifying meaning.
- **The SDK's URL-capturing defaults are forced OFF** (`enableNetworkBreadcrumbs = false`, `enableCaptureFailedRequests = false`) and must stay off: both record full request URLs, and the mirror URL carries the user's password in its path (the "request paths are never logged" invariant, enforced on the server too). Re-check what new SDK defaults capture on every update.
- Auto session tracking is deliberately OFF: usage counting belongs to TelemetryDeck and its core/extended tiers, not the crash-report toggle. App-hang detection is at 10 s (2 s paged us for harmless onboarding stalls); `enableUncaughtNSExceptionReporting` is explicitly on (it defaults off on macOS); no tracing or profiling.

Identity: `CrashReporting.installID`, a random UUID minted once in UserDefaults, set as Sentry's user id
and TelemetryDeck's default user (which hashes it again). Every event is auto-stamped with the OS and app
version.

These filters are designed to exclude private content; they are not a proof that all possible
third-party exception strings are harmless. Keep new event fields in a closed vocabulary, review
SDK upgrades, and never rely on the text scrubber to sanitize arbitrary structured payloads.

## `captureEvent` and the event catalog

```swift
CrashReporting.captureEvent("source.some_failure", level: .warning,
                            tags: ["source": "whatsapp"], extra: ["count": "42"],
                            fingerprint: ["whatsapp", "some_failure"])
```

Stable dotted names, low-cardinality tags, structure-only extras, and a fingerprint so issues group by
failure mode. Callable off-main with no `await`; a no-op unless Sentry is up and opted in.

| Event | From | Fires when |
|---|---|---|
| `engine.load_failed` · `engine.hard_stop` · `triage.parse_failure_spike` · `source.dropped` · `source.hit_time_cap` | `IterativeRun` | the model will not load · the GPU-wedge cascade the reloads could not clear · ≥20% of a ≥30-item run were garbled replies · a connector's listing threw (FDA denied, DB copy failed) · a source ran past its 60-min budget |
| `whatsapp.zero_sessions_despite_install` · `whatsapp.no_opted_in_chats` | `WhatsAppSource` | the session whitelist returned nothing on an installed WhatsApp · opted-in chats matched no live session |
| `imessage.decode.degraded` · `notes.decode.degraded` | the sources | typedstream / gzip+protobuf decode under 50% with a real sample |
| `<source>.listing_collapsed` · `files.extraction_degraded` | `SourceHealth` | a healthy listing count cratered to zero · the rolling extraction rate fell under 50% (≥30 samples) |
| `db.schema_error` · `addressbook.no_store` | `SQLiteDB` · `AddressBookNames` | a static SQL prepare failed (a column rename) · the v22 contacts store is absent |
| `gmail.parse.shape_mismatch` · `calendar.parse.shape_mismatch` | the cloud sources | the reply will not parse or lacks `notable` (a quiet week is silent) |
| `codex.failure` · `codex.agent_command` · `codex.fire_fallback` · `codex_auth.refresh_failed` · `codex_setup.step_failed` | `CodexCLI` · `ProactiveExecutor` · `CodexAuth` · `CodexSetup` | a real codex failure (case name, feature, model, effort, duration; STOPs and usage limits never report) · a sandboxed connector fire's write auto-cancelled and the one-shot bypass retry ran · the token re-mint got a non-OK status · a setup step failed |
| `model.download.failed` · `fda.probe` · `notify.add_failed` · `mirror.push_failed` · `vault_swap_failed` | `ModelDownload` · `Permissions` · `Notify` · `VaultCloud` · `VaultGenerator` | the download exhausted retries (reason enum) · FDA not cleanly granted before a DB-source run · a notification add threw · a mirror push failed (HTTP status only) · the atomic swap threw |
| `executor.fire` | `ExecutorScoreboard` | a defect-shaped fire only: `failed`, `refused` (COULD_NOT), `notFireable`, or `fired` with no STATUS sentinel (the false-success risk). Verified successes never report here. |

Plus native crashes and 10 s hangs from the SDK, and `capture(error)` on the critical vault paths.

## Agent and helper diagnostics

`AgentRunDiagnostics` scopes frontier calls and consumes structured events from both engines. It
retains a bounded sequence of fixed tool names or families, counts, durations, failure categories
and helper/process state. Connector-defined tool names and provider call IDs stay local; native app
selectors become per-run target ordinals. Unknown results remain unknown, and a model's final status
is labelled as a claim rather than treated as proof that the action happened.

`Diagnostics` and `SidekickInteraction` supply app-generated operation/task IDs and attempt numbers
to connect failures and recovery events. Questions, answers and model-authored error text do not
become fields. Expected blockers can use informational reports; cancellation alone is not a defect.
A tool failure observed before cancellation can still be reported. Child-process collection excludes
intentionally stopped helpers, while unexpected nonzero exits, including signal exits, remain visible.

## Analytics signals (`Analytics.signal`)

Two consent tiers. The **core** tier keeps sending when extended analytics are opted out and is disclosed
beside that switch; the current core categories include how many people use Sentient (the install
ping + the SDK's session signals), `Command.submitted` (Sidekick / command-bar fires), `Proactive.prepared`
and `Proactive.actionFired` (cards made and fired), `Scheduler.overnightCompleted`, and `Home.opened`.
The separate `Sidekick.taskSummary` sink also uses the always-on tier, as described below.
Other product signals are **extended**: `Onboarding.completed`, `Processing.completed` (counts), `Engine.reloaded`,
`Scheduler.overnightStarted` / `.gated` / `.caution` / `.autoEnabled`, `KnowledgeBase.built` / `.updated` /
`.failed` / `.staleSwapAverted`, `Proactive.decided`, `ComputerUse.finished` (agent seconds as
`floatValue`, summed into total agent time), `Mirror.enabled` / `.pushed` / `.disabled` / `.regenerated`,
`Source.connected`, `Model.downloadCompleted`, `PermissionGate.shown` / `.continued`, `PlanGate.*`,
`Notify.notAuthorized`. Every signal auto-stamps the model file name.

**The minimal install ping** (`countInstallOnce`): one direct POST to TelemetryDeck's ingest with a
throwaway random hash, separate from the persistent diagnostics identifier, an empty payload, and no device info, fired at most once
per install (latched only after a 2xx) even when analytics are opted out; the one number that is
attempted across installs independently of the extended-analytics setting. `countUninstall` is its farewell twin, fired as the teardown begins.

## Sidekick task descriptions and outcomes

For an eligible user-requested attempt, the selected task model can call `describe_task_usage` with
an initial `intent` phrase and a later `final` phrase. The prompt requires a generalized workflow,
without identifying or sensitive details. This tool neither marks success nor adds visible activity.
Further actions invalidate a final phrase while retaining a valid intent for interrupted attempts.
A null or rejected replacement withdraws earlier text. Completion consumes the report once.

`SidekickTaskSummary.checkedPhrase` checks the byte length, word count and character envelope.
`Analytics.recordTaskSummary` accepts only the resulting `Validated` value within a typed report.
There is no separate inference or model review. Invalid or unavailable descriptions are omitted;
fixed availability/reason fields distinguish them. Outcomes and interruption reasons use their own
bounded categories, including whether evidence came from the app or the model.

Workflow phrases are the sole free-text analytics exception. Prompt instructions and format checks
do not prove anonymity or exclude every sensitive meaning. Original requests, conversation text,
screenshots, knowledge files and final answers are not accepted by this sink. Generated identifiers
can associate repeated events and do not sanitize the phrase.

This reporting remains enabled in Release when extended analytics is off. Debug does not submit
these events. Keep `PrivacyCopy` and `SECURITY.md` consistent with these boundaries.

The App ID and the Sentry DSN are ingest-only and safe in the public repo; the Sentry Auth Token used for
dSYM upload is a real secret and lives only in the gitignored `.sentryclirc`.

## dSYMs (readable Release crashes)

The "Upload dSYMs to Sentry" build phase uploads Release dSYMs via `sentry-cli`, reading auth and
org/project from `.sentryclirc` at the repo root. Every guard exits 0, so a missing token or tool never
breaks a build, which also means the phase fails SILENTLY: both dev Macs must keep a current
`.sentryclirc`, and `Scripts/release.sh` hard-gates a release on the DMG's dSYMs being on Sentry
(`SKIP_SENTRY=1` opts out knowingly). Sentry does not capture crashes while the debugger is attached;
test with the standalone `.app`.

## Rules

- `Log()` everywhere; bare `print()` is a code smell. Error paths use `ErrorLabel`.
- Structure only in technical events and ordinary signals; format-validated task descriptions use their
  typed sink exclusively. Content-bearing logs are `#if DEBUG`.
- Never re-enable the SDK's network breadcrumbs, failed-request capture, or auto session tracking.
- Sentry gets technical failures and explicitly classified blockers; usage and successes go to TelemetryDeck.

## Related docs

`Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md` (the release gate on dSYMs), `Cloud/Documentation - Cloud - MCP Mirror.md` (the URL invariant), the repo's `SECURITY.md`.

## Sidekick conversation backend

`SidekickDiagnostics.swift` is the structure-only boundary for conversation storage, legacy
migration, explicit message delivery, questions/answers, attention, memory, context construction,
history retrieval, background compaction, task lifecycle and reset. It does not replace existing
provider, native-capture or connector diagnostics, and never records an additional tool transcript.

Call `SidekickDiagnostics.event(stage, outcome:reason:taskID:attemptID:backend:source:counts:duration:)`
at a meaningful lifecycle boundary or durable commit. Call `failure(stage, reason:...)` for a
backend defect. The stage, outcome, reason, provider, source and count keys are closed enums;
identifiers are UUIDs; measurements are nonnegative bounded integers or finite bounded durations.
No API accepts arbitrary extra fields, an `Error`, message text, memory text, quoted replies,
paths, tool arguments/results, screenshots or provider output. Invalid measurements reject the
whole observation before reaching any sink. The return value reports whether a structurally
valid observation was accepted, not whether consent permitted an upload.

| Signal | Purpose and consent |
|---|---|
| `sidekick.backend` breadcrumb | Structure-only lifecycle context, subject to existing Sentry startup/crash-report consent. |
| `sidekick.backend_failed` | Defects grouped by phase, reason, backend and source; task and attempt UUIDs are extras, never issue fingerprints. Uses existing operation deduplication and a 15-minute repeat cooldown. |
| `Sidekick.backend` | Counts, duration and categorical outcomes through **extended** TelemetryDeck consent. Task/attempt UUIDs are removed. Existing core task-end and submission signals stay independent. |
| Local `DiagnosticHistory` error | Backend defects pass through the existing bounded, scrubbed technical ledger, independently of upload consent. No conversation or memory content is added to exports. |

Expected Stop, cancellation, interruption, stale callbacks, duplicate delivery, exhausted budget,
changed sources, foreground contention, quota and unavailable-provider outcomes become ordinary
health observations rather than Sentry defects. Failures require an explicit reason; `.none`
is rejected. Do not log a provider failure again here when its existing owner already explains
it, except to record a distinct backend consequence such as failure to preserve a message.

Useful instrumentation points:

* Store open/migration: schema outcome, imported task/event counts, and elapsed time. Report
  corruption/newer schema/failed persistence accurately; success follows commit.
* Delivery: committed message/question/answer counts; a failed write never reports delivery
  success. Attention reports requests/presentation outcomes without the message body.
* Lifecycle: task/attempt start and terminal outcome, recovered unfinished tasks, and resets.
  Keep stable logical-task and per-attempt UUIDs distinct.
* Memory: successful read/write byte counts, conflict or atomic-write failure. A save is
  independent of the eventual task outcome.
* Context: encoded UTF-8 byte size, retained messages and omitted events. These measurements
  are not token counts; no tokenizer estimate is reported as measured provider usage.
* Compaction: start, completed-prefix installation, covered sequence, event/summary byte counts,
  duration and stale/skipped/failure outcomes. Do not
  report a snapshot as installed before its generation/sequence check and durable commit.

Use commit/batch totals rather than per-token, per-poll or raw tool-stream reporting. These
signals supplement existing task metrics; do not add their counts to `Sidekick.taskEnded`.

`Scripts/test_sidekick_diagnostics.py` compiles the complete production Sidekick diagnostics
implementation with inert sinks. It reuses the production Sentry dispatch guards, analytics
consent-tier guard and shared repeat limiter, checking typed payloads, rejected measurements,
UUID exclusion from analytics/fingerprints, expected outcomes, independent opt-outs, concurrent
failure deduplication and cooldown boundaries. It neither starts SDKs nor sends external events.

Clear chat emits `Sidekick.backend` with phase `chat_clear` at start/completion, plus bounded elapsed
time. Busy or canceled operations use skipped outcomes; stop timeout/storage failure use the existing
Sentry warning and deduplication path. No message, instruction, knowledge content or path is logged.

Foreground route loss/recovery emits phase `connectivity` with started/unavailable or completed/none
through the same consent-controlled breadcrumbs and extended analytics. A route hint does not emit
a failure or cancel the task. Native tool failures retain categorical evidence independently of
the eventual task outcome; classification no longer decides whether the agent continues.
Raw native error excerpts are reserved for the model's local tool response and never enter these sinks.
## Computer-use recovery and explicit support reports

Native tool errors are observations, not task endings. Individual `agent.tool_failed` and native
capture failures are informational and do not mark their operation failed. Recovered runs are
informational too; unresolved task outcomes retain their own severity. Extended analytics
`ComputerUse.recovery` records task outcome, tool recovery category, error count and omitted-event
count. `ComputerUse.checkFinished` records only the explicit check's source, backend, outcome and
repair verification. Neither event contains tool arguments, raw errors or app/window content.

`BuildIdentity.identifier` is the loaded Mach-O binary UUID (the app's debug dylib in Xcode Debug
builds). It is an artifact identifier, not an installation or device identifier. Sentry and
TelemetryDeck include `app_binary_id`, and schema-4 diagnostic exports include it alongside the
last content-free computer-use check. Version/build numbers alone can identify several distinct
development binaries.

The optional **Send report** flow is independent of automatic Sentry/analytics consent. It sends
only the report the user just previewed, to Supabase, with a dedicated anonymous support identity.
It never uploads the existing full export, which can contain prompts and an account email.
`ComputerUseCheckReport` retains structured native/RPC/system codes but excludes `modelError`.
The server accepts only this schema; clients cannot read other users' reports or overwrite a
receipt. No credentials are persisted in the report, logged, or followed across HTTP redirects.
The new backend migration must be applied by the release owner; it is not deployed by local tests.
