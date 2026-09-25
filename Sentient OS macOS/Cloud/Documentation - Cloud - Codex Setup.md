# Codex setup

Sentient prepares the user's frontier CLI, login and selected computer-use dependency through shared
setup code. Browsing engine tabs downloads nothing; installation starts at an engine commitment,
onboarding's existing background setup, an explicit repair, or a computer-use task that needs it.

## Owners

| Owner | Job |
|---|---|
| `CodexSetup` | Discover, install/update and log in to Codex CLI; expose shared progress and retry state. |
| `ClaudeSetup` | The equivalent CLI and login flow for Claude Code. |
| `ComputerUseSetup` | Prepare the selected computer-use runtime, independently of either CLI's installation. |

ChatGPT uses OpenAI's signed native helper. Claude and custom model endpoints use CUA. The native
helper is extracted from OpenAI's official installer into the existing Codex home; no new CLI,
desktop app installation, plugin configuration or login copy is needed. CUA keeps its pinned,
checksum-verified download. Details live in the two Driver docs.

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
only for a Codex-backed engine; Claude's updater self-guards for its own backend. The existing
stale-client repair and health signals remain the reactive paths. A package-manager installation is
not silently modified by the background updater.

## Computer-use preparation

`ComputerUseSetup.instance(for:)` owns one installation task per runtime. Onboarding, Settings,
upgrade, repair and task startup join the same work. Progress distinguishes downloading, preparation,
verification and publication. STOP cancels a task's wait without canceling a shared background
installation. Uninstall cancels and drains both installers before removing managed support files.

ChatGPT preparation verifies the existing native helper or installs one. It verifies the signed
service and client plus a local MCP initialization handshake before use. CLI and native-helper
versions are independent; updating the CLI does not automatically redownload the helper. A newer
compatible helper is preserved if the public installer carries an older build.

The onboarding analysis takeover retains its two-minute deferred computer-use setup. The selected
runtime is resolved when that work starts. A Settings commitment to another engine prepares that
engine's dependency; browsing tabs does not. First-use permission gates remain responsible for
macOS consent, and a task waits for unfinished installation.

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
