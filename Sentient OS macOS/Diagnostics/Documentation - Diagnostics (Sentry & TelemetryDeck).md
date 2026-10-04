# Diagnostics (Diagnostics/): crash reporting, structured events, and product analytics

Basic usage counts and optional technical reports help us improve this open-source app without
collecting people's knowledge or task content for product analytics. **Sentry** reports crashes,
hangs and structured errors. **TelemetryDeck** reports counts, timings, setup progress and app health.

Both run in Release builds. Crash reports and extended analytics have separate Settings → System
controls, enabled by default. Turning crash reports off stops Sentry. Turning extended analytics off
leaves basic usage, launch/session and install/uninstall counts enabled. The services use a generated
per-install identifier, separate from the mirror secret and feedback list, rather than a name or email.

## Files

| File | Job |
|---|---|
| `Log.swift` | `Log()`: the codebase-wide replacement for `print()`. Console output, a Sentry breadcrumb, and in DEBUG a timestamped tee to `/tmp/sentient-dev.log`. Plus `ErrorLabel(error)`: the content-safe way to log an error. |
| `CrashReporting.swift` | Sentry: the two gates, `captureEvent`, `capture(error)`, breadcrumbs, the PII scrubber, the forced-off SDK defaults. |
| `Analytics.swift` | TelemetryDeck: `start`, `signal` (with the two consent tiers), the one minimal install-count ping and its uninstall twin. |
| `ExecutorScoreboard.swift` | The health sink for "AI that DOES things": one Sentry event per DEFECT-shaped fire (failed / refused / not fireable / fired without the STATUS sentinel). Successes go to TelemetryDeck. |
| `SourceHealth.swift` | The sensors' memory: run-over-run listing counts per source (a healthy count that craters to zero = `<source>.listing_collapsed`) and a rolling 7-day file-extraction rate. |

## The gates

Nothing reaches Sentry unless BOTH hold: a **Release build** (`start` no-ops in DEBUG; there is no
debug bypass, so verify from a Release build) and the **crash-reports opt-out** (`diagnosticsEnabled`,
default on, the "Share crash reports" toggle). TelemetryDeck boots in Release
unconditionally, because its always-on core tier must send; the "Share extended usage analytics" toggle
(`analyticsEnabled`, default on) gates the extended tier per signal. Flipping either toggle calls
`applyEnabledChange()` live. `main.swift` starts Sentry in BOTH process roles (the GUI app and the root
wake helper, tagged `process: app` / `wakeHelper`) and TelemetryDeck in the GUI role only.

## Keeping content out of reports

The reporting contract permits structured technical fields: counts, ratios, booleans, enums, durations, byte buckets, HTTP / exit /
sqlite codes, error type or case names, versions, fingerprints. Never message or note text, file names
or paths, contact names, chat ids, drafts, codex output, transcripts, or the mirror token. The implementation uses these defenses:

- **Clean at the source.** `captureEvent` takes only enums and counts the caller controls. Content-bearing `Log()` lines are `#if DEBUG` (Sentry never boots in DEBUG, so they can never become a breadcrumb). Error paths log `ErrorLabel(error)`, never `\(error)` or `localizedDescription`: in Release it renders the enum case or type name only ("CLIError.exitFailure"), because error payloads embed content (codex stderr, note titles in file paths). The pipeline logs only a bucket key's scheme (`CycleStore.scheme`), never the key.
- **The scrubber backstop** (`beforeSend` / `beforeBreadcrumb`): redacts home-directory paths (the WHOLE remainder, since a folder name is PII), external-volume paths, the mirror password's `/p_…` URL segment, emails, phone runs, and high-entropy long tokens (≥1 uppercase or digit, so snake_case event names survive) from message, exception, and breadcrumb text and breadcrumb `data` strings. It does NOT touch `tags` / `extra`; those are structure-only by contract, so never put free text there.
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

## Analytics signals (`Analytics.signal`)

Two consent tiers. The **core** tier keeps sending when analytics are opted out and is disclosed in the
toggle's own off-state caption; the current core categories include how many people use Sentient (the install
ping + the SDK's session signals), `Command.submitted` (Sidekick / command-bar fires), `Proactive.prepared`
and `Proactive.actionFired` (cards made and fired), `Scheduler.overnightCompleted`, and `Home.opened`.
Everything else is **extended**: `Onboarding.completed`, `Processing.completed` (counts), `Engine.reloaded`,
`Scheduler.overnightStarted` / `.gated` / `.caution` / `.autoEnabled`, `KnowledgeBase.built` / `.updated` /
`.failed` / `.staleSwapAverted`, `Proactive.decided`, `ComputerUse.finished` (agent seconds as
`floatValue`, summed into total agent time), `Mirror.enabled` / `.pushed` / `.disabled` / `.regenerated`,
`Source.connected`, `Model.downloadCompleted`, `PermissionGate.shown` / `.continued`, `PlanGate.*`,
`Notify.notAuthorized`. Every signal auto-stamps the model file name.

**The minimal install ping** (`countInstallOnce`): one direct POST to TelemetryDeck's ingest with a
throwaway random hash, separate from the persistent diagnostics identifier, an empty payload, and no device info, fired at most once
per install (latched only after a 2xx) even when analytics are opted out; the one number that is
attempted across installs independently of the extended-analytics setting. `countUninstall` is its farewell twin, fired as the teardown begins.

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
- Structure only in events and signals; content-bearing logs are `#if DEBUG`.
- Never re-enable the SDK's network breadcrumbs, failed-request capture, or auto session tracking.
- Sentry gets defects; usage and successes go to TelemetryDeck.

## Related docs

`Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md` (the release gate on dSYMs), `Cloud/Documentation - Cloud - MCP Mirror.md` (the URL invariant), the repo's `SECURITY.md`.
