# Native computer use

Every active model backend uses OpenAI's signed native helper through `codex exec`. Claude
subscriptions supply inference through the local ClaudeSubscriptionBridge and official `claude -p`;
custom endpoints use their existing Codex provider configuration.
Every task still enters through `CommandCoordinator` and `FrontierRun`; there is one task lock,
progress stream and STOP path.

## Files and responsibilities

| File | Responsibility |
|---|---|
| `ComputerUseBackend.swift` | Selects native OpenAI computer use for every active backend; retains the legacy CUA identity for cleanup. |
| `ComputerUseSetup.swift` | One observable installer instance per runtime, shared by onboarding, Settings, repair and task startup. |
| `OpenAIComputerUse.swift` | Finds and validates the native helper, launches it for permission checks, and builds its per-run MCP configuration. |
| `OpenAIComputerUseSetup.swift` | Downloads the official installer, extracts the signed helper, and publishes it atomically. |
| `DependencyDownload.swift` | Cancellable, streamed downloads with byte progress and HTTP validation for both runtimes. |

Legacy CUA files remain for installation history, cleanup and compatibility tooling. Active computer
tasks neither install nor launch CUA.

## Installation

The native installer uses Sentient's private Codex home inside
`~/Library/Application Support/SentientOS/Private Codex`, independently of the user's `~/.codex`.
It installs `computer-use/Codex Computer Use.app`, including the nested `SkyComputerUseClient.app`
and all signed resources. ComputerUseSetup also prepares the required Codex CLI, including for Claude users,
without requiring a ChatGPT login. The helper installer does not install the desktop app or plugin
files. It never
rewrites Codex configuration, skills, notification hooks or authentication.

Every normal app launch starts shared dependency preparation in the background, before model
selection and without waiting for onboarding or analysis. Compatible CLIs and helpers are reused.
Settings and computer tasks join the same installation; a routine startup check stays quiet.

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

The private runtime manifest pins and verifies the CLI and helper. Uninstall drains installers and
stops only the helper at Sentient's exact private path; standalone Codex files and credentials remain untouched.

## Competing helper takeover

OpenAI's helper is named **ChatGPT Computer Use** in Activity Monitor, despite its bundle directory
being **Codex Computer Use.app**. Its identity is `com.openai.sky.CUAService`. A user-started Sidekick
task automatically force-quits instances of that identity outside Sentient's private path, waits for
exit, and re-enumerates to catch a concurrent relaunch. It preserves a healthy private helper.
Takeover and startup retries are bounded; they run before any agent tools and never replay actions.

Passive health refreshes leave other apps' helpers alone and retain the conflict internally instead
of presenting a permission error or manual-quit instructions. When the user starts a task, the normal
permission gate resolves the conflict before presenting any setup window. Genuine missing macOS
permissions still use the existing consent flow. Explicit idle repair also handles a foreign helper,
while active Sentient task leases prevent repair from terminating their helper.

Sentry breadcrumbs record takeover outcome, attempt count and terminated count, without process paths
or user content. `test_private_codex_cleanup.py` verifies force-quit, respawn bounds and ownership;
`test_native_helper_startup.py` exercises the full runtime's shared-startup and launch races.
`test_native_helper_takeover.py --app <signed Debug app> [--suspend]` verifies the actual foreground
gate and native capture after starting a competing helper, without a model call or user-app actions.

## Running a task

`FrontierRun.runAgentCommand` captures the model backend and adds the native runtime instructions
exactly once. `CodexCLI.runAgentCommand` prepares a compatible Codex CLI and validates the signed
OpenAI helper for every backend. Claude uses a per-task loopback provider; its model login stays in
the official Claude CLI. The bridge protocol and process ownership are described in the ClaudeCLI doc.

Native tools are registered directly for that invocation as `sentient_native`, using the nested
client executable with the `mcp` argument. Registration is required, so a missing or incompatible
client fails startup. No app-server integration or permanent plugin configuration is involved.
The model/speed choice, prepared direct MCP connections, streaming and computer-use approval mode
are preserved. ChatGPT retains its hosted connector policy. Claude-hosted connectors remain on the
separate structured Claude path and are not advertised in a Codex computer task. Ordinary structured runs do not receive these computer-use tools.

The native instructions explain app-state reads, tool discovery, fresh-state verification and the
background interaction path. Editable text should use `set_value`, with Unicode verified afterward. Sidekick and card wrappers stay runtime-neutral. App contents remain
data, never instructions that can expand the user's task.

STOP cancels the owned CLI process and closes its client connection. It does not terminate a shared
OpenAI helper used by another app. User-owned tasks have no overall execution deadline (`timeout: 0`);
individual native requests still have bounded waits so a broken helper does not hang forever.
After a clean provider exit, completion uses the final saved `message_user` answer's explicit
`completion=done|could_not`, with the exact final `STATUS` sentinel retained for older clients.
An explicit failure wins contradictory claims. Neither a successful tool call nor saving an
answer alone proves success. Cancellation remains a separate stopped outcome.

## Permissions and setup surfaces

The native path needs Sentient's Apple Events entitlement plus user-granted Automation access to
OpenAI's helper. The helper has its own Accessibility and Screen Recording grants; Sentient retains
Screen Recording for Sidekick's screen context. This applies to Claude, ChatGPT and custom models.
Sentient's old CUA Accessibility grant is not needed for native actions. Microphone and Speech remain optional.

Automation checks use Apple's asynchronous permission API after starting the helper through
LaunchServices. A stopped target is not treated as denied permission. Visible setup surfaces request unasked Apple Events consent through the macOS dialog. There is no
separate Automation row; the user still chooses Allow in the system prompt. Denial exposes a Settings
action without another automatic prompt. Background checks never request consent and no TCC database is written. Normal startup and Factory Reset preserve
the grant. Uninstall uses `tccutil` to reset only Sentient's Apple Events access.

`ComputerUseGate`, its shared permission rows, Settings health and migration all select the same
runtime. An engine switch from Settings joins the shared preparation if needed. Onboarding uses the
setup already started by AppState at launch. Existing CUA users on every backend complete a mandatory native
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
Task checks include both prompt builders, screenshot-only vision, Unicode, local file access, retry
deduplication, STOP, immediate recovery, parent exit, quota errors,
backend switching and final-result parsing. Debug and Release builds both enforce the CUA contract.

Acceptance has verified Claude-backed native actions with Codex 0.160.0, Claude Code 2.1.284,
and helper build 1001365, including an isolated Codex home with no OpenAI authentication and a fresh
helper download. Sonnet low/medium and Opus medium were exercised through the signed app.

A successful helper extraction on an existing Mac is not a clean-Mac permissions test. New macOS
versions, a new helper layout, first installation without existing desktop components/grants,
additional displays and Safari need their own coverage. Treat the extracted bundle layout and its
native MCP interface as compatibility boundaries, not as a promise that every future OpenAI build
will have the same shape.

## App-window startup grace

`NativeComputerUseServer` quietly retries only `get_app_state` for recognized transient window,
read-timeout and capture failures. It makes the initial read plus at most three re-reads, waiting
2, 3 and 5 seconds. All attempts share a 90-second monotonic deadline inside the 130-second MCP
call timeout; each native session request receives the remaining budget. A client request timeout
closes the broken session, but its tool error still reaches the agent so it can explain or choose
another available route. It does not terminate the model process.

If the agent next requests `get_app_state` or `list_apps`, the broker replaces a dead model-free
session before that read. It clears verified app state and never replays the failed call. A new
mutation still requires a successful fresh state read. Ordinary tool errors do not restart healthy
sessions. STOP cancels and drains a connection being opened. Reconnection is recorded as
`recovery_decision=reopen_on_read`, independently of the task's outcome.

The same pending model tool call spans these attempts, so recoverable startup failures do not
become failed chat steps, final responses or recovery prompts. Success after a retry records
`recovered`; intermediate attempts record content-free `skipped` capture evidence with
`recovery_decision=wait_and_reread`. Only the final failure emits the warning event. STOP cancels
backoff immediately, and the actor’s closed guard prevents another read after shutdown.

Click/send/type/like and other actions are never automatically replayed. Permission/auth denials,
malformed replies and transport failures remain honest failed tool results. No helper restart,
window activation/restoration or permission change is added. Shared model guidance separately
asks the agent to wait and re-read visible splash/loading screens before escalating to the user.

## Agent-owned recovery

`ComputerUseStream` only records activity and formats progress. It never interprets a native
tool error as a reason to terminate the agent. The native server no longer stores a sticky failure
that blocks all subsequent calls. After a failed read, permission denial or stale-target error,
the next explicit model request can inspect state again. A dead transport is replaced on a new
read; a failed replacement remains a tool error for the agent to assess.

The `structuredContent.sentient_native_failure` contract carries diagnostic evidence, not a
termination decision. Failed operations invalidate verified app state, and another mutation needs
a successful `get_app_state` first. The model receives useful bounded error detail, fresh-read
guidance and an explicit warning when an action's effects may be unknown. No mutation is replayed.

Codex's CLI error events can contain `status: failed`, `error: null`, and a `result` with
`structured_content` but no `isError` flag. The failed event itself supplies the classification
context; a null error field must not erase it. Recovery text is a single MCP text block containing
the error, original bounded detail and next-step guidance, because Codex's model-facing executor
can retain only the first text block from an error. An unsupported `set_value` on a text input
requires fresh state and a suitable typing/focus method, not a permissions repair.

Chromium guidance recommends one focused re-read/retry, then reassessing the method or asking
the user when needed. There is no browser-specific counter or automatic task termination in code.
Duplicate or ambiguous RPC requests remain rejected without executing their action; the agent
receives that error too. Explicit Stop, actual process failures and execution/history integrity
failures retain their cancellation/error paths.

Consumed RPC IDs are retained as compact hashes for the task's lifetime, with only eight response
bodies cached. There is no fixed request-count ceiling: long tasks must not become permanently
blocked after 1,024 calls. An evicted request ID is rejected rather than executing its action twice.
Successful JSON-RPC replies may include `error: null`; only a non-null error is a failure.

Stage Manager's unreadable thumbnail is a blocker only when the next necessary step needs visual
information and the accessibility tree cannot supply it. Runtime state reads accept usable text
without requiring a screenshot. Invalid image blocks are removed when useful text remains, with
the missing screenshot disclosed to the model. Empty/error-only and unusable image-only results
remain failed tool calls. The agent decides whether the remaining evidence suffices, asks for
help if needed, and never guesses pixel coordinates. Explicit screenshot/vision probes remain strict.

Network-path changes are advisory. While the provider is alive and its transport can retry, the
notch and Home show "You might be offline. Retrying..." without cancelling or restarting the task.
Reconnection reveals the latest retained progress. A real final provider failure still ends the
attempt with its actual error; an offline hint never overwrites a successful result.

`Scripts/test_native_read_retry.py` compiles the actual server/policy/classifier/validator with
inert peers, checking recovery and exhaustion, real delays, deadline accounting, cached request
IDs, action exclusions and cancellation. `test_native_capture.py` also checks the real session’s
per-request timeout/cleanup contract. These fixtures never operate real apps or call a model.
`test_native_session_recovery.py` exercises real local RPC subprocess exits, fresh-read recovery,
uncertain actions, long tasks, nullable errors and Stop during reconnection. Capture diagnostics
also record a best-effort cached Stage Manager flag; that flag never gates or terminates a task.

## Explicit check and repair

`ComputerUseDoctor` owns the small **Test & repair computer use** window in Permissions & Health.
It verifies the installed signed runtime, observes Automation and TCC state, and tests an app-owned
window with a per-check marker. The real native tools must read that marker, return a decodable
screenshot, click a uniquely identified test button, and set/read back the test field. The controls'
actual AppKit state verifies the actions. Missing/ambiguous controls, lost focus or a Space change
interrupt the check without guessing coordinates or labelling the computer broken. Text entry uses
`set_value`; this is not a claim that every app's keyboard input or every window will work.

Standalone checks reserve the idle runtime; ordinary task startup waits cancellably for that
reservation, and a separate repair cannot reserve an active agent. The probe holds the runtime's
shared file lease. Restart/reinstall first require its exclusive lease, respecting tasks in other
Sentient processes too; a busy lease is reported without interrupting them. An incomplete/invalid
helper can use the existing pinned installer after stopping only the private helper. The install
wait is cancellable, and reset/uninstall drain an active diagnostic before deleting its state.
A confirmed connection/capture startup problem can restart the idle helper once and rerun all
checks. No TCC edits or automatic grants. An explicit
ScreenCaptureKit user-denied error is permission evidence; an unreadable TCC database is unknown.
`repairVerified` becomes true only after the complete real probe passes.

The native broker additionally advertises `diagnose_computer_use` for every provider. This is a
last-resort model-requested tool, never automatically triggered by errors. The broker requires
three qualifying failed UI reads across at least two actual apps (including a non-browser), or
three failed global app-discovery reads. Any usable app read or action clears the evidence. Browser-only,
single-app, stale-state, focus, typing and Space problems do not qualify. Known missing or unverified
permissions direct the model to focused recovery or Health; a diagnostic offer requires confirmed grants.
This gate only controls diagnostic offers, never the original task or ordinary recovery tools.

An eligible first call returns a task-scoped request ID without opening a window or changing the
connection. The agent passes `computer_use_check_id` to the existing `sentient_recovery.ask_user`.
Sentient supplies a fixed consent question explaining the test window and brief focus change, with
**Run check** and **Not now**. Only the actual UI answer can approve the request; a model-supplied ID
alone cannot. A second diagnostic call consumes the single-use approval. Decline, dismissal, Stop
or silence never authorize a check, and an answered request cannot be offered again in that task.
The two-phase flow preserves the normal question-wait lifetime without holding a native tool open.
Manual **Test & repair** in Health remains an explicit user action and does not need this evidence gate.

Only after approval, the tool replaces its own model-free
connection and uses the current broker, serialized with actions; it never force-restarts the
active helper or restarts the agent. Normal client teardown can close an idle helper, which the
diagnostic starts again through the same private runtime. A dead transport can also reopen on a
fresh read using the usual recovery path. The result returns to the same model/task;
closing the check window cancels that check, not the parent task. Ordinary focus changes, partial
typing, stale targets and Space switches are handled with fresh state and informed retries first.
Each potentially applied action is verified before a retry, including partial text and uncertain
sends. The agent may use available accessibility state. No new agent-termination policy exists.

`ComputerUseCheckReport` is separate from the full diagnostic export. It has fixed, content-free
fields only: versions, binary UUID, permission observations, test outcomes and native error codes,
plus up to 16 recent computer-use technical events filtered through a second closed allowlist.
No model error excerpts, prompts, screenshots, account identifiers or paths enter its schema.
Health displays the timestamp of a previous successful check only for the same binary UUID.
The report can be previewed and saved locally. **Send report** explicitly uploads that exact
snapshot through `ComputerUseReportUpload`, using an independent anonymous support identity and
no background queue. Its Supabase migration is `20261019010000_computer_use_support_reports.sql`;
it was deployed to the app-data project on 18 October 2026 after explicit user authorization.
Live authenticated submission, duplicate receipts, private-field rejection and denied reads were
verified; the synthetic report and anonymous test identity were removed. Authenticated
clients cannot read/update/delete the report table. The RPC validates the schema, limits size and
daily writes, and deduplicates immutable report IDs. An unavailable upload leaves local save usable.

Validation: `test_computer_use_diagnostics.py` covers the real probe, interruption and ambiguity
handling, underlying error evidence, report privacy and HTTP receipts/reauthorization with inert
controls and HTTP. `test_computer_use_report_database.py` exercises the real SQL in a disposable,
rolled-back schema, never applies a production migration. `test_native_helper_startup.py` covers
diagnostic/task ownership and cancellation. `test_computer_use_consent.py` exercises the production
broker's evidence gate, permission checks, no-side-effect refusal and single-use consent with inert
transport. `test_sidekick_tools.py` checks real question routing, fixed wording, actual answers and
cancellation. Signed lab mode `doctor` exercises the real window and native helper; `doctor-chatgpt`
and `doctor-claude` now verify that a healthy run's diagnostic request is suppressed without opening
a window. No user-app actions or report uploads. The optional voice first-use offer is separate.
