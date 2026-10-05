# Codex setup

Sentient starts shared Codex CLI and native computer-use preparation in the background on every
normal app launch, including the first onboarding screen and before model selection. Compatible
installations are reused. Claude Code and model sign-in remain tied to the selected engine.

## Owners

| Owner | Job |
|---|---|
| `CodexSetup` | Discover, install/update and log in to Codex CLI; expose shared progress and retry state. |
| `ClaudeSetup` | The equivalent CLI and login flow for Claude Code. |
| `ComputerUseSetup` | Own shared startup preparation of Codex CLI and the native helper, plus repair and task-time checks. |

Every model backend uses OpenAI's signed native helper through Codex CLI. Claude users keep their
Claude login for inference and need no ChatGPT login. The helper is extracted from OpenAI's official
installer into the existing Codex home; Sentient installs no desktop app or permanent plugin config.
Legacy CUA installation records are used only for migration and cleanup.

## CLI preparation

`ensureCurrent()` is the commitment/version gate. It detects the installed CLI, checks the release,
and runs OpenAI's official installer if preparation is needed. Concurrent callers share one task.
A failed update that leaves an older executable in place does not count as a successful update.
`ensureInstalled()` is the lighter presence-only entry point. Installation has bounded retries and
an explicit manual-install fallback.

`startLogin(force:)` starts `codex login`, which opens the browser. Onboarding and Settings notice
completion through `loginStatus`; the dev surface also has an explicit confirmation button. Login
URLs are elided from diagnostics. Sentient reuses the existing Codex authentication.

The managed CLI updater checks at most daily, when the user is away and no task is active. It runs
for every backend that has a managed Codex installation; Claude's updater self-guards for its own backend. The existing
stale-client repair and health signals remain the reactive paths. A package-manager installation is
not silently modified by the background updater.

## Computer-use preparation

`ComputerUseSetup.instance(for:)` owns one installation task per runtime. App launch, Settings,
upgrade, repair and task startup join the same work. Progress distinguishes downloading, preparation,
verification and publication. STOP cancels a task's wait without canceling a shared background
installation. Uninstall cancels and drains both installers before removing managed support files.

`ensureComputerUseCLI()` requires Codex 0.160.0 or newer and a runnable binary, sharing any needed
preparation. It never initiates ChatGPT sign-in. Computer-use preparation then verifies the existing
native helper or installs one. It verifies the signed
service and client plus a local MCP initialization handshake before use. CLI and native-helper
versions are independent; updating the CLI does not automatically redownload the helper. A newer
compatible helper is preserved if the public installer carries an older build.

`AppState` calls `prepareForLaunch()` after the headless self-test guard and migration detection.
It registers the shared installation immediately and returns without waiting for network or CLI
work. Onboarding has no deferred setup timer. A routine launch check does not show an update banner;
Health also waits for the shared installation to finish before reporting a broken runtime, and
rechecks on completion or failure. An established runtime missing required components retains its
repair notice. Failed setup remains
retryable through Settings, first use, or a later launch. First-use permission gates remain
responsible for macOS consent, and a task waits for unfinished installation. Browsing engine tabs
does not start another download or a login.

## Invariants

- Computer-use setup never edits Codex configuration, login tokens, skills or plugin policy.
- Installation and macOS permission requests are separate operations.
- A dependency's presence alone does not establish task success or permission readiness.
- The selected backend is captured for a task; its runtime instructions and transport agree.

## Related docs

`Driver/Documentation - Native Computer Use.md`, `Driver/Documentation - Driver (cua-driver).md`,
`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`,
`Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md`,
`Views/Permissions/Documentation - Permission Gate & Guide.md`.
