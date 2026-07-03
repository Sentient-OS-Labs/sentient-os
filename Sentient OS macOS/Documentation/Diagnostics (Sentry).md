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

---

## 1. The two gates — nothing reaches Sentry unless BOTH pass

Everything funnels through `CrashReporting` (`CrashReporting.swift`), a caseless-enum namespace with
`nonisolated static` members (safe to call from any actor/thread).

1. **RELEASE builds only.** `start(_:)` no-ops in DEBUG — `boot()` sits behind `#if !DEBUG`. There is
   **no debug bypass** (the old `startForDevTest` / dev-pane buttons were removed). To test the
   pipeline you build a Release app; Sentry then boots through the normal `start(.app)` path.
2. **Opt-OUT switch, default ON.** `diagnosticsEnabled` (UserDefaults key `diagnosticsEnabled`,
   treats unset as `true`). One "Share anonymous diagnostics" toggle in **Settings** gates **all**
   reporting — crashes included. Flipping it live calls `applyEnabledChange()` (boots or `SentrySDK.close()`).

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
  breadcrumb), and success logs were reduced to lengths.
- **`beforeSend` / `beforeBreadcrumb` scrubber (backstop).** A pure closure set in `boot()` that
  redacts free text on outgoing events + `Log()`-fed breadcrumbs: home-dir paths → `/Users/<redacted>`,
  emails → `<email>`, phone runs → `<phone>`, and **high-entropy** long tokens → `<token>`.
  ⚠️ The token rule requires ≥1 uppercase/digit on purpose — a plain `{24,}` rule wrongly redacted our
  own snake_case event names (`zero_sessions_despite_install` → `<token>`); real tokens/hashes always
  carry entropy. (Caught + fixed during the Release verification.)

> The scrubber covers **message / exception / breadcrumb** text — NOT `extra`/`tags` (those are
> structure-only by contract). So never put free text in `extra`/`tags`.

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

Native **crashes** + **app-hangs** are automatic via the SDK. The structured events:

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
| `codex.failure` | `CodexCLI.run` | any codex call fails | `feature`, `error` (CLIError case), `model`, `effort`, `duration_ms`, `resumed` | error (usageLimit → info) |
| `codex.agent_command` | `CodexCLI.runAgentCommand` | a computer-use codex run fails | `feature: computer`, `error` | error |
| `engine.load_failed` | `IterativeRun` | the on-device model won't load (→ a 0-item run) | `error`, `model_present` | error |
| `source.dropped` | `IterativeRun` | `connector.buckets()` throws (FDA denied / DB-copy failed) → whole source skipped | `source`, `error` | error |
| `engine.hard_stop` | `IterativeRun` | the GPU-wedge cascade the reloads couldn't clear | `reloads_without_progress`, `consecutive_failures` | error |
| `triage.parse_failure_spike` | `IterativeRun` | ≥20% of a run's items were garbled model replies (not real junk), ≥30 items | `parse_failures`, `done` | warning |
| `mirror.push_failed` | `VaultCloud.pushIfDirty` | the MCP mirror push (swallow-and-retry path) fails | `http_status` (0 = non-HTTP) | warning |
| `fda.probe` | `Permissions` (once/run, DB source present) | Full Disk Access isn't cleanly granted | `which_probe`, `errno` | warning |
| `notify.not_authorized` / `notify.add_failed` | `Notify` | a denied notification permission silently kills reminders / add fails | `auth_status` | warning |
| `addressbook.no_store` | `AddressBookNames` | the `v22` contacts store is absent (the v22→v23 rename) → contacts stop resolving | `path_version` | warning |
| `codex_setup.step_failed` | `CodexSetup` | a setup step fails | `step`, `error`, `binary_found` | warning |
| `executor.fire` | `ExecutorScoreboard` | EVERY executor action (see §5) | `method`, `source`, `outcome`, `duration_s`, `status_present` | info / warning |
| `vault.update.stale_swap_averted` | `VaultCloud.update` | the user edited the vault in the editor mid-update → swap aborted (see §6) | — | info |
| `overnight.gated` | `OvernightScheduler` | the 3am run was skipped (battery / Low Power / thermal-critical) | `reason` | info |

Plus `CrashReporting.capture(error)` on the critical vault-restore/swap failure paths (B1/B2).

---

## 5. Two subsystems worth knowing

**The 1-hour per-source cap** (`IterativeRun`, §5): each source gets a 60-min wall-clock budget; on
overrun it stops that source and moves on (per-item marks are atomic, so it just resumes next run) and
emits `source.hit_time_cap`.

**The executor scoreboard** (`ExecutorScoreboard.swift`, §7.19) — the health metric for the flagship
"AI that DOES things." `record(method:source:outcome:duration:)` emits `executor.fire`, fed from
`ProactiveExecutor.fire()` (source `proactive_card`) AND `CommandRunModel.complete()` (source
`voice`/`promptBar`). Outcomes: `fired` / `notFireable` / `failed` / `refused`. Success/refusal is read
from a **`STATUS: DONE | COULD_NOT` sentinel** the executor wrapper prompts now require (replacing a
brittle `hasPrefix("COULD NOT")` guess); a missing sentinel → optimistic `fired` with
`status_present:false`, which measures the false-success RISK.
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

**Verified (real hardware, Release, via the Sentry API):** all 21 structured event types + real-path
triggers (`db.schema_error`, `listing_collapsed`, `extraction_degraded`, `executor.fire`,
`capture(error)`) + a native crash (`EXC_BREAKPOINT`, symbolicated) + app-hang. B8 (300/dir cap) and
B11 (create+update stage-swap) verified on real codex.

**Deferred (not built):** the full `OvernightReport` (§7.20, with the production scheduler + overnight
hardware), **voice internals** (§7.21 — hotkey/permission/engine-start signals; needs a mic + human to
verify), `SMAppService` daemon onboarding + the Release codesign-gate enforcement, and minor leftovers
(`model.not_found`, ComputerUseSetup DMG per-step trail, Files skip-histogram `whitelisted_lost`).

**Testing note:** there is no debug bypass, so verify from a **Release build**. The past verification
used a temporary headless self-test (`Self Tests - Temp/`, deleted after) that ran in the Release build
and called the real `captureEvent`/`start(.app)` — never a debug shortcut. Read-back is via the Sentry
REST API (an auth token with `event:read`); `sentry-cli` is used for `send-event`-style checks.
