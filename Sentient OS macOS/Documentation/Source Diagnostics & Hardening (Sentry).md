# Source Diagnostics & Hardening (Sentry) — Implementation Plan

> **STATUS: NOT YET BUILT. This is a design + implementation handoff for the next session.**
> It describes work to *do*, not work that exists. The only Sentry code that exists today is
> `CrashReporting.swift` (crash + error + performance reporting, shipped in PR #81 — see
> `Documentation/Crash Reporting (Sentry).md`). Everything in §4 onward is greenfield.
> Line numbers are a snapshot from the audit (2026-06-30) and will drift — always re-grep before editing.

---

## 0. What this is, in one breath

Add **per-source diagnostics** to Sentient OS: when any source's processing (WhatsApp, iMessage, Notes, Files, Gmail, Calendar, the on-device model, the knowledge base, the mirror, proactive actions, the scheduler, voice/computer-use) **breaks, silently degrades, or a decoder rots because Apple/Meta/Google shipped an update**, we get a precise, **PII-free** report in the Sentry dashboard. Plus a set of **hardening bug-fixes** the audit uncovered, and a new **1-hour-per-source processing cap**.

This is NOT "catch every error." It is: **total crash coverage (already live) + a curated set of high-signal events for the failures that matter + a single catch-all for surprises + strict privacy by construction.** See §1 for the exact coverage boundary.

---

## 1. Goals & non-goals (the coverage boundary — state this, don't drift from it)

**Goals**
- Detect **silent breakage**: a source that stops producing output with no exception (e.g. a WhatsApp schema change zeroing out all groups; an Apple typedstream format change dropping the iMessage decode rate to ~0).
- Detect **decoder rot early**: tag every event with OS/app versions + a schema fingerprint so an update-driven break shows up as a correlated spike on day one.
- Report **real operational failures** (a source dropped, a run aborted, a vault-swap failure, an aborted overnight run) — aggregated, never per-item spam.
- Do all of this **without ever transmitting user content** (messages, emails, notes, drafts, names, phone numbers, file paths, tokens).
- **Opt-out** (default ON): a single "Share anonymous diagnostics" switch gates **all** Sentry reporting (crashes included). *(DECIDED 2026-07-01, Aditya + Jesai — see §13.1.)* Privacy is upheld **by construction, not by the switch**: the PII firewall (§10) means only structure is ever transmitted, never content — on or off.

**Non-goals (explicitly)**
- Not wiring every `throw`/`return nil` in the codebase (there are hundreds). Most "failures" are *normal* (a junk verdict, a quiet Gmail week, an empty bucket, an attachment-only iMessage row). Capturing them would blow Sentry quota, bury signal, and widen the PII surface.
- Not a metrics/analytics product. This is failure diagnostics.

**What's already total (no work needed):** native crashes (signals + unhandled exceptions) are caught exhaustively by the Sentry crash handler shipped in PR #81 — including in code we never audited. If it crashes the process, it's reported.

**The gap a curated approach leaves, and how we close it:** unknown-unknown *caught* errors that don't crash. Closed by a **single catch-all** at the top-level boundaries (§4.9), not by blanket instrumentation.

---

## 2. Background — what exists today (read `CrashReporting.swift` first)

`CrashReporting` is a **caseless `enum`** (an implicitly-`Sendable` namespace) with `nonisolated static` members:
- `start(_ role: Role)` — boots Sentry once per process (`app` / `wakeHelper`), sets options inside `SentrySDK.start { options in … }`. DSN is a public-safe constant. Guarded by a `private static var started` bool.
- `breadcrumb(_ message:)` — called by **every** `Log()` call (`Log.swift`), so the recent log trail rides every event. `guard started else { return }`.
- `capture(_ error: Error)` — non-fatal error capture. **Called from nowhere in the engine today.**
- `sendTestEvent()` / `forceCrash()` — DEBUG-only dev buttons (DevToolsView SENTRY pane).

The whole diagnostics build is: **wire the failure points into `capture`/a new `captureEvent`, add the accumulator + storage + opt-in + scrubber, and fix the bugs.**

---

## 3. The concurrency contract (MUST READ before writing code)

The build sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`project.pbxproj`, both configs) — every unannotated declaration is `@MainActor`. But the diagnostics call sites are NOT on main. Verified isolation:

| Type | Isolation | Why |
|---|---|---|
| `CrashReporting`, `Log`, `LifetimeStats`, `ChatWindowing` | **nonisolated** | caseless-enum / Sendable namespaces (members don't get MainActor inference) |
| `AppState` | `@MainActor` | explicitly annotated |
| `IterativeRun` | **`@MainActor`** | plain struct, unannotated → default |
| `withExtractionTimeout` / `TimeoutBox` | nonisolated | free async func + `@Sendable` closure; `TimeoutBox: @unchecked Sendable` |
| Connectors (`FilesConnector`…), `FilesSource`, `Candidate`/`Artifact` | nonisolated | `Connector: Sendable`, structs are `Sendable` |
| `CycleStore` | **`actor`** | `@ModelActor` |
| The `static` decode helpers (`typedstreamText`, `decodeBody`, `pruneReason`, …) | nonisolated | static funcs, no `self` |

**Proof it already works off-main:** `ChatWindowing.windows(of:)` (nonisolated, called off-main inside a chat connector's `load`) calls `Log()` synchronously → so `Log()` and therefore `CrashReporting.breadcrumb` are *already* invoked off-main and compile. The diagnostics pattern is proven before writing a line.

**Hard requirements this imposes:**
1. `captureEvent` and every capture entry point = **explicit `nonisolated static func`** with **`Sendable` params** (so `@ModelActor`, off-main connectors, and `@Sendable` dispatch closures can call with no `await`, no executor hop). Mark them `nonisolated` explicitly (copy the `SQLiteDB.swift` idiom) so a future annotation on the enum can't silently pull them onto MainActor.
2. `SourceFault` = a `Sendable` value type (only `String`/scalar/`[String:String]` fields → trivially synthesized).
3. `diagnosticsEnabled` and all rolling-window counters live in **`UserDefaults`, NOT `CycleStore`.** The connector call sites are **sync nonisolated** funcs that physically cannot `await` the `@ModelActor`. `UserDefaults` is thread-safe + synchronous (this is exactly how `LifetimeStats` and `MirrorClient.isEnabled` already read/write off-main).
4. `beforeSend` scrubber = a pure closure set once inside `SentrySDK.start`'s options block; it runs on the SDK's transport thread — must capture nothing MainActor-isolated.
5. Anomalies are emitted as **events, not breadcrumbs** (see §4.8) so they survive the breadcrumb ring buffer.
6. Minor: `private static var started` is an unsynchronized set-once-before-use bool. Benign in practice; make it set-once/`os_unfair_lock`-guarded if you want it clean (low priority).

---

## 4. New infrastructure to build

### 4.1 `CrashReporting.captureEvent(...)` — the structured event API
Add to `CrashReporting.swift`:
```swift
enum DiagLevel: String, Sendable { case info, warning, error, fatal }

nonisolated static func captureEvent(
    _ message: String,                 // a STABLE, content-free title, e.g. "imessage.decode.degraded"
    level: DiagLevel = .warning,
    tags: [String: String] = [:],      // source, stage, kind, os_version, app_version, schema_fp…
    extra: [String: String] = [:],     // counts/ratios/durations as strings — PII-free ONLY
    fingerprint: [String]? = nil        // explicit grouping key, usually [source, stage, kind]
) {
    guard started, diagnosticsEnabled else { return }
    // SentrySDK.capture(message:) inside withScope { scope in scope.setTags/ setExtras/ fingerprint/ level }
}
```
Implementation notes: use `SentrySDK.capture(message:)` wrapped in `SentrySDK.configureScope`/`withScope` to set tags, extras, level, and `scope.fingerprint = fingerprint` so issues group by **failure mode**, not stack line. Keep `DiagLevel` your own `Sendable` enum; map to `SentryLevel` inside (don't expose the SDK type across the boundary).

### 4.2 `SourceFault` — the standard report slip (optional helper)
A `Sendable` value type the sources build and hand to `captureEvent`. Fields: `source` (SourceKind.rawValue), `stage` (enum: listing/copy/query/decode/extract/connect/run/parse/write), `kind` (a stable per-source failure-kind string = the fingerprint key), `severity` (DiagLevel), `context: [String:String]`. A thin convenience over `captureEvent`; you can also just call `captureEvent` directly. Keep it a struct with no reference members.

### 4.3 The diagnostics accumulator — `RunDiagnostics` (the tally-keeper)
**Why it's needed:** the decode sub-counts (per-stage decode failures, prune reasons, member-query degradations) are produced inside **`static` decode helpers with no `self`**, and `Connector.buckets()` returns `[Bucket]` which can't carry per-listing counts (the grain is per-source-call, not per-bucket). A stored property on the connector can't work either (`buckets()` is `throws`, non-`mutating`, and connectors are fresh per run). **The only path that reaches the static decoders without changing five signatures is a shared singleton the decoders write into.**

Shape:
```swift
// An actor OR an os_unfair_lock-guarded final class. Holds a per-run scratchpad keyed by SourceKind.
// Sources write sub-counts into it during listing/decode; IterativeRun reads it at run-end.
final class RunDiagnostics: @unchecked Sendable {
    static let shared = RunDiagnostics()
    // beginRun(runID:), record(source:key:count:), snapshot(source:) -> [String:Int], endRun()
    // Thread-safe (lock-guarded RMW). Reset per run.
}
```
- Keyed by `SourceKind` (+ `bucketKey`/`root.id` where the grain is per-bucket, e.g. Files is per-root).
- Written from the sync nonisolated decoders (lock makes that safe).
- Read once at IterativeRun run-end to assemble the aggregated event and to update `SourceHealth`.
- Reset at run start (a per-run ID prevents cross-run bleed).

### 4.4 `SourceHealth` — the rolling-window / anomaly store (the memory book)
UserDefaults-backed, modeled on `LifetimeStats` (single-key `[String:Int]` dict, non-atomic RMW — fine for approximate counters), **plus an epoch-bucket eviction dimension `LifetimeStats` lacks** (bucket by hour/day, prune buckets older than the window on each write). Use a **separate key** (e.g. `stats.sourceHealth`) so it never collides with or gets wiped by `LifetimeStats.reset()`.

Stores per source:
- **`lastListingCount`** per bucket key (for the run-over-run anomaly compare — see §8/R1).
- **Rolling decode/extraction-rate windows** (attempted vs succeeded, bucketed by epoch) for the per-item sensors (§8/R2).

Reads/writes are sync + thread-safe (UserDefaults) so the off-main decoders and the `@MainActor` IterativeRun can both touch it with no hop.

### 4.5 The opt-out gate — `diagnosticsEnabled`
**DECIDED (2026-07-01, Aditya + Jesai): opt-OUT, default ON, and the switch gates ALL Sentry (crashes included).** One "Share anonymous diagnostics" switch controls every report the app sends.
- Storage: **UserDefaults key `diagnosticsEnabled`, default `true`.** ⚠️ `UserDefaults.bool(forKey:)` returns `false` for an *unset* key, which would wrongly read as "off" on first launch — so either register the default (`UserDefaults.standard.register(defaults: ["diagnosticsEnabled": true])` early in `main.swift`) or read via an `object(forKey:) == nil ? true : bool(...)` helper. The `register` approach is cleanest and keeps the static reader trivial.
- Read: a `nonisolated static var diagnosticsEnabled: Bool { UserDefaults.standard.bool(forKey:) }` on `CrashReporting` (mirrors `MirrorClient.isEnabled`; relies on the registered default). Off-main sites read it with no hop.
- App-facing: add `var diagnosticsEnabled` to `AppState` mirroring the existing `hasCompletedOnboarding` UserDefaults-`didSet` pattern (AppState.swift ~37–40), so SwiftUI binds to it.
- **Gate placement:** at `CrashReporting.start()` — if `!diagnosticsEnabled`, don't call `SentrySDK.start` → `started` stays false → every downstream call (crash handler AND diagnostics) is a zero-cost no-op via the existing `guard started`. This is what makes the single switch gate *everything*. For mid-session opt-back-in, call `start()` at toggle time; for mid-session opt-out of an already-started SDK, the `guard started, diagnosticsEnabled` in `captureEvent` covers the diagnostics path, and call `SentrySDK.close()` to stop crash reporting too.
- **This gates crash reporting too** — a change from today, where crash reporting starts whenever a DSN is set. Move the `start()` call behind the flag in `main.swift` (§9). Rationale for the whole-Sentry gate: one honest switch, one clean privacy story; and because the PII firewall (§10) means we transmit only structure regardless, default-ON is safe.

**DECIDED (2026-07-01): Sentry runs in RELEASE builds only, never DEBUG.** A build-config gate that sits **on top of** the opt-out flag — both must pass for anything to reach Sentry. Our own dev machines run the Debug build day-to-day (Dev Notes §two-builds), and we don't want dev crashes, self-test noise, or half-finished-feature errors polluting the production dashboard (or the release-health / session metrics).
- **Implementation:** wrap the actual `SentrySDK.start` body in `#if !DEBUG`. In DEBUG, `start()` returns early *without* setting `started = true`, so every downstream call stays a zero-cost no-op via the existing `guard started`. (Today `start()` sets `options.environment = "debug"/"release"` but boots the SDK either way — the change is to not boot at all in DEBUG.)
- **⚠️ Dev-button interaction:** the DEBUG-only `sendTestEvent()` / `forceCrash()` (SENTRY dev pane) need `started == true`, so a plain `#if !DEBUG` guard would make them dead. Keep them testable by having those two dev entry points call a **`startForDevTest()`** that boots the SDK explicitly (bypassing both the `#if !DEBUG` and the opt-out flag) — so a dev can still verify the Sentry pipeline from a Debug build on demand, but nothing auto-reports in DEBUG. Alternatively drop the dev buttons entirely and verify only from a Release/TestFlight build; confirm which you prefer.
- The `environment` tag stays (`"debug"` only ever appears via the explicit dev-test path, `"release"` for real traffic), so the dashboard can still filter.

### 4.6 The `beforeSend` scrubber (the bouncer — defense in depth)
Set `options.beforeSend` inside the existing `SentrySDK.start { options in … }` block in `CrashReporting.start`. A pure `(Event) -> Event?` that redacts, as a final net:
- Home-dir paths (`/Users/<name>/…` → `/Users/<redacted>/…`).
- Email addresses, phone numbers, long tokens/base64 blobs (regex).
- Over-length free-text fields.
Also set `options.beforeBreadcrumb` (same rules) since `Log()` breadcrumbs could carry the existing leaks until B7 is fixed. Runs on the SDK thread — capture nothing MainActor-isolated.

### 4.7 The version / schema fingerprint stamp (the ID stamp)
On **every** diagnostics event, attach as tags:
- `os_version` (`ProcessInfo.processInfo.operatingSystemVersion`), `app_version` (Info.plist).
- For DB sources: `schema_fp` = a stable hash of the DB's column/table names (compute once per listing from the `PRAGMA`/known column set). When WhatsApp/Apple ship a schema change, this value shifts and all failures correlate to it.
- For the model: `model_version`, `metal_version`. For cloud: `codex_version`.
Centralize this in `captureEvent` (auto-add OS/app versions to every event's tags) so no call site forgets.

### 4.8 Event vs breadcrumb discipline (quota + the ring-buffer trap)
- Sentry's default `maxBreadcrumbs` is **100** (a ring buffer). `Log()` breadcrumbs every call; a run logs hundreds–thousands of lines. So a per-item breadcrumb trail **evicts the actual signal** before a crash.
- **Rule 1 — anomalies/failures are `captureEvent` (events), which are NOT breadcrumb-capped.** This is the single most important choice; it makes diagnostics robust to volume by construction.
- **Rule 2 — do NOT breadcrumb per item.** Don't route the high-frequency per-item verdict log (IterativeRun ~154, already DEBUG-only) into breadcrumbs. Consider category-gating `Log()`'s breadcrumb emission.
- **Rule 3 — one aggregated event per run**, gated (§7.1). Never per-item.
- Optional: raise `options.maxBreadcrumbs` to 200–300 (cheap for a single-user app) — secondary to Rules 1–2.

### 4.9 The catch-all net (surprises)
One generic `unexpected_error` capture at the **top-level boundaries only**: the IterativeRun run wrapper, the `CodexCLI.run`/`runAgentCommand` spine, and `ProactiveExecutor`/`CommandRunModel`. Any caught error that isn't one of our known typed cases → `captureEvent("unexpected_error", …)` **once**, deduped by fingerprint (`[boundary, String(describing: type(of: error))]`), error **type name only** (never `.localizedDescription`/`.description` — those embed content, e.g. `CLIError.exitFailure`'s stderr). Sample if needed. This surfaces novel failures without instrumenting all ~200 sites.

### 4.10 A telemetry sink distinct from `Log()` (the PII firewall)
`Log()` auto-feeds breadcrumbs, and the voice/command/executor files already `Log()` raw transcripts, drafts, and codex play-by-play. To make the firewall **structural** (not discipline-dependent), the diagnostics path must be a **separate call** (`captureEvent`) that only ever takes enums/counts/bools/durations/error-type-names — never a free string interpolating user content. A dev writing `Log("heard: \(text)")` then can't accidentally ship it, because `Log()` → breadcrumb is scrubbed by `beforeBreadcrumb` (§4.6) and the *events* never touch that text.

### 4.11 The anonymous install-id (correlation without identity)
**DECIDED (2026-07-01): a separate anonymous install-id, NOT the mirror token.** So we can see "this one machine has recurring WhatsApp faults across runs" without ever linking a report to a person or to the user's knowledge-base identity.
- A fresh **random UUID minted once** (`UUID().uuidString`) on first launch, stored under its own UserDefaults key (e.g. `diagnostics.installID`). Never derived from hardware, never the mirror token (§8 mirror), never `NSUserName()`.
- Set it as Sentry's `scope.setUser(User(userId:))` inside `SentrySDK.start`'s options block (or a tag if you'd rather not use the `user` field) so every event/crash carries it automatically — no per-call-site work.
- It resets if the user clears app data / reinstalls; that's fine — this is coarse per-install correlation, not a durable identity. Honors the no-accounts principle: it can't be tied back to a human, and it's independent of the mirror token so the two can't be cross-referenced.

---

## 5. The 1-hour per-source processing cap (NEW FEATURE)

**Behavior:** during a run, each **source** (connector) gets a **60-minute budget**. If a source is still processing after 60 minutes, stop it where it is and move to the **next source**. Progress is preserved (each item already commits its mark atomically → the cut-off source resumes where it left off next run). A source hitting the cap emits a diagnostics event.

**Why it's safe by construction:** IterativeRun commits per item (`advance` in iterative, `sinkFloor` in initial) in one atomic store write, so breaking mid-source cannot corrupt or lose progress — it just pauses.

**Implementation (on-device sources — `IterativeRun.run`):**
- The connector loop is `runLoop: for connector in connectors` (~168). At the top of each connector iteration, record `let connectorDeadline = Date().addingTimeInterval(3600)`.
- Add a label to the bucket loop: `bucketLoop: for bucket in buckets`.
- Inside the per-item loop (`for w in work`, ~224), before processing each item, check:
  ```swift
  if Date() >= connectorDeadline {
      CrashReporting.captureEvent("source.hit_time_cap", level: .warning,
          tags: ["source": connector.kind.rawValue],
          extra: ["processed": String(processedThisConnector), "cap_seconds": "3600"])
      break bucketLoop   // exits the item loop AND the bucket loop → next connector
  }
  ```
  `break bucketLoop` from inside the item loop exits both loops and continues `runLoop` to the next connector. The timer spans **all of a source's buckets** (Files has one bucket per root; chats one per chat) — correct, since the cap is per-source.
- Track `processedThisConnector` (reset per connector) for the event's `extra`.

**Cloud sources (Gmail / Calendar legs):** these run *outside* IterativeRun (in `OvernightScheduler.runProcessing` / `ProcessingView.run`). They have per-call codex timeouts but the *source-level* total can exceed an hour (Calendar's initial is 12 sequential monthly reads at 600s each = up to 2h). **Wrap each cloud leg in the same 60-minute budget** (a `Task` + deadline, or check elapsed between windows/months and stop early). Same resume semantics — they advance a per-source mark. Emit `source.hit_time_cap` with `source: gmail|calendar`.

**Diagnostics value:** a source that *regularly* maxes its hour is a "slow or stuck" signal. Track cap-hits per source in `SourceHealth`; alert if a source hits the cap on N consecutive runs.

**DECIDED (2026-07-01): wall-clock** (the `Date() >= connectorDeadline` sketch above). Overnight runs hold the Mac awake (keep-awake assertion), so wall-clock ≈ active-processing time there; for foreground runs it's naturally wall-clock. Active-processing tracking was rejected as complexity that buys nothing given the keep-awake. Resume-next-run makes any mid-run cut-off harmless regardless.

---

## 6. P0 — bug fixes (DO FIRST, as their own PR, before any logging)

These are real bugs the audit found; some are data-loss/security. Fix + verify before instrumenting. Line numbers are snapshot — re-grep.

> **STATUS (2026-07-01, unmerged — needs real-run testing before docs go true):**
> ✅ **B1, B2, B3, B4, B5, B8, B9 FIXED** (isolated Debug build green). Each used the existing `CrashReporting.capture(error)` on its critical failure path (structured `captureEvent` upgrade comes in P2). ⏳ **B10, B6, B7 DEFERRED** with rationale (see each below) — none is a standalone user-facing bug: B10 is a refactor whose only payoff is P2/P3 sensors, B6 is new scheduler-feature work, B7 only bites once Sentry is on (P1+). Do them alongside the phase that needs them, not in the P0 PR.
> **Still to verify (ask Aditya/Jesai to test):** B8 → a previously over-skipped folder now yields more files; B1 → force a `VaultCloud.update` error and confirm the vault is restored from `.bak`; B5 → the deadman stays armed if `pmset` fails.

### B1 — VaultCloud restore can destroy the knowledge base (CRITICAL, data loss) — ✅ FIXED (2026-07-01, unmerged)
**Fix applied:** durable same-volume `.bak` sibling (never defer-deleted); restore uses removeItem→**copy** and deletes `.bak` only after the copy verifiably succeeds (a failed restore always leaves `.bak` intact); a top-of-`update()` recovery restores from `.bak` if a prior run died mid-restore; `updateResumeSessionID` is now persisted to UserDefaults (`vault.update.midEditSessionID`, loaded in `init`) so a restart resumes instead of abandoning a half-merged vault; `CrashReporting.capture` on the restore-failed path.

`VaultCloud.swift` `update()` restore path (~127–132): on a codex error it does `try? removeItem(vault)` then `try? moveItem(snapshot → vault)` — **both swallowed** — and a `defer` (~98) deletes the snapshot on **every** exit. If `removeItem` succeeds and `moveItem` fails, the vault **and** its snapshot are both gone → total, silent, unrecoverable loss of the user's canonical knowledge base.
**Fix:** move the snapshot to a durable `.bak` (not a defer-deleted temp); on error, restore from `.bak`; only delete `.bak` after a verified successful commit/restore. Then a critical Sentry event `vault_restore_failed` on the failure path. Also persist `updateResumeSessionID` + a `vault_mid_edit` marker (it's in-memory only today → a restart silently abandons a half-merged vault).

### B2 — VaultGenerator swap can leave zero vaults — ✅ FIXED (2026-07-01, unmerged)
`VaultGenerator.swift` (~157–158): `try? removeItem(root)` then `try moveItem(staging → root)`; the move can throw (disk full, cross-volume, permissions) → no vault on disk.
**Fix applied:** rename the old vault to a same-volume `.bak` first, move staging in, delete `.bak` only on success, restore `.bak` if the move throws; `CrashReporting.capture` on the swap-failed path.

### B3 — MirrorClient mints a predictable token — ✅ FIXED (2026-07-01, unmerged)
`MirrorClient.swift` `mintToken()` (~166): ignores `SecRandomCopyBytes`'s return → on failure the token is 32 zero bytes (predictable identity).
**Fix applied:** `mintToken()` now `throws MirrorError.tokenGenerationFailed` unless `SecRandomCopyBytes == errSecSuccess`; `Keychain.set` returns a `Bool` (`SecItemAdd == errSecSuccess`) and `enable()` throws `.keychainWriteFailed` on a failed persist or a token that doesn't read back. `enable()` is now `throws`; both call sites (HomePopovers toggle, DevToolsView) handle it.

### B4 — MirrorClient treats a non-HTTP response as success — ✅ FIXED (2026-07-01, unmerged)
`MirrorClient.swift` `check()` (~175): if the response isn't `HTTPURLResponse` it returns *success* → a captive portal/proxy marks a never-synced vault as synced and clears `vaultDirty`.
**Fix applied:** non-HTTP response now throws `MirrorError.http(0, …)` (status 0 = no HTTP response).

### B5 — WakeHelper endAwake can leave the Mac awake all day — ✅ FIXED (2026-07-01, unmerged)
`WakeHelper.swift` `endAwake` (~76–83): runs `cancelDeadman()` **before** `pmset disablesleep 0`. If `pmset` fails, `disablesleep` stays 1 and the deadman is already cancelled → Mac awake indefinitely (until the next daemon relaunch's defensive reset). This is the exact failure the deadman exists to prevent.
**Fix applied:** `pmset disablesleep 0` runs FIRST; `cancelDeadman()` only on its success — a failed `pmset` KEEPS the deadman armed as the backstop, and logs it. (The `endAwakeLeftSleepDisabled` overnight-report flag is P2, with the report itself.)

### B6 — AC / thermal / low-power gates don't exist — ⏳ DEFERRED (scheduler feature work, not a P0 bug)
Arch §9 says the overnight run is gated on AC power, `!isLowPowerModeEnabled`, and thermal state. Grep for `IOPSGetProvidingPowerSourceType` / `thermalState` / `isLowPowerModeEnabled` → **zero matches**. They aren't implemented.
**Fix:** implement the gates in `OvernightScheduler.runProcessing` before `beginAwake`, and record their values in the overnight report (they can't be logged until they're measured). **Deferred rationale:** this is *building a missing scheduler feature*, not fixing existing code — it belongs with the production-scheduler wiring (Arch §9 "Still TO BUILD"), not the P0 hardening PR. It's a prerequisite for a *complete* empty-morning report, not for the fixes above.

### B7 — Existing PII leak into breadcrumbs — ⏳ DEFERRED (do in P1, with the scrubber; harmless until Sentry is on)
`Log()` breadcrumbs everything, and these log `displayPath`/drafts/recipients: `IterativeRun.swift:154` (`displayPath` = `~/Desktop/Divorce.pdf`), `Proactive.swift:117–118`, `ProactiveResearch.swift:145–149`, `CommandCoordinator`/`CommandRunModel`/`ProactiveExecutor` (transcripts, drafts, codex output), the reset `Log` in DevToolsView (~937, vault path).
**Fix:** scrub these (either stop logging the content, or rely on `beforeBreadcrumb` — but prefer removing at source). **Deferred rationale:** breadcrumbs only reach Sentry once `SentrySDK.start` runs, which (post-decisions) is Release-only + opt-out-gated and doesn't ship until P1. It IS a hard prerequisite for turning Sentry on — so it moves into the **P1 infra PR alongside `beforeBreadcrumb`** (§4.6), not a moment later. No exposure in the current Debug-only, Sentry-off state.

### B8 — The over-skip bug: per-directory cap is 100, not 300 (your known live bug) — ✅ FIXED (2026-07-01, unmerged)
`FilesSource.swift`: `perDirectoryCap` defaulted to **100** (~44), but `FileRoot.source` (~440, the sole caller) constructs `FilesSource` **without passing it** → every real run capped each directory at 100, while every doc + the architecture file say 300. A silent 3× under-cap dropping eligible files with zero counting.
**Fix applied:** corrected the `init` default `perDirectoryCap` 100 → **300** (single source of truth; `FileRoot.source` is the only caller and relies on the default). Also fixed three stale "100/dir" comments (file header, `eligibleFiles` doc, `cappedNewestFirst` doc). **Still to verify:** confirm on a real run that a previously over-skipped folder now yields more files (headless self-test or Analyze Now). **Co-suspects NOT changed** (no evidence they misfire; review only if the over-skip persists): the **depth cap at 3 folder levels** (~243, `maxWalkDepth = 3`) and the **code-density heuristic** (~133) on mixed data+doc folders. Add counting (§7.8) so the next such regression is visible.

### B9 — CycleStore.row() fetch failure → forever-reprocessing — ✅ FIXED (2026-07-01, unmerged)
`CycleStore.swift` `row(_:)` (~181–183): `try?` fetch. If it silently fails, `advance`/`sinkFloor` fall into the else-insert branch and try to `insert` a **second** `BucketPointer` for a `@Attribute(.unique)` key (~36) → the subsequent `save()` throws → swallowed by `try?` → mark never persists → **the bucket reprocesses forever.**
**Fix applied:** added a throwing `fetchRow` (distinguishes "no row" from "fetch failed"); `row()` captures on failure instead of swallowing; `advance`/`sinkFloor`/`setPointer` now route through a collision-safe `commit(...)` that, on a fetch/save failure, rolls back and **retries as an explicit update of the row that actually exists** (note re-committed in the same save, preserving atomicity) — so a unique-collision can no longer lose the mark. `collapseFloor` uses the throwing fetch + `capture` too.

### B10 — IterativeRun's failure catch conflates extraction vs inference — ⏳ DEFERRED (refactor for P2/P3 sensors, no standalone bug)
`IterativeRun.swift` `attempt` catch (~157–160) wraps both `connector.load` (extraction / `ExtractionTimeout`) and `engine.generate` (GPU wedge) — a corrupt-PDF failure and a GPU-wedge failure are indistinguishable, so you can't compute a clean Files-extraction-rate.
**Fix:** split the `do` (~128–156) into two try/catch scopes (extraction vs generate), or tag the thrown error type, so the two failure classes are separable. **Deferred rationale:** this changes nothing user-facing — its only payoff is separable counts for the §7.8 extraction sensor and §7.12 wedge sensor. Do it **in P3 alongside those sensors**, where the change can be validated by the sensor it enables; splitting the crash-safe hot loop now, with no consumer, is risk without benefit.

(Round-1 also flagged these lower-priority hardening items: `SQLiteDB.swift:47` `try?` on `-wal` sibling copy → silent stale reads; `Notes` `COALESCE(ZCREATIONDATE…)` drift; `Engine.reload`'s swallowed 1s sleep. Fold in opportunistically.)

---

## 7. Per-source instrumentation spec

For each: **what it does → failure points → insertion points (file:line) → events / breadcrumbs → PII-free fields → anomaly → fingerprint → iterative note.** "Event" = a Sentry `captureEvent` (an alert). "Breadcrumb" = context only. Remember §8 (iterative-awareness): count the **listing** (`bucket.items.count`), not `work.count`.

### 7.1 IterativeRun.swift — the core loop (the aggregation hub)
The orchestrator; every on-device source flows through it.
- **Listing count capture (A/E):** line **~174** `for bucket in buckets` — capture `bucket.items.count` **before** the mode switch (the switch `continue`s at ~204/211/217, skipping the bucket). This is the stable run-over-run count.
- **`work.count` (post-mark):** line **~220** `p.total += work.count` — the ~0 steady-state iterative count. Stash `(listingCount, workCount)` per bucket for the run-end event.
- **Per-item give-up tally (C):** line **~243** `} else { p.failed += 1; … }` — the single give-up counter. **Keep it a counter + at most a breadcrumb; NEVER an event here** (this is the 1,544-cascade site).
- **Uncounted hard-stop give-up:** ~235–237 — the in-flight item at the reload-exhausted hard stop is `break runLoop`'d and never added to `p.failed`; add a distinct `hardStopped` flag/counter.
- **The 1-hour cap:** §5 (label `bucketLoop`, deadline check in the item loop).
- **Run-end aggregated event (B), GATED:** fire **once after line ~261** (close of `runLoop`), before/after `engine.unload()` (~262). All exits funnel here (normal, cancel, hard-stop). Read `RunDiagnostics.shared` + the per-bucket `(listing, work, failed)`. **Gate:** emit as an *event* only if `p.failed > 0` OR `hardStopped` OR a bucket's listing diverged from `SourceHealth.lastListingCount` (anomaly) OR a rolling-rate sensor tripped OR a source hit the cap. Otherwise breadcrumb only. Fields: `mode`, `connector_kind`, `total/survivors/junk/parse_failures/sensitive/failed`, `reactive_reloads`, `preemptive_reloads`, `hard_stopped`, per-source `listing_count`/`work_count`. **Also gate on `!isSelfTest`** (`ProcessInfo…environment["SENTIENT_SELFTEST"]`) so headless test runs don't fire telemetry.
- **Emit from here, not ProcessingView** — because the overnight scheduler runs IterativeRun directly, bypassing the UI, and overnight is the most important case.
- **Anomaly compare (E):** load `SourceHealth.lastListingCount` near ~174, compare; write the new value at run-end (after ~261) so a crashed/capped run doesn't overwrite with a partial.
- **Engine-load failure (F1):** ~105–108 currently logs + returns an empty `RunProgress` silently (a whole 0-item run). Escalate to an **event** `engine.load_failed`.
- **buckets() throw (F2):** ~171–172 `continue` drops the **entire source** silently (the FDA-denied / DB-copy-failed case). Escalate to an **event** `source.dropped` (tag `source`, error *type* only).
- **Reload-exhausted hard stop (F9):** ~235–237 — **event** `engine.hard_stop` with `reloads_without_progress`, `consecutive_failures`.
- **Extraction vs generate split (B10):** required here for clean Files-extraction-rate + wedge sensors.

### 7.2 CycleStore.swift — the crash-safety store
- **Wrap the atomic-commit saves with capture-on-throw** (a swallowed throw = mark didn't persist → duplicate next run): `advance` `try? save()` **~215**, `sinkFloor` **~229**, `collapseFloor` **~236**, `setPointer` (Gmail/Cal pointer) **~170**. On catch → `capture(error)` + event `store.save_failed` (fields: `bucketKey` **scheme prefix only**, `order` numeric, `hasNote` bool; NEVER `tiebreak`/`text`/`title`/`sourceID`).
- **B9** fetch cascade at ~181–183 (capture-on-throw).
- Lower-priority `try?` reads to at least breadcrumb: `connectorMarks` ~157 (silent `[:]` → full re-listing), `notes()` ~241 (silent `[]` → cloud/proactive sees zero summaries).
- Breadcrumb before the `fatalError` (~306) and on the schema wipe-retry (~299–304) — a schema wipe silently discards all marks → full re-`initial` of every source ("why did everything reprocess overnight").

### 7.3 WhatsAppSource.swift (listing-phase decode — full sample every run)
No blob decode (ZTEXT is plaintext); "decode" failures = query degradation + window drops.
- **Counter sites:** `activeMemberNames` `try?` at **~60** (push-name map) and **~64** (group-member map) — silent → names degrade to "a group member"/"Group chat"; **~159** `guard let chat` drop (session-map mismatch); **~169–170/184** compactMap nils (chat's whole output dropped); **~194** `sender` → "a group member" (LID-blob rejection rate).
- **Handoff (write to RunDiagnostics):** inside `eligibleWindows()` **before the return at ~185**, keyed `SourceKind.whatsapp`: `{windows, chats_in, chats_out, msg_rows_dropped, member_query_degraded, cleanName_null_rate}`.
- **Events:** `whatsapp.zero_sessions_despite_install` when `isInstalled && chats == 0` (the NULL-guard landmine); `whatsapp.no_opted_in_chats` (`analyzedPKs.isEmpty`) distinguishing "opted into nothing" from "filter matched nothing".
- **Fingerprint:** `schema_fp` (ZWAMESSAGE/ZWACHATSESSION column names) + WhatsApp app version.
- **Anomaly:** `lastListingCount` (windows) collapse to 0, or `named_groups → 0`.
- **Iterative:** `buckets()` ignores the mark (ChatConnectors:21 always calls `eligibleWindows()`) → full sample every run. ✅

### 7.4 iMessageSource.swift (listing-phase decode)
- **`typedstreamText` (~191–208) `return nil` counter sites (each a distinct reason):** ~194 no marker (attachment-only — expected bulk), ~197 preamble EOF, ~200 0x81-length EOF, ~206 length ≤0/overrun, ~207 UTF-8 fail (implicit — add an explicit check to count it).
- **Consumer ratio site:** ~154–155 (`body = text ?? typedstreamText(blob)`, then the `guard`) — capture **attempts (rows with attributedBody) vs successes (non-nil bodies)** = the decode rate.
- Also count: ~103 null-guid chat drop; ~153/166–167/181 compactMap nils.
- **Handoff:** before the return at **~182**, keyed `SourceKind.imessage`: `{typedstream_attempts, typedstream_success, fail_no_marker, fail_preamble_eof, fail_len_eof, fail_len_zero, fail_utf8, chats_in, chats_out}`.
- **Event:** `imessage.decode.degraded` when rate < 90% (rolling). Include `first_len_byte` hex (structure) on first failure.
- **Fingerprint:** macOS version.
- **Anomaly:** decode-rate collapse (the Apple-typedstream-change tripwire).
- **Iterative:** full sample every run (decode at listing). ✅

### 7.5 NotesSource.swift (listing-phase decode — 5 stages)
- **`decodeBody` (~90–96) per-stage `nil` sites:** ~91 gunzip (internal: ~102 bad-magic/small, ~106 FEXTRA EOF, ~115 header overrun, ~130 inflate-init, ~144 inflate-process), ~92 field-2 (document), ~93 field-3 (note), ~94 field-2 (text), ~95 UTF-8. `firstMessage` internal bails ~165/169/171/175/179/182/185.
- **Consumer split (real gap):** ~64 `guard let blob = r.blob(4), let decoded = decodeBody(blob) else { return }` **merges two very different drops** — `blob == nil` = **undownloaded iCloud note**, vs `decodeBody` failed = **decode error**. The doc's "undownloaded → skipped **+ counted**" has **no counter today**. Split into two counters here. ~66 empty-body is a third silent drop.
- **Handoff:** before the return at **~84**, keyed `SourceKind.notes`: `{scanned, blob_null_undownloaded, decode_fail_by_stage{gunzip,field2,field3,field2text,utf8}, empty_body, kept}`.
- **Event:** `notes.decode.degraded` on rate collapse; `notes.gunzip.bad_magic bytes=<hex>` on ~102 (Apple changed the container).
- **Fingerprint:** macOS + Notes app version.
- **Iterative:** decode at listing (newest-1000), full sample every run. ✅

### 7.6 AddressBookNames.swift (resolution rate)
- **Counter sites:** the three `try?` `forEachRow` at **~63/70/75** (ZABCDRECORD / ZABCDPHONENUMBER / ZABCDEMAILADDRESS) — silent → **0 names resolved** (everyone shows as raw phone). ~57/59 store copy/reader `try?`.
- **Events:** `addressbook.no_store path_version=v22` (the `v22 → v23` file rename); breadcrumb on each query failure with **table name + `sqlite3_errmsg`** (schema string, safe).
- **Signal:** the resolution rate (`named_via_contacts / total_handles`) is best computed **in iMessage** (where handles are resolved) — a collapse means this file broke or the book is empty.

### 7.7 SQLiteDB.swift (the DB chokepoint)
- **`forEachRow`'s `.prepare` throw carries `sqlite3_errmsg`** (a SQL/schema string, **no user content**) — the uniform "column X renamed" detector for **all 4 DB sources**. Surface it at the throw (~73) or catch sites: event `db.schema_error db=<basename> msg=<errmsg>`.
- **Fix `try?` on `-wal` sibling copy (~47)** → silent stale reads look like "no new data"; at least breadcrumb.
- Disambiguate `missingFile` (~39): folds "not installed" and "no FDA" — pair with the Permissions probe (§7.22).

### 7.8 FilesSource.swift (listing = skip histogram; per-item = extraction)
- **Skip-reason counter sites in `eligibleFiles()` (~225–275):** ~239 symlink; **~242–245 `pruneReason` OR depth-cap — SPLIT these** (count the `pruneReason` string separately from the depth cutoff; `pruneReason` already returns the reason at ~106–148); ~250 extension reject; ~252–254 `fileRejectReason` (reason at ~173–188); ~287 per-root-cap (1000); ~288 age-cutoff (Downloads 1yr); ~291 per-directory-cap (**the B8 100-vs-300 bug**).
- **The over-skip signal:** capture into a per-root histogram `{reason: count}` **with a `whitelisted_lost` count** on prunes (how many whitelisted files a pruned directory's listing held — the listing is read inside `pruneReason` ~111; return it alongside the reason). A `code-density`/`dataset` prune with `whitelisted_lost > 0` is the over-skip signature. **Never the folder name/path.**
- **Extraction (per-item, `loadArtifact` ~303, via IterativeRun):** the 3 text paths (`pdfText`/`wordText`/`plainText`) return `""` on failure indistinguishably from empty — **split into `extraction_failed` vs `extraction_empty`** (use `doc.pageCount`: high pages + empty text = scanned PDF; nil = corrupt). Images throw (`imageDecodeFailed`/`imageEncodeFailed` ~349/356/366) — tag `(ext, size_bucket, method)`.
- **Handoff:** write per-root sub-counts to `RunDiagnostics` keyed `SourceKind.file` + `root.id` (Files' anomaly grain is **per-root**), before the return at ~274 (+ inside `cappedNewestFirst` ~281–296).
- **Fields:** extension, size_bucket, page_count, root enum, skip_reason string, depth, whitelisted_lost. **NEVER filename/path/displayPath.**
- **Event:** `files.root_yield_collapsed` when a root's kept-count craters vs `lastListingCount`; `files.extraction_degraded` (rolling, §8/R2 — per-item so needs the window).
- **Leaked-thread counter:** `ExtractionTimeout` (IterativeRun ~60) leaves the hung sync extractor thread running (~50) — count repeated timeouts (slow-burn resource exhaustion).
- **Iterative:** skip-histogram at listing (full sample every run ✅); extraction per-item (new files only → rolling window, §8/R2).

### 7.9 CodexCLI.swift — the cloud spine (THE chokepoint)
700 lines, **zero `Log()` today**, yet Gmail, Calendar, Vault, Proactive, and the command bar ALL funnel through `run()` / `runAgentCommand()`.
- **Single instrumentation seam:** `run()` (~277–306) / `parseEnvelope()` (~380–440) throw boundary. One try/catch that emits `codex.failure` keyed by `CLIError` case + a **new `Invocation.feature` tag** (gmail-read / calendar-read / vault / proactive / command-bar) so a codex fault is attributable to its origin without 4 separate sites. `runAgentCommand` (~317) is the computer-use sibling.
- **`CLIError` cases (list, ~100–120):** `.notAvailable(Availability)`, `.launchFailed(String)`, `.timedOut(after:)`, `.exitFailure(code:message:)`, `.badEnvelope(String)`, `.usageLimit(message:sessionID:)`. `Availability`: `.available/.notInstalled/.notWorking(String)`.
- **New typed case `.approvalGated`:** detect "user cancelled MCP tool call" in `parseEnvelope` errors (the `send_email`/`create_event` cancel-under-`never` trap) so "the action silently didn't fire" stops hiding as `.badEnvelope`.
- **Fields (structure only):** the `CLIError` case name, `exit_status`, `duration_ms`, `input_tokens`/`cached`/`output_tokens`, `model`, `effort`, `sessionID` **presence** bool, `feature`, `binary_found`, `binary_path_source` (known-path vs login-shell-which), `bypass_sandbox` bool (for `runAgentCommand`).
- **⚠️ MUST DISCARD:** `Envelope.raw` (full JSONL incl. the agent's final message = summarized email/event content), `Envelope.result`, any `detail`/`message`/stdout/stderr, the prompt. Consider gating/dropping `Envelope.raw` in Release (it exists "for debugging" only).
- **Extra:** re-probe `validate(force:true)` on a mid-session `.exitFailure`/`.badEnvelope` to tell "codex auth died" from "this one prompt failed"; log the resulting `Availability` case.
- **Computer-use specifics (`runAgentCommand`, ~308–330):** bypass-sandbox, prompt in **argv** (ARG_MAX), no `--json`, needs `richEnvironment` for the `$TMPDIR` socket (bare env hangs at `list_apps`); SIGTERM-only on timeout (no SIGKILL escalation). Event `codex.agent_command {exit_status, timed_out, duration_ms, binary_found}`; breadcrumb `codex.computer_use_hang_suspected` when a run goes >N seconds with no `onLine` output (proxy for the `list_apps` hang). Tag `bypass_sandbox=true` (highest-risk executions in the app).

### 7.10 GmailConnect.swift (cloud source)
- **Silent-nil epidemic in `parse()` (~216–229):** missing `{`/`}`, JSON won't parse, `notable` absent/non-bool, `notable == false`, empty `summary` all → `nil` = "nothing notable" — **indistinguishable from a real quiet week.** **Split shape-mismatch (a required JSON key is *absent*) from quiet-window (key present, `notable:false`).** Event `gmail.parse.shape_mismatch` with missing-key **names** only + `result.count` (length). Discard `result`/`span`/`summary`.
- Probe: drop the `env.result.prefix(40)` raw text from the `Log` (~91); log only the boolean verdict.
- Group-abort: when the 4-parallel initial task group throws, one event with completed-count + `CLIError` case.
- **Fields:** never `r.summary` or the prompt (email content). Use lengths/bools.
- **Anomaly:** cloud sources don't "list" a stable set — headcount doesn't translate. Signal = shape-mismatch + `probeConnected` flips. A quiet week must NOT alarm.
- **1-hour cap:** wrap the leg (§5).

### 7.11 CalendarConnect.swift (cloud source, twin of Gmail)
- Same shape-mismatch split in `parse()` (~219–229) / `jsonSpan()` (~232–237).
- **`fetchProactiveContext` (~169–194) is the most PII-dangerous:** `events_text` is verbatim titles/locations/attendees. **Log only `text.count` (already done well at ~188) + a `connected` bool.** Distinguish "connector down" from "empty calendar" (the `connected` field exists in the schema, ~182) so proactive degradation is observable without leaking event text.
- The calendar **write** path (`create_event`) lives in `ProactiveExecutor.fireCalendar` (§7.19) and hits the approval-gate trap → the `.approvalGated` case (§7.9).
- **1-hour cap:** wrap the leg (Calendar initial = 12 sequential monthly reads, up to 2h → this cap matters here).

### 7.12 Engine.swift (on-device LiteRT/Gemma)
Pure mechanism wrapper; **the wedge counters live in IterativeRun, not here** (§7.1). Zero `Log()` today.
- **Error enum:** `EngineError.modelNotFound(String)`, `.notLoaded` (throws ~73/116; native throws from `initialize`/`createConversation`/`sendMessage`).
- **Instrument:** `load_ms`, `reload_ms` breadcrumbs; `engine.load_failed` event tagging the `EngineError` case + `model_present` bool (never the path); `engine.generate_failed` breadcrumb with the **native error class string only** (never `prompt`/`imageData`/`response`).
- **The GPU wedge cascade** ("[Buffer] already has an outstanding map pending"): aggregate in IterativeRun's run-end event (`reactive_reloads`, `preemptive_reloads`) — an unguarded wedge = 1,544 failures → **one** event with the count, never 1,544. Distinguish `initialize`-failure (load/OOM/corrupt) from `sendMessage`-failure (wedge) by origin (different fingerprints).
- **Fingerprint:** macOS + Metal + model version.

### 7.13 Triage.swift (the hidden failure — parse-fail masquerading as junk)
Never throws. `parse()==nil → junk` (~146), `summary.isEmpty → junk` (~155), `boolField("junk")` defaults **true** when unreadable (~194). **A garbled model reply, a decode failure, and genuine junk all increment the same `p.junk` counter** — the documented "why so much junk?" blind spot, with no counter to check.
- **Fix (small code change, enables the sensor):** add `Outcome.reason` enum `{modelJunk, emptySummary, parseFailedStrict, parseRecovered, parseFailedTotal}`, set it in `decide()`/`parse()`, and have IterativeRun tally it (a `parse_failures` counter alongside `junk`).
- **Sensor (rolling, §8/R2):** `parse_failure_rate = parseFailed / done`; event `triage.parse_failure_spike`. **Never** `responseText`/`summary`/`title` — counts + which path only.

### 7.14 ModelLocator.swift
`resolve()` returns `nil` silently if the model is absent on all 4 paths (env → bundle → App Support → DEBUG repo-root). A Release build with a missing/half-downloaded App Support model fails invisibly.
- **Event `model.not_found`** with booleans only: `env_set`, `bundle_present`, `appsupport_present`, `debug_repo_present`, `expected_filename`. Never absolute paths.

### 7.15 VaultGenerator.swift
After **B2**: events `vault_swap_failed` (critical). Structure: `notes_in_staging`, `folders`, `input_tokens`, `output_tokens`, `codex_turns`, `duration_ms`, `usage_limit` bool, `resume_used` bool. Never note paths/titles/corpus. (Existing `Log()` at ~118/137/142/148/159 is good — mirror its structure.)

### 7.16 VaultCloud.swift
After **B1**: events `vault_restore_failed` (critical), `vault_mid_edit_abandoned`, `vault_snapshot_copy_failed`. `CloudError` cases: `.empty/.noVault/.usageLimit(String)/.failed(String)`. Push: `mirror_push {http_status, consecutive_failures}` (`pushIfDirty` ~151 swallows errors + leaves `vaultDirty` → retries forever). Never note text/skeleton paths/`envelope.result`.

### 7.17 VaultActivity.swift
Add a non-content `dirtySince` timestamp + `lastPushFailureCount` alongside `vaultDirty`. Event `vault_dirty_stuck` when dirty for days (the mirror is broken → the user's AIs read stale data). Pure structure.

### 7.18 MirrorClient.swift
After **B3/B4**: events `mirror.push_failed {http_status, zip_bytes, zip_file_count, zip_exit_code, duration_ms, network_error_class}`; `mirror.weak_token_averted`. `MirrorError` cases: `.notEnabled/.http(Int,String)/.zipFailed(String)/.noVault`. **PII: never the token** (SHA-256 hash only if correlation is genuinely needed), **never the HTTP response body** (`.http`'s second arg — log status only), never zip file names.

### 7.19 Proactive (Proactive.swift / ProactiveResearch.swift / ProactiveExecutor.swift / ProactiveCycle.swift)
- **The four "0 cards" paths that all look like a healthy empty morning** must be disambiguated with flags (not content): `Proactive.parse()==[]` from a non-empty codex result (~172) vs genuine "nothing to do"; `ProactiveResearch.parse()` empty (~215) vs a real all-dropped prune; `ProactiveCycle` `noRecent → items=[]` (~82) vs `items.isEmpty` (~89). Carry `decideFailReason` + `proactiveParseFailed` through `ProactiveCycle`.
- **Executor scoreboard (the headline computer-use health metric):** one shared `recordOutcome(method:source:outcome:duration:)` sink fed from **`ProactiveExecutor.fire()`'s method switch** (~52, keys `computer/gmail/calendar/research`) AND from **`CommandRunModel.complete()`** (as method `computer`, `source: voice|promptBar`). Counters `{method}×{fired,notFireable,failed,refused}`. Event `executor.fire {method, outcome, duration_s, timed_out, error_class}`. **Replace the brittle `hasPrefix("COULD NOT")` success test with a structured `STATUS: DONE|COULD_NOT` sentinel** in the wrapper prompts so false-success is detectable; treat `COULD NOT` as a distinct `refused` state. **Dashboard caveat: `fired` = codex exited 0 / claimed done, NOT verified completion.**
- **PII:** never `preparedContent`/drafts/`env.result`/`final`/recipe/`liveLines`/routing (all user content — Proactive ~117–118, Research ~145–149, Executor ~108/131).

### 7.20 Scheduler + WakeHelper — the "empty morning" black box
Emit **one structured `OvernightReport` per run** (to `scheduler.log` AND Sentry) bundling the ~9 distinguishable empty-morning causes. Fields (all structure-only): `armed_for`/`woke_at`/`arm_to_wake_drift_sec`, `helper_installed`/`install_declined`, `codesign_gate_passed`, `begin_awake_ok`/`end_awake_ok`, `heartbeat_count`/`heartbeat_failures` (currently discarded ~124 — count them), `deadman_tripped` (helper-log-only today — correlate), `on_ac`/`thermal_state`/`low_power` (**B6 — don't exist yet, add**), `fda_granted`, `custom_roots_seen` (always 0 today — hardcoded `[]` at ~113, a silent gap), `connectors_detected` (count + kinds), `model_found`, `device_kept/junk/failed/total`, `gmail_leg_ok`/`calendar_leg_ok`, `kb_outcome`, `decide_item_count`, `research_ready/dropped`, plus the two disambiguation flags **`proactive_parse_failed`** and **`end_awake_left_sleep_disabled`** (§7.19, B5).
- **A `runID`** generated in `runProcessing`, threaded into the helper ops, so `scheduler.log` ↔ `SentientOS-wakehelper.log` lines correlate (they're uncorrelated today).
- **WakeHelperClient's lossy `false`:** `call` (~67–77) collapses reply-false / xpc-error / timeout into one bool — record *which* guard fired so `begin_awake=false` isn't three-way ambiguous.

### 7.21 Voice + command bar + computer-use (Notch Magic) — the riskiest, least-observable subsystem
- **RightCommandMonitor:** `hotkey.tap_create_failed` **event** (whole voice path dead, no user signal — add a consecutive-failure counter across health ticks); breadcrumbs `hotkey.missed_release_reconciled`, `hotkey.max_hold_forced`. Tag OS major (permission behavior differs 15 vs 26).
- **VoiceCapture:** `voice.permission_denied {which: microphone|speech, status: denied|restricted|notDetermined}` **event** (a denial permanently breaks voice behind a 1.5s flash); breadcrumb `voice.engine_selected {engine: speechAnalyzer|sfSpeech, os_major}`.
- **SpeechAnalyzerEngine (macOS 26):** `voice.engine_start_failed {stage: format_unavailable|converter_init|audio_engine_start|model_install}`; breadcrumbs `voice.model_download_*`, `voice.buffer_convert_dropped` (count), `voice.transcript_empty` (bool). Never text.
- **SFSpeechRecognizerEngine (macOS 15, server-capable):** `voice.sf_unavailable`; breadcrumbs `voice.sf_final_timeout` (the 5s fallback fired → truncated), `voice.sf_recognition_error` (error class only). Tag `on_device=false` (audio may leave the Mac to Apple — a documented exception; **never** carry audio/transcript).
- **CommandCoordinator:** `command.submit_dropped {reason: already_running|busy_interacting|empty}` **event** (silent command loss); `voice.start_failed_nonpermission` (the path that shows the user nothing); breadcrumbs `notch.phase {phase enum}` (NEVER the `.notice(String)` payload / transcript), `voice.result {outcome: submitted|empty|transcribe_error}`.
- **CommandRunModel / ProactiveExecutor / runAgentCommand:** the computer-use outcome + duration (§7.9, §7.19). **Add the `COULD NOT` check to CommandRunModel too** (it's missing — weaker than the executor).
- **PII firewall is critical here** — every file logs raw transcripts/commands/codex play-by-play; §4.10 (separate sink + `beforeBreadcrumb`) is what keeps it out.

### 7.22 Permissions.swift — the FDA/TCC probe (empty-morning-critical)
`hasFullDiskAccess()` (~215–223) collapses **three states** into one `false`: true-denial (`EPERM`/`EACCES`), Terminal-TCC-attribution, and no-probe-file (`ENOENT`). Logs nothing.
- **Breadcrumb/event at arm time:** `fda.probe {result: bool, which_probe_matched: imessage|safari|tcc|none, errno: int}` — the `errno`+`none` combo distinguishes true-denial from Terminal-attribution from missing-file. This is the single highest-value empty-morning signal.
- Grant flow (`grantComputerUseAutomation`): `GrantError` case name only (`.noFDA/.helperNotFound/.requirement/.tcc`) + the SecCode step string (already non-PII, e.g. "SecCodeCopySelf") + sqlite result code. Never dbPath/bundle path.

### 7.23 Notify.swift
`requestAuthorization` (~29) and `add()` (~40) are `try?`-swallowed → a denied user gets a silent no-op (proactive reminders never fire).
- Breadcrumb `notify {authorization_status enum, suppressed bool, add_ok bool}`. **Never** `title`/`body` (the reminder text).

### 7.24 CodexSetup.swift / ComputerUseSetup.swift — the install flows
- **CodexSetup:** per-step outcomes `{step: install|login|computerUse, result, error_class}` — derive `error_class` from the typed error BEFORE it's stringified into `installStatus` (~70/108/163). Capture `binary_found_after_install` bool (the ~69 re-detect — "installer ran, binary missing" is specific/actionable) and `confirmLogin` retry-loop depth. **Never** the streamed installer/login `onLine` lines (embed paths/account hints).
- **ComputerUseSetup (richest failure surface — hardcoded OpenAI CDN URL + reverse-engineered DMG layout):** per-step trail `{step: download|mount|locate|ditto-marketplace|ditto-plugin|ditto-helper|patchConfig|postcheck, result, subprocess_exit_code}`. Capture the resolved **plugin `version` string** (~106 — tells you which OpenAI build broke `.missingSource`). Download failures: `{http_status, bytes_written, bytes_expected}` (404 = URL rotated vs mid-transfer drop). Flag leaked-mount (detach failure). **Never** `dmg.path`/`mount.path`/`codexHome` or `hdiutil`/`ditto` stdout (embed `/Users/<name>/…`).

### 7.25 GiftLetter.swift
`generate()` outcomes (already computed at ~73): `{outcome: success|noVault|usageLimit|empty|failed, letter_char_count, num_turns, output_tokens, written_file_found bool}`. **Never** the letter text (the user's synthesized life) nor the `.failed` stringified error (~80 — embeds vault path; use error-type name).

---

## 8. Iterative-awareness (the rules that make sensors valid in steady state)

The `.iterative` path (everyday nightly catch-up) and `.auto` (scheduler, per-bucket) behave very differently from the `.initial` backfill. Verified mechanics:
- **Two phases sample differently.** LISTING (`connector.buckets()`) **ignores the mark** and lists/decodes the FULL eligible set every run (ChatConnectors always call `eligibleWindows()`; NotesConnector always `eligibleNotes()`; FilesConnector always `eligibleFiles()`). The mark only decides which items get *triaged*. PER-ITEM (`load()` + Triage) runs only for items past the mark = **0–3 items** in iterative steady state.
- **So:** the brittle-decoder sensors (WhatsApp/iMessage/Notes/Files-skip/AddressBook) live in the LISTING phase → **full sample every run, identical to initial.** ✅ An Apple update breaking the iMessage decoder is caught the very next nightly run.

**R1 — Anomaly keys off the LISTING count, not `work.count`.** Store `SourceHealth.lastListingCount = bucket.items.count` (IterativeRun ~174), NOT `p.total`/`work.count` (~220, which is ~0 in steady state). Otherwise every healthy iterative run reports "0 items" and false-alarms or drowns the signal.

**R2 — Per-item sensors (Files extraction, Triage parse-failure) use a ROLLING WINDOW, not per-run rates.** An iterative run triages 0–3 items → a per-run rate is noise. Accumulate outcomes across the last N items (in `SourceHealth`, epoch-bucketed) and alarm on the rolling rate. A `.doc`-extraction break still surfaces as new `.doc`s arrive.

**R3 — The run-end aggregated event is GATED.** Iterative runs are frequent (nightly + every Analyze Now) and usually clean. Emit as an *event* only on failures/anomaly/hard-stop/cap-hit; otherwise breadcrumb only. The listing-phase anomaly checks emit independently, so a "0 new items but WhatsApp listing collapsed 50→0" run still fires.

**Iterative makes B9/B10 and the CycleStore save-swallow (D) MORE important** — `advance()` is the everyday iterative commit; a swallowed save there → duplicate notes next run.

---

## 9. Integration points (where the wiring lives)

- **Sentry init:** `main.swift` already calls `CrashReporting.start(.app)` / `.start(.wakeHelper)` before SwiftUI. Gate that call on `diagnosticsEnabled` (§4.5) — the switch gates ALL Sentry, so `start()` must sit behind the flag — AND on the RELEASE-only build gate (`#if !DEBUG` inside `start()`, §4.5). Also `register(defaults: ["diagnosticsEnabled": true])` and mint/read `diagnostics.installID` (§4.11) here, before `start()`.
- **Opt-out flag:** `AppState.diagnosticsEnabled` (UserDefaults `didSet`, mirror `hasCompletedOnboarding`; **default `true`**); `CrashReporting.diagnosticsEnabled` static reader for off-main sites.
- **Opt-out UI:** **SettingsView** — currently a static placeholder with NO toggle/`@AppStorage` precedent, so build the first interactive control there: a "Privacy & Diagnostics" section with `@AppStorage("diagnosticsEnabled") = true` (default ON) and a "structure-only, never your content — turn off anytime" reassurance line under the existing trust footer. Mirror the toggle mechanics of `DevToolsView.mcpToggleButton` (~763–854).
- **Run-end diagnostics emission:** IterativeRun run-end (§7.1), NOT ProcessingView (overnight bypasses the UI). Gate on `diagnosticsEnabled && !isSelfTest`.
- **Proactive-execution outcome:** the `recordOutcome` sink fed from `ProactiveExecutor.fire()` + `CommandRunModel.complete()` (§7.19).
- **Overnight report:** assembled in `OvernightScheduler.runProcessing` (§7.20).
- **Every run trigger (for reference):** DevToolsView `init.device`/`iter.device`/`init.cloud`/`iter.cloud`/`init.proactive`/`iter.proactive`/`proactive.research`/`executeButton`/scheduler; HomeView command bar (`commandCoordinator.submit`) + card fire (`ForYouModel.runReal`); RootView `onAnalyze` (`.auto` + optional `fullCycle` ProactiveCycle); OvernightScheduler (overnight `.auto`).

---

## 10. The PII firewall (the allowlist — enforce ruthlessly)

**ALLOWED in events/breadcrumbs (structure only):** counts, ratios/rates (as strings), booleans, enums (source/stage/kind/method/outcome/verdict/phase), durations, byte-size buckets, page counts, HTTP status codes, exit codes, sqlite result codes + `sqlite3_errmsg` (schema strings), error **type/case names**, OS/app/model versions, schema fingerprints (hashes), the `bucket.key` **scheme prefix** (`file`/`whatsapp`/`imessage`/`notes`), header/length **bytes as hex** (structure), protobuf field numbers/wire types.

**NEVER (denylist):** message text, email/calendar content, note bodies/titles, file names/paths/`displayPath`, contact names, phone numbers, JIDs/GUIDs/chat identifiers, the `tiebreak` (path/uuid), drafts/`preparedContent`/recipes/`env.result`/`Envelope.raw`/codex stdout-stderr/`onLine` lines, transcripts/spoken commands, the mirror token (SHA-256 hash only if correlation is essential), any `.localizedDescription`/`.description`/error-`message` that interpolates the above, `NSFullUserName()`/`NSUserName()`.

The `beforeSend`/`beforeBreadcrumb` scrubber (§4.6) is the backstop, not the primary defense — capture clean at the source.

---

## 11. Phasing

- **P0 — bug fixes** (§6, B1–B10) as their own PR. ✅ **Done (2026-07-01, unmerged):** B8, B1, B5, B2, B3, B4, B9 — isolated Debug build green; awaiting real-run verification (see §6 status block). ⏳ **Deferred out of P0:** B6 → the production-scheduler PR (Arch §9); B7 → the P1 infra PR (with `beforeBreadcrumb`); B10 → P3 (with the extraction/wedge sensors). Verify the merged fixes (headless self-tests where possible) before P1.
- **P1 — infra** (§4). ✅ **Built (2026-07-01, unmerged; isolated Debug build green):** `captureEvent` + `DiagLevel` (§4.1) · the **opt-out gate** `diagnosticsEnabled` (default ON) + **Release-only boot** + `startForDevTest()` + `applyEnabledChange()` (§4.5) · the **anonymous install-id** (§4.11) · the **SettingsView opt-out toggle** (§9) · `beforeSend`/`beforeBreadcrumb` **scrubber** (§4.6) · the **OS/app-version fingerprint stamp** auto-added to every event (§4.7) · the **1-hour cap** (§5, wired into IterativeRun, emits `source.hit_time_cap`). ⏳ **Deferred within P1→P2/P3 (no consumer yet — build with the sensors that use them):** `SourceFault` (§4.2), `RunDiagnostics` (§4.3), `SourceHealth` (§4.4), the run-end aggregated event + catch-all net (§4.8–4.9), the **DB `schema_fp` fingerprint** (§4.7, needs the DB sources' listing). **B7 PII source-scrub:** mitigated by the live `beforeBreadcrumb` scrubber (the doc's accepted fallback) + the one flagged hot line (`IterativeRun:154`) is already `#if DEBUG` so it never breadcrumbs in Release; per-line source-scrub of the remaining Proactive/Command logs is a follow-up.
- **P2 — the 5 highest-value sensors:** WhatsApp zero-sessions (§7.3), iMessage decode-rate (§7.4), Notes per-stage decode (§7.5), CodexCLI chokepoint + `feature` tag (§7.9), Scheduler/FDA "empty morning" (§7.20/§7.22).
- **P3 — the rest:** Files skip-histogram (§7.8), Triage discriminator (§7.13), Engine (§7.12), Vault/Mirror events (§7.15–7.18), the executor/command scoreboard + computer-use/voice (§7.19/§7.21), install-flow trails (§7.24), the smaller surfaces.

Each phase → build → **remind Aditya/Jesai to test it** → they confirm → then update docs (per Dev Notes §Documentation practice; don't doc-ahead of a confirmed-working implementation — this file is the *plan*, the per-feature docs come after).

---

## 12. Insertion-point checklist (quick reference — re-grep before editing)

| Item | File:line (snapshot) | Action |
|---|---|---|
| 1-hour cap | IterativeRun ~168 (connector start), label `bucketLoop` ~174, deadline check in item loop ~224 | §5 |
| Listing count (R1) | IterativeRun ~174 | capture `bucket.items.count` before switch |
| work.count | IterativeRun ~220 | post-mark count (stash, don't alarm on) |
| Extraction/generate split (B10) | IterativeRun ~128–156 (catch ~157–160) | split the `do` |
| Per-item give-up | IterativeRun ~243 (+ uncounted ~235–237) | counter + breadcrumb only; add hard-stop counter |
| Run-end gated event (B/R3) | IterativeRun after ~261 | read RunDiagnostics + SourceHealth; gate |
| Engine-load fail / source-dropped / hard-stop | IterativeRun ~105–108 / ~171–172 / ~235–237 | events |
| Atomic saves (D) | CycleStore ~215, ~229, ~236, ~170 | wrap `try? save()` |
| row() cascade (B9) | CycleStore ~181–183 | capture-on-throw |
| WhatsApp decode counters + handoff | WhatsApp ~60, ~64, ~159, ~169–170, ~184, ~194; return ~185 | RunDiagnostics(whatsapp) |
| iMessage typedstream counters + ratio + handoff | iMessage ~194/197/200/206/207; consumer ~154–155; return ~182 | RunDiagnostics(imessage) |
| Notes decode-by-stage + undownloaded split + handoff | Notes ~91(→102/106/115/130/144)/92/93/94/95; split ~64; return ~84 | RunDiagnostics(notes) |
| AddressBook query counters | AddressBook ~63/70/75 | events + resolution rate in iMessage |
| SQLite schema-error chokepoint | SQLiteDB ~73 (`.prepare`), fix ~47 (`-wal`) | event `db.schema_error` |
| Files skip-histogram (split prune/depth) + whitelisted_lost + handoff | Files ~239/242(split)/250/252/287/288/291; return ~274 + ~281–296 | RunDiagnostics(file, root.id) |
| Files extraction split | Files pdf/word/plain (`extractText`), images ~349/356/366 | extraction_failed vs empty |
| B8 over-skip fix | Files ~44 + ~440 | pass perDirectoryCap=300 |
| CodexCLI chokepoint + feature tag + approvalGated | CodexCLI ~277–306 / ~380–440; add `Invocation.feature` | event `codex.failure` |
| Gmail/Calendar shape-mismatch split | Gmail ~216–229; Calendar ~219–229/232–237; proactive-ctx ~169–194 | split shape vs quiet |
| Triage reason discriminator | Triage ~146/155/194 + `Outcome.reason` | enables parse-fail sensor |
| Engine events | Engine ~73/116, load/reload | breadcrumbs + events |
| Vault B1/B2 + events | VaultCloud ~127–132/98; VaultGenerator ~157–158 | .bak swap + critical events |
| Mirror B3/B4 + events | MirrorClient ~166/175/218 | fix + events |
| Executor scoreboard | ProactiveExecutor `fire()` ~52; CommandRunModel `complete()` | shared recordOutcome sink |
| Overnight report + runID + B5 + B6 | OvernightScheduler `runProcessing`; WakeHelper endAwake ~76–83 | OvernightReport event |
| FDA 3-state probe | Permissions ~215–223 | `fda.probe` breadcrumb |
| Structural: carry sub-counts | Connector.swift ~34 (`[Bucket]` can't hold them) | → RunDiagnostics singleton |

---

## 13. Decisions (RESOLVED 2026-07-01, Aditya + Jesai)

1. **Does the switch gate ALL Sentry (crashes included) or only the new diagnostics events?** (§4.5) — ✅ **Gates ALL Sentry, and it's opt-OUT (default ON).** One "Share anonymous diagnostics" switch controls every report. Privacy is upheld by the PII firewall (§10), not by the default.
2. **1-hour cap: wall-clock or active-processing time?** (§5) — ✅ **Wall-clock.**
3. **Curated + catch-all vs more-exhaustive throw-site coverage?** (§1) — ✅ **Curated + catch-all.**
4. **Identity: mirror token (hashed), a separate anonymous install-id, or fully unlinked?** — ✅ **Separate anonymous install-id** (a random UUID, independent of the mirror token; §4.11).
5. **Where should this doc ultimately live?** — ✅ **Stays in `Documentation/`.** It's the plan; once P0–P3 ship, fold the true per-feature docs alongside `Crash Reporting (Sentry).md` and keep this as the archived design record.
6. **Which build configs report to Sentry?** — ✅ **Release only, never Debug** (§4.5). Build-config gate on top of the opt-out flag; dev buttons keep an explicit `startForDevTest()` escape hatch. *(Confirm the dev-button choice — keep-with-escape-hatch vs remove entirely.)*

---

*Written 2026-06-30 as a handoff. Grounded in a two-round, whole-codebase audit (every Swift file). Re-grep line numbers before editing — they will have drifted.*
