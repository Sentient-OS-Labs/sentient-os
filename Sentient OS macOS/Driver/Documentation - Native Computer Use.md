# Native computer use

Sentient chooses the computer-use runtime independently of the frontier CLI. ChatGPT uses OpenAI's
signed native helper through `codex exec`. Claude and custom endpoints use the existing CUA driver.
Every task still enters through `CommandCoordinator` and `FrontierRun`; there is one task lock,
progress stream and STOP path.

## Files and responsibilities

| File | Responsibility |
|---|---|
| `ComputerUseBackend.swift` | Maps the selected model backend to OpenAI or CUA and selects its operating instructions. |
| `ComputerUseSetup.swift` | One observable installer instance per runtime, shared by onboarding, Settings, repair and task startup. |
| `OpenAIComputerUse.swift` | Finds and validates the native helper, launches it for permission checks, and builds its per-run MCP configuration. |
| `OpenAIComputerUseSetup.swift` | Downloads the official installer, extracts the signed helper, and publishes it atomically. |
| `DependencyDownload.swift` | Cancellable, streamed downloads with byte progress and HTTP validation for both runtimes. |

The CUA binary, catalog, manual, daemon and transport remain in their existing files. See
`Documentation - Driver (cua-driver).md` for that runtime.

## Installation

The native installer reuses the user's existing Codex home, normally `~/.codex`. It only installs
`computer-use/Codex Computer Use.app`, including the nested `SkyComputerUseClient.app` and all signed
resources. It does not install a separate CLI, a desktop app, plugin files, or a new login. It never
rewrites Codex configuration, skills, notification hooks or authentication.

A valid existing helper is reused. Otherwise the installer downloads OpenAI's desktop DMG directly
from its official CDN, mounts it read-only, and locates the helper by its bundle layout rather than
the desktop app's display name. The public distribution currently requires downloading the complete
installer to extract this dependency; Sentient does not host a copy.

Validation requires the expected helper identity, an executable service and nested client, a supported
build and macOS version, OpenAI's signing team on both bundles, and a successful native MCP initialize
handshake. The handshake is local and does not inspect any app or consume a model call.

The complete helper is staged beside its destination. Publication uses an exclusive rename for a
fresh installation or an atomic directory exchange for replacement. The previous bundle remains
available until post-install validation succeeds. Cancellation and failures preserve a working
installation. Failed rollback retains the previous bundle in staging instead of deleting it.
The disk image is detached using its resolved mount path, including during cancellation. Staging is
retained if a mount cannot be safely detached. A file lock serializes Sentient installer instances.
An active helper is not replaced, and an installation changed by another app is re-evaluated on retry.

The public DMG can lag the desktop updater. A newer compatible, verified helper is retained rather
than downgraded. The CLI and helper have separate versions; a CLI update does not automatically
redownload the helper. Sentient's minimum supported helper build is a tested compatibility floor.
A change to that floor requires a new artifact and runtime check.

An installation receipt under Sentient's Application Support records the helper version, path and
whether Sentient created the original installation. Uninstall drains both installers and preserves
the shared Codex home, including the helper. Another Codex installation may be using those files.

## Running a task

`FrontierRun.runAgentCommand` captures the model backend and adds the matching runtime instructions
exactly once. `CodexCLI.runAgentCommand` prepares and validates the OpenAI helper for ChatGPT; it
prepares the CUA daemon only for custom endpoints. Claude always prepares CUA.

Native tools are registered directly for that invocation as `sentient_native`, using the nested
client executable with the `mcp` argument. Registration is required, so a missing or incompatible
client fails startup. No app-server integration or permanent plugin configuration is involved.
The existing model/speed choice, connector policy, direct MCP connections, streaming and computer-use
approval mode are preserved. Ordinary structured runs do not receive these computer-use tools.

The native instructions explain app-state reads, tool discovery, fresh-state verification and the
background interaction path. Sidekick and card wrappers stay runtime-neutral. App contents remain
data, never instructions that can expand the user's task.

STOP cancels the owned CLI process and closes its client connection. It does not terminate a shared
OpenAI helper used by another app. An explicit final `STATUS: DONE` is required for completion;
missing or malformed status is unconfirmed, and `STATUS: COULD_NOT` is a failure even if the CLI exits
zero. Cancellation remains a separate stopped outcome.

## Permissions and setup surfaces

The native path needs Sentient's Apple Events entitlement plus user-granted Automation access to
OpenAI's helper. The helper has its own Accessibility and Screen Recording grants; Sentient retains
Screen Recording for Sidekick's screen context. Claude/custom continue using Sentient's own
Accessibility and Screen Recording grants. Microphone and Speech remain optional.

Automation checks use Apple's asynchronous permission API after starting the helper through
LaunchServices. A stopped target is not treated as denied permission. Visible setup surfaces request unasked Apple Events consent through the macOS dialog. There is no
separate Automation row; the user still chooses Allow in the system prompt. Denial exposes a Settings
action without another automatic prompt. Background checks never request consent and no TCC database is written. Normal startup and Factory Reset preserve
the grant. Uninstall uses `tccutil` to reset only Sentient's Apple Events access.

`ComputerUseGate`, its shared permission rows, Settings health and migration all select the same
runtime. An engine switch from Settings prepares the selected dependency. Onboarding retains its
existing deferred computer-use setup. Existing CUA users on ChatGPT complete a mandatory native
migration before the regular interface and Sidekick start. CUA installation history and earlier
deferred migrations are recognized even without the old readiness flag. Setup remains pending across
window closure and relaunch until installation and required grants are ready. Native readiness has
its own persistent latch, separate from old CUA history, and Factory Reset clears both readiness and
migration state. Fresh onboarding and later repairs of an already-migrated installation retain their
existing flows.

## Validation boundary

Acceptance exercises must use signed Sentient builds and the real `FrontierRun` paths, with isolated
install roots, CUA caches and synthetic app/browser targets. Installer checks include missing or
modified bundles, cancellation, atomic exchange/rollback, and preservation of a newer helper.
Task checks include both prompt builders, background browser interaction, STOP, immediate recovery,
backend switching and final-result parsing. Debug and Release builds both enforce the CUA contract.

A successful helper extraction on an existing Mac is not a clean-Mac permissions test. New macOS
versions, a new helper layout, first installation without existing desktop components/grants,
additional displays and Safari need their own coverage. Treat the extracted bundle layout and its
native MCP interface as compatibility boundaries, not as a promise that every future OpenAI build
will have the same shape.
