# ChatGPT plan identity and provider limits

The selected provider enforces its own account access and usage. Free/Go users can enter Home and
use Sidekick; a local plan label no longer hides the composer or forces a knowledge-only onboarding.
Claude and custom endpoints continue to use their own login, configuration and availability paths.

## Plan identity

`CodexAuth.currentPlan()` reads `chatgpt_plan_type` from Sentient's private Codex authentication file,
`CodexRuntime.auth`. Tokens, standalone Codex state and accounts from other installations are not
imported. The local `free`/`go` classification is a hint for existing model selection and recovery
copy, not proof that a task will succeed or fail. Unknown claims fail open; only the provider can
establish current account access.

`isLimited()` respects the existing `assertedPlus` compatibility flag. The existing model-resolution
policy in `CodexCLI.backendTuned` remains separate from onboarding. Connecting or browsing a provider
does not authorize another provider, silently switch an active run, or change billing.

## First launch and migration

The frontier-model screen can explain limited usage, but Continue enters the full Home after a
successful connection. `PersonalSetupProgress.migrate` retires `plan.kbOnly` on normal launch without
resetting any knowledge, sources, history or credentials. Frontier Continue also clears that old flag.
`OnboardingPlanView` and the old Home preview remain historical/developer surfaces, not routes in
the production onboarding. An upgrade never requires Reset & Rebuild.

## Evidence-based recovery

`SidekickUpgradeOffer` accepts only a real Codex CLI usage-limit error or explicit provider plan
denial from a task captured on the ChatGPT backend, with a known Free/Go claim and no asserted upgrade.
The original typed error is carried into `SidekickRecoveryContent.failure`; displayed text and model
reports are not reparsed into billing evidence.

Home and notch share Upgrade to Plus, Change AI, Try again and Stop. Upgrade opens the existing
pricing URL only on a click. Retry retains the task's existing recovery/session semantics and user
guidance. Network, permission, unsupported-model and unrelated connector quota errors never suggest
paying for Plus. Claude/custom tasks never show the ChatGPT upgrade action.

## Plan refresh

`refreshPlan()` remains a single-flight OAuth refresh for an explicit re-check. Successful token
rotation is written atomically with private permissions; server throttle dates are respected. A stale
local claim is not an authorization bypass or a reliable live quota meter.

## Verification

`Scripts/test_sidekick_plan_recovery.py` exercises backend, plan, typed-error and exclusion cases;
the Sidekick lifecycle/tool suites cover retry and cancellation. Onboarding provider selection tests
ensure a committed engine clears the retired local mode and that cancelled/failed selections do not
advance or overwrite another provider.

Related: the Frontier Model Choice, CodexCLI, Sidekick conversation, and Onboarding guides.
