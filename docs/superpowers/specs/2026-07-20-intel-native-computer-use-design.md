# Intel Native Computer Use Design

## Goal

Give Sentient OS a working Computer Use backend on Intel Macs without relying on OpenAI's arm64-only `SkyComputerUseService`. Preserve the existing Sky path on Apple Silicon.

## Scope

The first release is an MVP that supports the actions needed by most browser and native-app workflows:

- list running GUI applications;
- inspect one application's accessible interface hierarchy;
- capture the current display state;
- click an accessible element or explicit screen coordinate;
- type text into the focused control;
- press keys and keyboard shortcuts;
- scroll vertically or horizontally;
- report missing permissions, unavailable applications, stale elements, and invalid requests clearly.

Drag-and-drop, secondary accessibility actions, advanced text selection, and full multi-display parity with Sky are deferred. The protocol must remain extensible so those operations can be added without changing existing requests.

## Architecture

### Backend selection

Sentient OS chooses a backend by process architecture:

- `x86_64`: install and enable `SentientComputerUseService`;
- `arm64`: keep the existing OpenAI Sky setup and plugin unchanged.

The selection is deterministic and testable. An Intel installation must never download or launch the arm64 Sky helper. Existing Apple Silicon behavior must not regress.

### Native service

`SentientComputerUseService` is a small macOS command-line executable built as `x86_64`. It communicates through newline-delimited JSON over standard input and output. Each request contains an identifier, an operation, and typed arguments. Each response echoes the identifier and returns either a typed result or a structured error.

The service owns four focused components:

1. `ApplicationCatalog` enumerates running GUI applications and resolves an application name, bundle identifier, or path to a process identifier.
2. `AccessibilityInspector` uses `AXUIElement` to build a bounded, stable snapshot of accessible controls. It assigns snapshot-local element indexes and keeps the underlying accessibility references only for the lifetime of that snapshot.
3. `InputController` uses `AXUIElementPerformAction` when an element exposes a semantic action, falling back to `CGEvent` for coordinate clicks, typing, key presses, and scrolling.
4. `ScreenCapturer` uses ScreenCaptureKit where available and returns a temporary PNG path plus display metadata. Existing Sentient screenshots attached to `codex exec` remain supported.

The service does not persist screen contents, accessibility trees, or typed text. Temporary captures are deleted by the existing run cleanup path.

### Codex integration

The Intel computer-use plugin exposes these tool names and argument shapes:

- `list_apps()`
- `get_app_state(app, disableDiff?)`
- `click(app, element_index?, x?, y?, mouse_button?, click_count?)`
- `type_text(app, text)`
- `press_key(app, key)`
- `scroll(app, element_index?, direction, pages?)`

The names intentionally match the useful subset of Sky's current interface so existing prompts and model behavior transfer cleanly. A thin local MCP adapter translates tool calls to the service's JSON protocol. The adapter contains no UI automation logic.

On Intel, `ComputerUseSetup` installs the native plugin configuration from the Sentient bundle and reports the backend as ready only when the x86_64 executable, plugin manifest, and configuration are all valid. On Apple Silicon, the current DMG-derived Sky installation continues unchanged.

## Data Flow

1. The user submits a Computer Use command in Sentient OS.
2. Sentient launches `codex exec` with the existing prompt and screenshot context.
3. Codex loads the architecture-selected computer-use plugin.
4. The MCP adapter sends one JSON request to `SentientComputerUseService` for each tool call.
5. The service validates permissions and arguments, performs the native macOS operation, and returns a structured response.
6. Codex observes the result and decides the next tool call until the task finishes or fails.

Only the user's existing Codex/OpenAI session receives screenshots and accessibility text, matching Sentient's current trust boundary. The local service does not contact a network endpoint.

## Permissions and Safety

Sentient OS itself becomes the responsible executable for the Intel backend's macOS permissions:

- Accessibility is required for reading controls and generating input.
- Screen Recording is required for screenshots.

The existing permission UI is adapted to name Sentient's Intel backend instead of `Codex Computer Use` when running on Intel. No code writes directly to the TCC database or bypasses a macOS prompt.

The existing Computer Use confirmation policy remains in force. The backend performs only operations explicitly requested through its local tool protocol and does not add shell execution, filesystem access, or network access.

## Error Handling

Every failure returns a stable code and human-readable message. Initial codes are:

- `permission_denied_accessibility`
- `permission_denied_screen_recording`
- `application_not_found`
- `element_not_found`
- `stale_snapshot`
- `unsupported_action`
- `invalid_request`
- `capture_failed`
- `internal_error`

The MCP adapter preserves these codes in tool results. Sentient's health UI distinguishes an unsupported arm64 helper from missing permissions and a service launch failure. Intel users are never told to enable permissions for an executable their Mac cannot run.

## Testing

Development follows test-driven development.

Unit tests cover JSON request decoding, response encoding, backend selection, application resolution, bounded accessibility-tree formatting, element-index lifetime, key parsing, coordinate validation, scroll mapping, and error mapping. macOS framework calls sit behind narrow protocols so deterministic fakes can test behavior without moving the real mouse.

Integration tests launch the built x86_64 service, exchange JSON requests, verify malformed-input recovery, and inspect the binary architecture. A manual hardware acceptance test on the Intel Mac must prove two consecutive Codex runs can list apps, inspect a test window, click a harmless control, type into a scratch text field, and scroll. Existing Apple Silicon setup tests must continue to pass.

## Rollout

The Intel backend is enabled automatically only on `x86_64`. If its executable or plugin wiring fails validation, Sentient reports Computer Use as unavailable and leaves other features operational. There is no silent fallback to the incompatible Sky binary.

The initial release does not remove any Sky code. This keeps the change reversible and isolates Intel-specific risk.

## Success Criteria

- Sentient OS never launches an arm64 helper on an Intel Mac.
- Two consecutive real `codex exec` Computer Use sessions start without a cache or service-startup error.
- Codex can list apps, read accessible state, click, type, press keys, and scroll on the Intel Mac.
- Missing permissions produce actionable messages rather than a generic startup failure.
- Apple Silicon continues to use the existing Sky backend unchanged.
