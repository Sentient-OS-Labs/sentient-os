# Diagnostics (Sentry) — the built & verified system

**What this is:** Sentient's "smoke-detector" layer. It reports **native crashes**, **app-hangs**,
**caught errors**, and a curated set of **structured, PII-free failure events** to Sentry, so that
when a source silently breaks (an OS update rots a decoder, a codex call fails, a 3am run reads
nothing) we find out — precisely, and without ever seeing the user's content.

This doc describes the **shipped** system. The design/plan and the per-bug history live in
`Source Diagnostics & Hardening (Sentry).md`; the original native-crash setup in
`Crash Reporting (Sentry).md`. If those disagree with this file, **this file is the truth.**

Verified end-to-end on real hardware (2026-07-02/03): a **Release** build delivered every event
type below to Sentry — confirmed via the Sentry API — including a real native crash (`EXC_BREAKPOINT`,
symbolicated) and an app-hang.

**Curated 2026-07-12 (the first beta wave):** Sentry now reports **defects only**. Telemetry-shaped
events moved to TelemetryDeck, user STOPs and usage limits no longer report, app-hangs report at
10s (not 2s), uncaught-NSException reporting is on, and the SDK's URL-capturing defaults are
forced OFF as a privacy invariant (§2.5). Sections below reflect the curated state.

---

## 1. The two gates — nothing reaches Sentry unless BOTH pass

Everything funnels through `CrashReporting` (`CrashReporting.swift`), a caseless-enum namespace with
`nonisolated static` members (safe to call from any actor/thread).

1. **RELEASE builds only.** `start(_:)` no-ops in DEBUG — `boot()` sits behind `#if !DEBUG`. There is
   **no debug bypass** (the old `startForDevTest` / dev-pane buttons were removed). To test the
   pipeline you build a Release app; Sentry then boots through the normal `start(.app)` path.
2. **Opt-OUT switch, default ON.** `diagnosticsEnabled` (UserDefaults key `diagnosticsEnabled`,
   treats unset as `true`). The "Share anonymous crash reports" toggle in **Settings → System**
   gates **all** Sentry reporting — crashes included. Flipping it live calls `applyEnabledChange()`
   (boots or `SentrySDK.close()`). Product analytics (TelemetryDeck) has its OWN separate switch —
   `analyticsEnabled`, the toggle beside it — see the Product Analytics doc.

`main.swift` calls `CrashReporting.start(.app)` (GUI) / `.start(.wakeHelper)` (the root overnight
helper) before anything else. Both are gated as above.

**Identity:** every event carries an **anonymous install id** — a random `UUID` minted once and kept
in UserDefaults (`diagnostics.installID`), set as Sentry's `user.id`. It is **not** the mirror token,
not hardware-derived; it resets on reinstall. Lets recurring faults on one machine correlate without
tying to a person (honors no-accounts).

Every event is also auto-stamped with `os_version` and `app_version` tags.

---

## 2. The PII firewall (the whole reason this is safe)

**Reports contain STRUCTURE ONLY** — counts, ratios, booleans, enums (source/stage/kind/method/
outcome), durations, byte buckets, HTTP/exit/sqlite codes, `sqlite3_errmsg` (schema strings), error
**type/case names**, versions, fingerprints. **NEVER** message/email/note text, file names/paths,
contact names, phone numbers, chat ids, drafts/`preparedContent`/recipes, `env.result`/codex output,
transcripts, or the mirror token.

Two defenses:
- **Clean at the source (primary).** `captureEvent` only ever takes enums/counts/strings the caller
  controls. Content-bearing `Log()` lines (proactive drafts, command transcripts, codex output) were
  scrubbed in B7: the verbose ones are `#if DEBUG` (Sentry is Release-only, so DEBUG-only can never
  breadcrumb), and success logs were reduced to lengths. **Error paths use `ErrorLabel(error)`
  (Log.swift), never `\(error)` / `localizedDescription`** — in Release it renders the enum case /
  type name only. Raw interpolation would carry codex stderr (`CLIError`'s description embeds up to
  300 chars of it — Gmail/calendar/screen content), note titles (Cocoa file errors carry the path),
  and the mirror server's response body — the 2026-07-12 hardening pass (frontier-model audits over
  every capture site + manual review by both devs) locked all ~22 error logs down to labels. A second
  sweep (2026-07-12) closed the last identifier-bearing sources: the on-device pipeline's error logs
  logged only a bucketKey's **scheme prefix** (`CycleStore.scheme` — `whatsapp`/`file`/`notes`), never
  the raw key (a chat's phone-number JID or a user file path); and the vault-swap failure became a
  structured `vault_swap_failed` event (its Cocoa error embeds the failing note's path = a note title,
  which the path scrubber can't fully strip from a spaced vault path).
- **`beforeSend` / `beforeBreadcrumb` scrubber (backstop).** A pure closure set in `boot()` that
  redacts free text on outgoing events + `Log()`-fed breadcrumbs: home-dir paths → `/Users/<redacted>`
  (the WHOLE remainder — a folder/file name is PII, not just the username), external-volume paths →
  `/Volumes/<redacted>`, the mirror password path segment `/p_…` → `/p_<redacted>`, emails → `<email>`,
  phone runs → `<phone>`, and **high-entropy** long tokens → `<token>`. Since 2026-07-12 the breadcrumb scrub
  also walks `crumb.data` string values (SDK-authored crumbs carry their payload there, not in
  `message` — see §2.5).
  ⚠️ The token rule requires ≥1 uppercase/digit on purpose — a plain `{24,}` rule wrongly redacted our
  own snake_case event names (`zero_sessions_despite_install` → `<token>`); real tokens/hashes always
  carry entropy. (Caught + fixed during the Release verification.)

> The scrubber covers **message / exception / breadcrumb** text + breadcrumb `data` strings — NOT
> `extra`/`tags` (those are structure-only by contract). So never put free text in `extra`/`tags`.

---

## 2.5 The SDK's own defaults are part of the firewall

The sentry-cocoa SDK ships with **URL-capturing features ON by default**: network breadcrumbs
(every URLSession request → a crumb with the full `url` + `http.query` in `crumb.data`) and
failed-request capture (any HTTP 5xx from ANY URL → its own event with request details). The MCP
mirror's URL carries the user's **mirror password in its path** — so the §8 invariant ("request
paths must NEVER be logged"), already enforced server-side (uvicorn access log), has to hold
client-side too: a captured push URL (`/u_…/p_…/vault`) is exactly such a path. `boot()` therefore
forces **`enableNetworkBreadcrumbs = false`** and **`enableCaptureFailedRequests = false`** —
never re-enable either. Locked down 2026-07-12 in the week-long pre-launch security hardening
program (the repo's `SECURITY.md`): the whole telemetry surface extensively evaluated with
frontier models (Claude Mythos/Fable 5, GPT-5.6 Sol) plus manual review by both devs, stored
events swept end-to-end. The `crumb.data` scrub (§2) is the backstop, not the defense. Lesson: **when the SDK
updates, re-check what its new defaults capture.**

---

## 3. `captureEvent` — the API + how to add a new event

```swift
CrashReporting.captureEvent(
    "source.some_failure",              // a STABLE, content-free name (this is the Sentry title)
    level: .warning,                    // .info / .warning / .error / .fatal
    tags: ["source": "whatsapp"],       // low-cardinality, structure only
    extra: ["count": "42"],             // strings, structure only
    fingerprint: ["whatsapp", "some_failure"])   // groups issues by FAILURE MODE, not stack line
```

To add one: pick a stable dotted name, emit at the failure site with structure-only fields, and set a
`fingerprint` so it groups sensibly. It's a no-op unless Sentry is started + opted-in, and callable
off-main with no `await`.

`CrashReporting.capture(_ error:)` reports a caught `Error` (used by the critical vault paths, B1/B2).

---

## 4. The event catalog (everything that's wired today)

Native **crashes** (signals + uncaught NSExceptions — the latter needs
`enableUncaughtNSExceptionReporting = true`, which defaults OFF on macOS) + **app-hangs at 10s**
are automatic via the SDK. The structured events (defects only — telemetry-shaped events live in
TelemetryDeck since 2026-07-12):

| Event | Emitted from | Fires when | Key fields | Level |
|---|---|---|---|---|
| `source.hit_time_cap` | `IterativeRun` (§5 cap) | a source runs past its 60-min wall-clock budget | `source`, `processed` | warning |
| `whatsapp.zero_sessions_despite_install` | `WhatsAppSource` | WhatsApp installed but the session query returns 0 (the NULL-guard landmine) | `source` | error |
| `whatsapp.no_opted_in_chats` | `WhatsAppSource` | opted into specific chats but none matched | `source` | warning |
| `<source>.listing_collapsed` | `SourceHealth` | a source's run-over-run listing count craters to 0 from a healthy count | `source`, `previous` | error |
| `imessage.decode.degraded` | `iMessageSource` | typedstream decode <50% (≥50 samples) — the Apple-format-change tripwire | `attempts`, `success_pct` | error |
| `notes.decode.degraded` | `NotesSource` | Notes gunzip/protobuf decode <50% (≥30 downloaded) | `attempts`, `success_pct` | error |
| `files.extraction_degraded` | `SourceHealth` (rolling) | PDF/Word/txt extraction rate <50% over a week window (≥30) | `attempts`, `success_pct` | warning |
| `db.schema_error` | `SQLiteDB` | any `prepare` fails — our SQL is static, so this = a column rename (all 4 DB sources) | `db`, `msg` (sqlite3_errmsg) | error |
| `gmail.parse.shape_mismatch` / `calendar.parse.shape_mismatch` | `GmailConnect` / `CalendarConnect` | the cloud reply's JSON won't parse or the required `notable` key is absent (vs a genuine quiet week) | `source`, `missing` | warning |
| `codex.failure` | `CodexCLI.run` | a codex call fails for a REAL reason — a cancelled Task (the user's STOP; its SIGTERM exit used to masquerade as `exitFailure`) and `usageLimit` (expected; the amber caution owns it) never report | `feature`, `error` (CLIError case), `model`, `effort`, `duration_ms`, `resumed` | error |
| `codex.agent_command` | `CodexCLI.runAgentCommand` | a computer-use codex run fails (same cancel/usage-limit exclusions) | `feature: computer`, `error` | error |
| `codex.fire_fallback` | `ProactiveExecutor.runConnector` | a sandboxed connector fire's write auto-cancelled (agent `COULD_NOT` + the verbatim "cancelled MCP tool call" in the raw JSONL) and the executor retried once on the legacy bypass path — the signal that codex's apps-approve config surface changed under us | `channel` (gmail/calendar) | warning |
| `codex_auth.refresh_failed` | `CodexAuth` | the on-demand codex token re-mint gets a non-OK HTTP status | `status` | warning |
| `engine.load_failed` | `IterativeRun` | the on-device model won't load (→ a 0-item run) | `error`, `model_present` | error |
| `model.download.failed` | `ModelDownload` | the onboarding model download exhausted its retries / aborted | `reason` — `disk_space` (the 10 GB preflight floor refused to start), `disk_write` (the disk filled mid-transfer), `checksum_mismatch`, `upstream_changed`, `bad_response`, `short_delivery`, `network` | error |
| `source.dropped` | `IterativeRun` | `connector.buckets()` throws (FDA denied / DB-copy failed) → whole source skipped | `source`, `error` | error |
| `engine.hard_stop` | `IterativeRun` | the GPU-wedge cascade the reloads couldn't clear | `reloads_without_progress`, `consecutive_failures` | error |
| `triage.parse_failure_spike` | `IterativeRun` | ≥20% of a run's items were garbled model replies (not real junk), ≥30 items | `parse_failures`, `done` | warning |
| `mirror.push_failed` | `VaultCloud.pushIfDirty` | the MCP mirror push (swallow-and-retry path) fails | `http_status` (0 = non-HTTP) | warning |
| `fda.probe` | `Permissions` (once/run, DB source present) | Full Disk Access isn't cleanly granted | `which_probe`, `errno` | warning |
| `notify.add_failed` | `Notify` | the notification-center add call throws | `error` | warning |
| `addressbook.no_store` | `AddressBookNames` | the `v22` contacts store is absent (the v22→v23 rename) → contacts stop resolving | `path_version` | warning |
| `codex_setup.step_failed` | `CodexSetup` | a setup step fails | `step`, `error`, `binary_found` | warning |
| `executor.fire` | `ExecutorScoreboard` | a DEFECT-shaped executor outcome only (see §5): failed / refused / notFireable / fired-without-STATUS-sentinel. Verified successes go to TelemetryDeck, never here | `method`, `source`, `outcome`, `duration_s`, `status_present` | warning |

Plus `CrashReporting.capture(error)` on the critical vault-restore/swap failure paths (B1/B2).

**Moved to TelemetryDeck (2026-07-12) — telemetry, not defects; they no longer touch Sentry:**
`Scheduler.gated` (was `overnight.gated`), `Scheduler.caution` (was `overnight.caution` — the
morning-after classification: codex signed out / no internet / usage limit),
`KnowledgeBase.staleSwapAverted` (was `vault.update.stale_swap_averted`), and
`Notify.notAuthorized` (was `notify.not_authorized` — a declined permission is a user choice).

---

## 5. Two subsystems worth knowing

**The 1-hour per-source cap** (`IterativeRun`, §5): each source gets a 60-min wall-clock budget; on
overrun it stops that source and moves on (per-item marks are atomic, so it just resumes next run) and
emits `source.hit_time_cap`.

**The executor scoreboard** (`ExecutorScoreboard.swift`, §7.19) — the health metric for the flagship
"AI that DOES things." `record(method:source:outcome:duration:)` is fed from
`ProactiveExecutor.fire()` (source `proactive_card`) AND `CommandRunModel.complete()` (source
`voice`/`promptBar`/`notchTyped`; user STOPs are skipped by the caller). Outcomes: `fired` /
`notFireable` / `failed` / `refused`, read from a **`STATUS: DONE | COULD_NOT` sentinel** the
executor wrapper prompts require; a missing sentinel → optimistic `fired` with
`status_present:false`, which measures the false-success RISK.
**Sentry sees defects only** (since 2026-07-12): a verified success returns without emitting —
the success counts live in TelemetryDeck (`ComputerUse.finished`, `Proactive.actionFired`, both
core-tier), because success telemetry in the issue feed buried the real errors and tripped
Sentry's escalation detector.
> ⚠️ `fired` means codex **claimed** done, NOT verified completion. Read the dashboard that way.

**`SourceHealth.swift`** backs the anomaly sensors: run-over-run listing counts
(`checkListingCollapse`) and the rolling extraction-rate window (`recordExtraction` /
`checkExtractionRate`), in its own UserDefaults key (never wiped by `LifetimeStats.reset()`).

---

## 6. Related hardening this rode with (see the plan doc for detail)

- **KB stage-then-swap (B11):** both `VaultGenerator` (build) and `VaultCloud.update` now edit a temp
  staging copy and atomically swap into the real vault only on success — the live vault is never
  mutated mid-run; durable `(sessionID, stagingPath)` resume for both; a swap-time **freshness check**
  (`VaultGenerator.vaultFingerprint`) aborts rather than clobber a Knowledge-editor edit made during
  the run (`vault.update.stale_swap_averted`). See `Vault Generation (Stage 2).md`.
- **B10 extraction/generate split:** `IterativeRun.attempt()` separates a corrupt-file extraction
  failure from a GPU-wedge generate failure, so a bad file no longer triggers pointless engine reloads.
- **Scheduler:** 3 AM production default + B6 power/thermal gates (`PowerState.swift`) → `overnight.gated`.

---

## 7. Verified vs deferred

**Verified (real hardware, Release, via the Sentry API):** all structured event types + real-path
triggers (`db.schema_error`, `listing_collapsed`, `extraction_degraded`, `executor.fire`,
`capture(error)`) + a native crash (`EXC_BREAKPOINT`, symbolicated) + app-hang (2026-07-02/03,
pre-curation). **The 2026-07-12 curation itself:** Release build compiles clean (including
`ErrorLabel`'s Release-only branch) and the dSYM upload phase ran end-to-end with the new org
token (files confirmed on Sentry via the API). The curated event flow (10s hangs, STOP silence,
defect-only scoreboard) still wants a runtime spot-check on the next real Release session.

**Deferred (not built):** the full `OvernightReport` (§7.20, with the production scheduler + overnight
hardware), **voice internals** (§7.21 — hotkey/permission/engine-start signals; needs a mic + human to
verify), `SMAppService` daemon onboarding + the Release codesign-gate enforcement, and minor leftovers
(`model.not_found`, ComputerUseSetup DMG per-step trail, Files skip-histogram `whitelisted_lost`).

**Testing note:** there is no debug bypass, so verify from a **Release build**. The past verification
used a temporary headless self-test (`Self Tests - Temp/`, deleted after) that ran in the Release build
and called the real `captureEvent`/`start(.app)` — never a debug shortcut. Read-back is via the Sentry
REST API (an auth token with `event:read`); `sentry-cli` is used for `send-event`-style checks.
