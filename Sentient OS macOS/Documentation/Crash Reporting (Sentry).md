# Crash Reporting (Sentry)

`CrashReporting.swift` wires the app to [Sentry](https://sentry.io) so we get crash logs,
unhandled errors, and performance/profiling from real runs. It's the "black box" for diagnosing
a crash we can't reproduce — including a crash during the root overnight run, when nobody's
watching. Runtime reporting needs only the DSN (already in the code); readable production stack
traces additionally need the Release dSYM-upload build phase (below).

## How it boots

`main.swift` calls `CrashReporting.start(_:)` first thing — in **both** process roles, before any
other code runs:

```swift
if CommandLine.arguments.contains(WakeHelperConfig.helperFlag) {
    CrashReporting.start(.wakeHelper)   // the root --wake-helper LaunchDaemon (overnight path)
    WakeHelper.run()
} else {
    CrashReporting.start(.app)          // the normal GUI app
    SentientOSApp.main()
}
```

Each role tags every event with `process: app` or `process: wakeHelper`, so a 3am overnight-run
crash is told apart from a UI crash in the dashboard.

`start(_:)` boots Sentry with everything on: native crash handler + attached stack traces,
app-hang ("beachball") detection, release-health sessions, 100% trace sampling, and trace-lifecycle
profiling. It's idempotent (guarded by `started`) and a no-op if the DSN is blank.

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

## Dev verification (DEBUG only)

DEV TOOLS → **More** → **SENTRY** row:
- **Send test event** → `CrashReporting.sendTestEvent()`, a non-fatal event; appears in Issues in
  seconds. Good for confirming the pipeline + breadcrumbs.
- **Force crash** → `CrashReporting.forceCrash()`, a hard crash. The report uploads on the **next
  launch** (that's how native crash capture works).

⚠️ **Sentry does not capture crashes while the Xcode debugger is attached** — LLDB eats the signal.
To test a crash, run the built `.app` **standalone** (not ⌘R), crash, then relaunch.

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

- `CrashReporting.swift` — init, breadcrumbs, `capture(_:)`, dev test helpers.
- `main.swift` — `start(.app)` / `start(.wakeHelper)`.
- `Log.swift` — breadcrumb tee.
- `Views/DevToolsView.swift` — the DEBUG SENTRY test buttons.
- `.sentryclirc` (gitignored) — Auth Token + org/project for dSYM upload.
- Build phase **"Upload dSYMs to Sentry"** in the app target (Release-only).
