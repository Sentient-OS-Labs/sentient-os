# Product Analytics (TelemetryDeck)

`Analytics.swift` wires the app to [TelemetryDeck](https://telemetrydeck.com) so we can see the
product funnel from real runs — do people arrive, finish setup, does the on-device brain work, does
the 3am scheduler run itself, does the proactive magic fire, what do they adopt. It is the **twin of
`CrashReporting.swift`** (Sentry, which is crashes/errors): same boot pattern, the **same opt-out**,
the **same anonymous identity**, and the same "structure only, never content" discipline.

TelemetryDeck is a privacy-first analytics service: **no PII, no IP addresses stored**, timestamps
rounded to the hour, one anonymized per-install user id (hashed on-device *and* again on their
server). That's GDPR-clean by construction and a clean fit for our Privacy Constitution — no
accounts, nothing personal ever leaves the Mac.

## How it boots

`main.swift` calls `Analytics.start()` right after Sentry, in the **GUI app role only** (the root
`--wake-helper` LaunchDaemon sends no analytics — it's a privileged, minimal path):

```swift
} else {
    CrashReporting.start(.app)   // crash reporting
    Analytics.start()            // product analytics (TelemetryDeck) — GUI app only
    SentientOSApp.main()
}
```

`start()` has **two hard gates**, mirroring Sentry's shape:
1. **RELEASE builds only** — a deliberate no-op in DEBUG, so a dev's day-to-day Debug runs never
   pollute real usage numbers. (Verify from a Release build — see below.)
2. **Its OWN opt-OUT switch** — `Analytics.analyticsEnabled` (UserDefaults key `analyticsEnabled`,
   default ON, unset-reads-true). The "Share anonymous analytics" toggle in **Settings → System**
   gates TelemetryDeck only; crash reports keep their separate switch (`CrashReporting.
   diagnosticsEnabled`, the "Share anonymous crash reports" toggle beside it). The two consents
   split when the real Settings shipped, so a user can keep crash reports on while opting out of
   usage analytics — or vice versa. Flipping the toggle calls `Analytics.applyEnabledChange()`.

Identity is the **same anonymous per-install id** as Sentry (`CrashReporting.installID`, a random
UUID in UserDefaults), passed as TelemetryDeck's `defaultUser` (it re-hashes it). One identity,
two independent switches. Every signal also auto-stamps `model` (the on-device
model file name) via `defaultParameters`; OS/app version/device come free from the SDK.

## The App ID — safe in the code

The App ID is a plain constant at the top of `Analytics.swift` (org namespace `ai.sentient-os`).
**Not a secret, fine to ship publicly** (even open source): like a Sentry DSN it is ingest-only — it
can only write signals *in*, never read anything out or touch the account. `start()` no-ops if it's
ever left as the `PASTE_…` placeholder.

## What we send (structure only — never content)

Every signal carries counts / enums / on-off / which-feature. **Never** a filename, message, prompt,
email, or anything the user wrote. `Command.submitted` records only source+mode, right next to the
existing B7 "length, not the command text" log — same discipline.

**Tier column:** 🟢 = the always-on **core** tier (survives opt-out — the five anonymized usage counts, plus the SDK's launch/session signals and the install ping in the next section). Everything else is **extended**, gated by the analytics opt-out. The core set is exactly these five signals — nothing more rides always-on.

| Signal | Tier | Emitted from | Meaning |
| --- | --- | --- | --- |
| `Onboarding.completed` | extended | `AppState.swift` | Setup finished (once, false→true) |
| `Processing.completed` | extended | `Ingestion/IterativeRun.swift` | On-device read ended — mode + survivors/junk/sensitive/failed/total |
| `Engine.reloaded` | extended | `Ingestion/IterativeRun.swift` | GPU-wedge self-heal fired (`reason`: preemptive/reactive) |
| `Scheduler.overnightStarted` | extended | `Scheduling/OvernightScheduler.swift` | 3am run began |
| `Scheduler.overnightCompleted` | 🟢 core | `Scheduling/OvernightScheduler.swift` | 3am run finished cleanly — the always-on "overnight runs" count |
| `Scheduler.gated` | extended | `Scheduling/OvernightScheduler.swift` | Nightly run skipped (`reason`: battery/lowPower/thermal) |
| `Scheduler.caution` | extended | `Scheduling/OvernightCaution.swift` | An unattended run failed for a knowable reason (`kind`: usageLimit/loggedOut/noInternet) — was Sentry's `overnight.caution` until the 2026-07-12 curation |
| `Scheduler.autoEnabled` | extended | `Scheduling/OvernightScheduler.swift` | The 14h auto-enable flipped the scheduler on |
| `KnowledgeBase.built` / `.updated` / `.failed` | extended | `Proactive/ProactiveCycle.swift` | First build / incremental update / error |
| `KnowledgeBase.staleSwapAverted` | extended | `Vault/VaultCloud.swift` | The freshness check aborted a swap over a mid-run editor save (working as designed — was Sentry's `vault.update.stale_swap_averted`) |
| `Proactive.decided` | extended | `Proactive/ProactiveCycle.swift` | # things-worth-doing found |
| `Proactive.prepared` | 🟢 core | `Proactive/ProactiveCycle.swift` | # cards that survived research (+ # dropped) — the always-on "proactive cards made" count |
| `Proactive.actionFired` | 🟢 core | `Proactive/ProactiveExecutor.swift` | A user fired a card (`method` + `outcome`) — the always-on "proactive cards fired" count |
| `ComputerUse.finished` | extended | `Notch Magic/CommandRunModel.swift` + `Proactive/ProactiveExecutor.swift` | Agent working seconds (`floatValue`, summed into total agent-time) — a DURATION, so gated |
| `Mirror.enabled` / `.pushed` / `.disabled` / `.regenerated` | extended | `Cloud/MirrorClient.swift` | MCP mirror lifecycle |
| `Command.submitted` | 🟢 core | `Notch Magic/CommandCoordinator.swift` | Sidekick / "do stuff for me" bar used (`source` + `mode`) — the always-on "Sidekick fires" count |
| `Home.opened` | 🟢 core | `Views/RootView.swift` | Home screen opened (`trigger`: launch/reopen) — the always-on "home opens" count |
| `Source.connected` | extended | `Views/{Gmail,Calendar}ConnectSheet.swift` | A source hooked up (`source`) |
| `Notify.notAuthorized` | extended | `System/Notify.swift` | A reminder was suppressed by a declined notification permission (`status`) — user choice, not a defect (was Sentry's `notify.not_authorized`) |

Plus what the SDK sends automatically: app launches, sessions, new-install, and device/OS/version.

**This is the SOLE owner of usage/session counting.** Sentry's auto session tracking is deliberately
off (`CrashReporting.swift`), so "how many people use Sentient" lives entirely behind *this* toggle —
with **one deliberate exception**: the anonymous install ping (below).

## The one anonymous install ping (`countInstallOnce()` — opt-out-INDEPENDENT)

`countInstallOnce()` sends a **single, totally anonymous** "an install exists" beacon that fires at
most once per install and, unlike everything else here, fires **even when analytics are opted out**.
It's how we always know how many people use Sentient, without making the opt-out a lie: it's
**disclosed in the opt-out's own Settings copy** (a caption appears under the toggle the moment it's
switched off).

- **Anonymity.** It carries a throwaway random hash as `clientUser` (a fresh `UUID`, SHA-256'd, never
  stored, never reused — so it ties to nothing: not the install id, not the crash-report id, not each
  other), an empty payload, and no version / device / locale / content. Just a bare count.
  TelemetryDeck stores no IP and salts the hash again server-side.
- **Not via the SDK.** It's a single direct `POST` to TelemetryDeck's V2 ingest
  (`https://nom.telemetrydeck.com/v2/`, matching the SDK's `SignalPostBody` wire shape), *not*
  `TelemetryDeck.initialize` — because initializing the SDK would spin up ongoing session tracking,
  which is exactly what an opted-out user must not get.
- **Exactly once.** Latched by the `analytics.installCounted` UserDefaults flag, set **only after a
  confirmed 2xx** — so an offline first launch simply retries next launch until the count lands once
  (a reinstall clears the flag and counts again, same coarseness as `installID`).
- **Release-only**, like everything else here (a dev's Debug launches never inflate the count).
- **Fires for every install** (opted in or out), so the headline metric is clean and uniform: build a
  TelemetryDeck Insight on **unique users of the `App.anonymousInstall` signal** = total installs.
  Opted-in installs additionally send the rich signals in the table above; this ping is the one
  number that's complete across everyone.

Called once from `main.swift` (the `.app` branch), right after `Analytics.start()`. Opting out of
analytics silences the whole EXTENDED tier (the rich funnel + health signals) and any correlatable
identity — but the tiny CORE tier keeps sending: the five always-on usage counts marked 🟢 in the
table above (`Command.submitted`, `Home.opened`, `Proactive.prepared`, `Proactive.actionFired`,
`Scheduler.overnightCompleted`), the SDK's launch/session signals, and this anonymous install tally.
Counts only, no correlatable identity — disclosed verbatim in the switch's off-state caption.

The knowledge-base and proactive-stage signals live centrally in `ProactiveCycle.run()` — the one
place with all the counts and the create-vs-update decision — rather than scattered into
`VaultCloud`/`Proactive`/`ProactiveResearch`, so they can't double-fire.

## Adding a signal

Call the wrapper, never TelemetryDeck directly:

```swift
Analytics.signal("Area.thing", parameters: ["count": "\(n)", "kind": kind.rawValue])
```

`Analytics.signal` is nonisolated + a no-op until started / when opted out, so it's safe from any
actor or thread. Keep names dotted (`Area.thing`) and parameters structure-only.

## Verification (how it was proven)

Because sends are Release-only, verify from a **Release build** (Debug sends nothing by design):

1. **Wire:** a standalone SPM executable using the same SDK + App ID + config sent live signals;
   TelemetryDeck's ingest server (`POST nom.telemetrydeck.com/v2/`) returned `OK` and the SDK's
   cache flushed to 0 (a rejection logs `Failed to send events (status …), will try again`).
2. **App path:** running the real Release binary logged `Analytics: TelemetryDeck started` and exited
   clean — the shipping `start()` path initializes without crashing.
3. In the TelemetryDeck dashboard, signals appear under the app; the **Test Mode** toggle separates
   Debug-config (test) signals from live ones.

## Files

- `Diagnostics/Analytics.swift` — `start()`, `signal(_:parameters:)`, `countInstallOnce()` (the opt-out-independent anonymous install ping), `applyEnabledChange()`, the `analyticsEnabled` opt-out, the App ID constant.
- `App/main.swift` — `Analytics.start()` and `Analytics.countInstallOnce()` in the `.app` branch.
- `Diagnostics/CrashReporting.swift` — the `installID` identity (shared) + Sentry's separate `diagnosticsEnabled` opt-out.
- `Views/Settings/SystemPane.swift` — the two Privacy toggles; each `onChange` calls its own `applyEnabledChange()`.
- The ~12 call sites in the table above.
- SPM package `github.com/TelemetryDeck/SwiftSDK` (product `TelemetryDeck`), pinned up-to-next-major from 2.0.0.
