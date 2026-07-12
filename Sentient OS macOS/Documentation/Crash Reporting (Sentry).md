# Crash Reporting (Sentry)

`CrashReporting.swift` wires the app to [Sentry](https://sentry.io) so we get crash logs,
unhandled errors, and app-hangs from real runs. It's the "black box" for diagnosing a crash we
can't reproduce — including a crash during the root overnight run, when nobody's watching. Runtime
reporting needs only the DSN (already in the code); readable production stack traces additionally
need the Release dSYM-upload build phase (below). Sentry is the smoke detector, NOT an APM: there
is no performance tracing or profiling (see the options note below).

## How it boots

`App/main.swift` calls `CrashReporting.start(_:)` first thing — in **both** process roles, before
any other code runs:

```swift
if CommandLine.arguments.contains(WakeHelperConfig.helperFlag) {
    CrashReporting.start(.wakeHelper)   // the root --wake-helper LaunchDaemon (overnight path)
    WakeHelper.run()
} else {
    CrashReporting.start(.app)          // the normal GUI app
    Analytics.start()                   // product analytics (TelemetryDeck) — GUI app only
    SentientOSApp.main()
}
```

Each role tags every event with `process: app` or `process: wakeHelper`, so a 3am overnight-run
crash is told apart from a UI crash in the dashboard.

`start(_:)` boots Sentry with the crash surface on — and only the crash surface (curated
2026-07-12):

- **Native crash handler + attached stack traces**, PLUS `enableUncaughtNSExceptionReporting =
  true` — ⚠️ that flag **defaults OFF on macOS** (unlike iOS), so without it a whole class of
  AppKit/ObjC crashes silently never reports.
- **App-hang ("beachball") detection at 10s** (`appHangTimeoutInterval = 10`, not the SDK's 2s
  default — 2s paged us for harmless onboarding/codex-install stalls all through the beta).
- **No tracing, no profiling.** The old 100%-traces + profiling config never produced a single
  ingested transaction (the SDK's auto-instrumentation is UIKit-shaped; macOS SwiftUI generates
  none) — deleted as dead weight.
- **⚠️ `enableNetworkBreadcrumbs = false` and `enableCaptureFailedRequests = false` — a LEAK
  GUARD, never re-enable.** Both SDK defaults record full request URLs, and the MCP mirror URL
  carries the user's mirror password in its path (§8's "request paths must NEVER be logged").
  Found leaking a real password into stored events on 2026-07-12; the events were deleted and
  both flags forced off. The `beforeBreadcrumb` scrub of `crumb.data` is the backstop only.

It's idempotent (guarded by `started`), a no-op if the DSN is blank, and — the two hard gates — a
no-op in DEBUG and whenever the `diagnosticsEnabled` opt-out is off (the full gate story:
`Diagnostics (Sentry).md`).

⚠️ **Auto session tracking is deliberately OFF** (`enableAutoSessionTracking = false`). Release-
health sessions are a "how many people use Sentient" signal, and **all** usage counting belongs to
the *analytics* toggle (TelemetryDeck), never the *crash* toggle. If it were on, a user who keeps
crash reports on but opts OUT of analytics would still be counted here — which would break the
promise the analytics toggle makes. Sentry therefore reports crashes, errors, and hangs only;
user/session counting lives solely in `Analytics.swift`. (This costs us Sentry's crash-free-
session % — TelemetryDeck's counts plus crash volume cover it.)

## The DSN — safe in the code

The DSN is a plain constant at the top of `CrashReporting.swift`. **This is not a secret and is
fine to ship publicly** (even when the repo goes open source): a DSN is write-only/ingest-only — it
can only push crash events *in*, never read data out, touch the account, or delete anything. Every
shipped Sentry app embeds its DSN in the binary anyway. The only abuse vector is event-quota spam,
handled by Sentry's inbound filters + rate limits, and the DSN rotates in one click if needed.

> Contrast with the **Auth Token** used for dSYM upload (below) — *that* one is a real bearer
> credential (full read/write/delete on the org) and must NEVER be in the repo or the binary.

## Breadcrumbs from `Log()`

Every `Log()` call (Log.swift) also feeds a Sentry breadcrumb, so a crash report arrives carrying
the recent log trail that led to it. No-op until Sentry has started.

**⚠️ That means every non-`#if DEBUG` `Log()` line SHIPS in Release.** Two rules keep the trail
content-free:
- Content-bearing logs (prompts, transcripts, codex output, proactive dumps) are `#if DEBUG`.
- Error paths use **`ErrorLabel(error)`** (Log.swift), never `\(error)` or
  `error.localizedDescription`: in Release it renders the enum case / type name only
  ("CLIError.exitFailure"), in DEBUG the full description. Raw interpolation leaked codex stderr
  (which embeds Gmail/calendar/screen content) and note titles through ~22 error logs until the
  2026-07-12 sweep — don't reintroduce.

## Verifying the pipeline

Sentry **never initializes in DEBUG** — there is no debug bypass, and the old dev-pane test
buttons (`sendTestEvent`/`forceCrash`) were removed when that gate landed. To verify: build
**Release**, run the app, and exercise a real path (any structured event, or a forced crash via a
temporary `fatalError`). The pipeline was proven end-to-end on real hardware — see
`Diagnostics (Sentry).md`.

⚠️ **Sentry does not capture crashes while the Xcode debugger is attached** — LLDB eats the signal.
To test a crash, run the built `.app` **standalone** (not ⌘R), crash, then relaunch (the report
uploads on the next launch — that's how native crash capture works).

## Production stack traces — the dSYM upload

A Release crash report only shows raw addresses (`0x1042f8a1c`) unless Sentry has the build's
**dSYM** (debug symbol) files. A Run Script build phase, **"Upload dSYMs to Sentry"**, uploads them
automatically — **Release only** (Debug has symbols locally; the phase skips with a log line).

- Tool: `sentry-cli` (`brew install getsentry/tools/sentry-cli`).
- Auth + org/project: read from **`.sentryclirc`** at the project root — **gitignored**, because it
  holds the Auth Token (a real secret). Each dev/CI keeps their own copy. Format:
  ```ini
  [auth]
  token=sntrys_...            # an Organization Auth Token from sentry.io/settings/auth-tokens
  [defaults]
  org=sentient-os
  project=sentient-os
  ```
- The phase **fails safe**: every guard exits 0, so a missing token, missing `sentry-cli`, or a
  failed upload never breaks the build — Debug builds, OSS clones, and CI without the config just
  skip it.
- ⚠️ **Fail-safe cuts both ways — the phase fails SILENTLY.** Field lesson (2026-07-12): the first
  beta DMG shipped with no dSYM on Sentry — it was built on a Mac whose gitignored `.sentryclirc`
  didn't exist, and the other Mac's copy held a dead (revoked) token — so every beta crash/hang
  arrived unsymbolicated ("Processing Error" badge, `<redacted>` frames). **Both dev Macs need a
  current `.sentryclirc` at the repo root** (hand-copy it — AirDrop/Signal, never commit), and
  after any Release/Archive build it's worth glancing at the build log for the
  "Sentry: uploading dSYMs" line. A missed build can be repaired after the fact:
  `sentry-cli debug-files upload --include-sources <archive>.xcarchive/dSYMs`.
  *(Epilogue, 2026-07-12: the main beta build's dSYMs were uploaded after the fact and its events
  symbolicate; three other beta builds' dSYMs were already gone — overwritten Debug products — so
  their events stay unreadable permanently. Keep the archive of any build that leaves a dev Mac.)*
- **`release.sh` now hard-gates on this** (step 2/6, added 2026-07-12): publishing a DMG requires
  its matching dSYMs to be found locally and (re-)uploaded to Sentry, or the release aborts — a loud
  seatbelt over the silent build phase, at the moment it matters. `SKIP_SENTRY=1` opts out knowingly.
  Details: `Auto-Update (Sparkle).md` §Releasing.

Build settings already cooperate: Release is `dwarf-with-dsym`, Debug is `dwarf` (no dSYM, fast),
and user script sandboxing is off so the upload script can reach the network.

## ⚠️ Gotcha: the `TimeoutBox` optimizer landmine (don't reintroduce)

Wiring this surfaced a **pre-existing** Swift compiler crash (not Sentry's fault): a generic
`TimeoutBox<T>` in `Ingestion/IterativeRun.swift` crashed the optimizer's `EarlyPerfInliner` pass on
the generic class's `deinit` layout under `-O`. That segfaults swift-frontend and breaks **every
Release/Archive build** — invisible in Debug (`-Onone`), so it hid until the first archive attempt.

Fix: `TimeoutBox` is now **non-generic**, erasing the element type at the continuation boundary
(it stores a `fire` closure that captures the typed continuation; only an erased `Result<Any, Error>`
crosses the box). Same resume-exactly-once semantics. **Do not make it generic again** — the inline
comment there says why.

## Files

- `Diagnostics/CrashReporting.swift` — init, gates, `captureEvent`, breadcrumbs, `capture(_:)`, the scrubber.
- `App/main.swift` — `start(.app)` / `start(.wakeHelper)`.
- `Diagnostics/Log.swift` — breadcrumb tee.
- `.sentryclirc` (gitignored) — Auth Token + org/project for dSYM upload.
- Build phase **"Upload dSYMs to Sentry"** in the app target (Release-only).
