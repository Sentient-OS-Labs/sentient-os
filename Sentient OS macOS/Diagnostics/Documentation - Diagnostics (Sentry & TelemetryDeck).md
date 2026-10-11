# Diagnostics (Diagnostics/): crash reporting, structured events, and product analytics

Basic usage counts, reviewed Sidekick workflow descriptions and optional technical reports help us
improve this open-source app. **Sentry** reports crashes, hangs and structured errors.
**TelemetryDeck** reports usage and reviewed workflow phrases, plus optional timings, setup progress
and app health. Raw task content is not an analytics payload; the phrase review and its limits are
described below.

Both run in Release builds. Crash reports and extended analytics have separate Settings → System
controls, enabled by default. Turning crash reports off stops Sentry. Turning extended analytics off
leaves basic usage, launch/session and install/uninstall counts and reviewed task descriptions enabled.
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
| `Notch Magic/SidekickTaskSummary.swift` | Stages one workflow phrase, invalidates stale candidates and obtains a separate review before the typed analytics sink can accept text. |
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
technical-event and ordinary-signal contract. Reviewed task descriptions have one separate, typed
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

## Reviewed Sidekick task descriptions

For an eligible user-requested Sidekick attempt, the selected AI can stage a short, generalized
workflow phrase through `describe_task_usage`. It runs after task actions and instruction updates,
before the final status. Further tool activity or a user answer invalidates a stale candidate.
Completion consumes the candidate once, and background review does not retain the task lock.

`SidekickTaskSummary` first checks the phrase's size, word count and character envelope. A separate
tool-free model call receives only that phrase and the review rules, without the original prompt,
screens, history or tools. The rules exclude identifying and sensitive details and require rejection
when uncertain. A strictly parsed Boolean response can approve only the original phrase. Errors,
malformed responses, rejection or missing text produce no phrase and no rejection reason downstream.

`Analytics.recordTaskSummary` accepts only the reviewer's `Approved` value. Its event contains the
approved phrase, if available, plus bounded source, method, outcome, availability and schema fields.
The phrase is the sole free-text analytics exception. The local checks and model review reduce
disclosure risk; they do not prove anonymity or rule out every identifying or sensitive meaning.
Generated identifiers can associate repeated events and do not sanitize text.

This reporting remains enabled in Release when extended analytics is off. Debug neither sends the
event nor spends a background model call on its review. The UI disclosure is shared through
`PrivacyCopy`; keep it and `SECURITY.md` consistent with this behavior.

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
- Structure only in technical events and ordinary signals; reviewed task descriptions use their
  typed sink exclusively. Content-bearing logs are `#if DEBUG`.
- Never re-enable the SDK's network breadcrumbs, failed-request capture, or auto session tracking.
- Sentry gets technical failures and explicitly classified blockers; usage and successes go to TelemetryDeck.

## Related docs

`Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md` (the release gate on dSYMs), `Cloud/Documentation - Cloud - MCP Mirror.md` (the URL invariant), the repo's `SECURITY.md`.
