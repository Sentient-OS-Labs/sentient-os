# Plan Gate — CodexAuth & Knowledge-Base-Only Mode

Sentient knows the user's ChatGPT plan and adapts. Free/Go accounts carry a tiny **monthly**
codex quota (the initial knowledge-base build alone eats ~70% of it at `.high` — the effort every
plan runs since 2026-07-10) and no
ChatGPT connectors (Gmail/Calendar) — so instead of a broken full experience they get an honest
fork at onboarding and a scoped **knowledge-base-only mode**. Everything here shipped and was
verified on real hardware (a real Free login walked end-to-end), July 2026.

## 1. Detection — `Cloud/CodexAuth.swift`

`~/.codex/auth.json`'s OAuth tokens are JWTs whose claims carry `chatgpt_plan_type` under the
`https://api.openai.com/auth` key. `CodexAuth.currentPlan()` decodes it straight off disk — a
pure file read, no network, safe every launch and every cycle.

- **Tier policy:** `free`/`go` → `.limited`. Everything else — plus, pro, prolite, team,
  business, edu, enterprise, unknown future strings — → `.full`. **Fail open**: no file, no
  tokens (API-key auth), or an undecodable claim all read as full; only a POSITIVE free/go
  read gates anything. Worst case a limited account hits codex usage-limit errors, which every
  caller already survives (typed `.usageLimit` + resume handles).
- Plan **enforcement** is entirely server-side (OpenAI rate-limits by its own account state, per
  `X-Codex-Plan-Type`); the JWT claim is only how *we* read the plan. The codex client itself
  uses the claim purely for display.

## 2. Refresh — noticing an upgrade in seconds, not days

Codex only re-mints its tokens every **8 days** (`TOKEN_REFRESH_INTERVAL` in codex-rs
`login/src/auth/manager.rs`), on a 401, or ~5 min before access-token expiry — running `codex`
does NOT refresh the claim (measured: days of exec sessions + a TUI cold start, zero writes to
auth.json). So `CodexAuth.refreshPlan()` replays codex's own refresh flow on demand:

```
POST https://auth.openai.com/oauth/token
{ client_id: "app_EMoamEEZ73f0CkXaXp7hrann",   // codex's public constant
  grant_type: "refresh_token", refresh_token: <from auth.json> }
```

⚠️ Sharp edges, all handled — don't regress them:
- **Refresh tokens ROTATE.** The response's new `refresh_token` MUST be written back or the
  user's codex login bricks ("refresh token was already used"). Write-back is atomic
  (temp + replace), 0600, preserves every key we don't own, sets `last_refresh = now` — so
  afterward auth.json is indistinguishable from a codex-native refresh (codex's own 8-day
  timer simply restarts).
- **Single-flight**: one in-flight refresh max (two concurrent POSTs = the second presents a
  consumed token). `@MainActor` task reuse in `refreshPlan()`.
- **Server throttle**: the response's `earliest_refresh_at` is persisted
  (`plan.earliestRefresh`) and respected — before it, `refreshPlan()` returns the on-disk claim
  without a network call. This is what makes focus-return re-checks spam-safe.
- Failure never touches the file and never blocks anything (the row/screen just keeps the
  current claim).

Verified live end-to-end: refresh → rotation → write-back → `codex login status` OK → a real
`codex exec` on the rotated tokens.

## 3. The crossroads — `Views/Onboarding/OnboardingPlanView.swift`

The onboarding step between codex login and the ready screen. **Full plans auto-advance before
a pixel renders** (also the relaunch-mid-onboarding case; the Back button knows to skip over it
for them). Free/go accounts see:

> YOUR CHATGPT PLAN · FREE
> **We noticed you're not on ChatGPT Plus.**
> Right now, Sentient uses your ChatGPT plan's Codex frontier model for a small part of its
> compute. / You can still build your private knowledge base from this Mac and offer it to
> your AIs. · WITH CHATGPT PLUS: the three feature rows (same vocabulary as the free home)
> · [Upgrade on ChatGPT] (glow) · (Continue with just the knowledge base) (QuietPillButton)

- **Upgrade** opens `CodexAuth.upgradeURL` and enters a waiting state: auto-recheck on app
  foreground (`refreshPlan()`) + a manual "I've upgraded" button; silent when still free on
  focus-return (they may just be reading), explicit status line on manual checks. Unlock →
  green done line → auto-advance.
- **Continue** sets `CodexAuth.knowledgeBaseOnly` (`plan.kbOnly`) — THE app-wide gate flag.
- Analytics: `PlanGate.shown` (with the raw plan string) / `.upgraded` / `.continuedFree`.

## 4. Knowledge-base-only mode — every gate, in one list

`CodexAuth.knowledgeBaseOnly` is the user's *choice* (distinct from the live claim). What it
flips:

| Surface | Behavior |
|---|---|
| `OvernightScheduler.maybeAutoEnable()` | Early-returns — no 14h auto-enable, no timer, no 3am runs. Deliberately NOT latched: upgrade + reset starts the clock fresh. |
| `ProactiveCycle` | Skips decide + research (saves an empty ready-list — no stale cards). Still runs: read → KB build/update → mirror push → gift letter → wipe. |
| Sidekick | Gated at **invoke**, not arming: the hotkey stays armed for everyone; on press the notch answers instantly with the 2s aside "get ChatGPT Plus to wake Sidekick" (the mic-notice pattern) and never opens for listening/typing. `submit()` carries a backstop for the command-bar path. Live-checked per press — no stale-launch-flag hole. |
| Home | Command bar hidden. The **preview note** (orb + "This is a preview of Sentient." + feature rows + Get Plus glow + Reset Sentient… pill) is ALWAYS mounted; the gift envelope perches top-center above a compact version of it and the note blooms to full center when the letter is flung. Once the claim reads Plus (re-read every appearance), it becomes "You're on Plus. Time to go live." + a Reset & Rebuild glow. |
| Gmail/Calendar chips | Locked (dim + lock glyph + instant `LockedChipTip` hover: "Only supported on ChatGPT Plus") in onboarding's ready screen, the Analysis popover, and Settings → Knowledge Sources. |
| Settings → Health | "ChatGPT plan" row (amber when limited, keeps the codex group expanded) with a **Re-check** pill → `refreshPlan()`. |

Deliberately NOT gated: **Analyze Now.** The on-device read is free; the KB-update tail spends
their leftover quota until codex's usage-limit error stops it gracefully (summaries kept). Free
users effectively get a couple of manual KB refreshes a month — the *nightly* learning is the
Plus promise.

## 5. The upgrade path

Reset is the rebuild: `FactoryReset.run(appState:)` now **rewinds to the start of onboarding**
(clears `onboarding.step`, `plan.kbOnly`, `hasCompletedOnboarding`; flips the live AppState so
the main window switches immediately; Settings dismisses itself). Re-onboarding re-runs the
crossroads, which re-detects the plan fresh — a now-Plus user silently skips it and gets the
full experience with connectors. The free home's "Reset & Rebuild" / "Reset Sentient…" buttons
deep-link there via `SettingsView.requestedPane = .system`.

Passive detection: codex's own 8-day refresh keeps the claim fresh-ish, the home re-decodes it
every appearance, and the Health row's Re-check is the manual lever — so an upgrade is noticed
without any push machinery.

## 6. Receipts & field notes

- The refresh endpoint/constants come from codex-rs source (`login/src/auth/manager.rs`); the
  claim shape was verified against live auth.json files.
- OpenAI's own issue tracker documents plan changes lagging server-side after upgrade/renewal
  (codex #30772 + dupes, #29243) — hence the crossroads' patient "it can take a minute after
  paying" retry copy instead of hard failure.
- A ~$20 ChatGPT **Plus** subscription remains the product's requirement for the FULL
  experience; free/go is a deliberate preview tier (the knowledge base + Knowledge window +
  MCP mirror + gift letter), not a supported full tier.
