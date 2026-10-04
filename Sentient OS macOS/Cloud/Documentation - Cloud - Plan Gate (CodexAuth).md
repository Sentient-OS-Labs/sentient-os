# The Plan Gate: CodexAuth & knowledge-base-only mode (Cloud/)

This gate describes the selected **ChatGPT plan**, not a general requirement to buy a subscription.
Supported Claude and custom backends use their own availability checks. Apple Mail and Apple Calendar
provide locally analyzed email/schedule context with a custom backend; Double Tap has a separate
provider setting. See the Frontier Model Choice guide for those options.

Sentient reads the user's ChatGPT plan from their own codex login and adapts. Free and Go accounts have
a tiny monthly codex quota (the first knowledge-base build alone eats most of it) and no ChatGPT
connectors, so instead of a broken full experience they get an honest fork at onboarding and a scoped
**knowledge-base-only mode**: the knowledge base, the Knowledge window, the MCP mirror, and the gift
letter, with proactive cards, Sidekick, nightly runs, and Gmail/Calendar gated behind Plus. A
non-ChatGPT backend bypasses the whole gate: the Claude engine gates itself (Claude Code has no free
tier, so logged-in IS the plan — ClaudeAuth in the ClaudeCLI doc), and a custom endpoint is the
user's own compute (the BYOM doc).

## File

`CodexAuth.swift`: plan detection, the on-demand token refresh, and the two persisted flags.

## Detection (no network)

`~/.codex/auth.json` holds OAuth tokens that are JWTs; their claims carry `chatgpt_plan_type` under
`https://api.openai.com/auth`. `CodexAuth.currentPlan()` decodes it off disk (id_token first,
access_token as backstop). Tier policy: `free` and `go` → `.limited`; everything else (plus, pro,
team, business, edu, enterprise, unknown future strings) → `.full`. **Fail open**: no file, API-key
auth, or an undecodable claim reads as full. Only a POSITIVE free/go read gates anything; worst case a
limited account hits codex usage-limit errors, which every caller already survives.

`isLimited()` is `!assertedPlus && currentPlan()?.tier == .limited`, the convenience most gates read.
Enforcement is entirely server-side (OpenAI rate-limits by account state); the claim is only how we read
the plan.

## Refresh (`refreshPlan()`)

Codex only re-mints its tokens every 8 days, so an upgrade would go unnoticed for days. `refreshPlan()`
replays codex's own refresh: `POST https://auth.openai.com/oauth/token` with codex's public client id
and the refresh token, then writes the result back exactly as codex would (only the returned fields,
every other key preserved, `last_refresh` reset, 0600 permissions, atomic replace). Handled edges:
refresh tokens rotate (the new one MUST be written back or the login breaks), so the write-back is
atomic and success-only; the call is single-flight (two concurrent POSTs would present a consumed
token); and the server's `earliest_refresh_at` throttle is persisted (`plan.earliestRefresh`) and
respected, so focus-return re-checks can never hammer the endpoint. A non-OK status emits
`codex_auth.refresh_failed` (status code only).

## The two flags

- **`knowledgeBaseOnly`** (`plan.kbOnly`): the user's CHOICE at the crossroads to continue with just the knowledge base. This is the gate every limited-mode surface checks. The getter reads false whenever a non-ChatGPT backend is active (the free/go limitation is a ChatGPT-plan fact; Claude and custom engines gate themselves); the stored value is preserved so switching back to ChatGPT restores the free/go experience.
- **`assertedPlus`** (`plan.assertedPlus`): the user told us they upgraded and we believed them (the crossroads' "I've upgraded to ChatGPT Plus" plus a native confirm). Needed because a just-paid upgrade can read free/go on disk for a while (the claim lags, the refresh can be throttled), and OpenAI's server is the real enforcement point anyway. Sticky; makes `isLimited()` false everywhere (chiefly so `CodexCLI.backendTuned` stops downshifting them off `gpt-6-sol`). Reset clears it.

`connectorsLocked` (free/go OR a custom backend) and `connectorLockedTip` are the one predicate and the
one wording every Gmail/Calendar chip uses.

## What knowledge-base-only mode changes

| Surface | Behavior |
|---|---|
| Onboarding | The plan crossroads (`OnboardingPlanView`) appears right after the frontier-model step, for free/go ChatGPT only; full plans, the Claude engine, and custom engines skip it before it renders. Choices: upgrade on ChatGPT (opens the pricing page, then the screen quietly re-checks on foreground via `refreshPlan`), "I've upgraded" (the trust path), or continue with just the knowledge base. |
| `OvernightScheduler.maybeAutoEnable()` | Returns early: no 14h auto-enable, no 3 AM runs. Not latched, so an upgrade plus reset starts the clock fresh. |
| `ProactiveCycle` | Skips decide and research (saves an empty ready list so stale cards never linger). Knowledge base, mirror push, gift letter, and the wipe still run. |
| Sidekick | The hotkey stays armed for everyone, but a press, a notch click, or a command-bar submit is answered instantly with a 2 s aside ("get ChatGPT Plus to wake Sidekick") and the run never fires. Checked live per press. |
| Home | The command bar is hidden. The always-mounted preview note (orb + "This is a preview of Sentient." + the three feature rows + a Get ChatGPT Plus glow + a Reset Sentient… pill) replaces the empty state; the gift envelope perches above a compact version of it. Once the claim reads Plus, it becomes "You're on Plus. Time to go live." with a Reset & Rebuild glow. No health banners on the free home. |
| Gmail / Calendar chips | Locked (dim, lock glyph, hover tip) in onboarding's ready screen, the Analysis popover, and Settings → Knowledge Sources. |
| Settings → Health | A "ChatGPT plan" row (amber when limited) with a Re-check pill → `refreshPlan()`. |
| `CodexCLI.backendTuned` | `gpt-6-sol` calls downshift to `gpt-5.6-terra` at medium on a positive free/go read. |

Deliberately NOT gated: Analyze Now. The on-device read is free; the knowledge-base update spends the
user's leftover quota until codex's usage-limit error stops it gracefully (summaries kept).

## The upgrade path

Reset (Settings → System, or the free home's buttons, which deep-link there) rewinds to the start of
onboarding; re-onboarding re-runs the crossroads, which re-detects the plan fresh, and a now-Plus user
gets the full experience with connectors. Passive detection also exists: codex's own 8-day refresh, the
home re-decoding the claim on every appearance, and the Health row's Re-check.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md` (`backendTuned`), `Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md`, `Views/Onboarding/Documentation - Onboarding.md`, `Views/Documentation - Views - Home, Processing & Shared UI.md` (the preview home).
