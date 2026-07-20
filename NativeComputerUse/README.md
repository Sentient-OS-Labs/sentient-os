# Native Computer Use (Intel macOS)

This package is Sentient OS's native x86_64 Computer Use backend. It replaces the incompatible
arm64-only Sky helper on Intel Macs while leaving the Apple Silicon Sky path unchanged.

## Architecture

`SentientComputerUseMCP` is a thin MCP stdio adapter. It starts the sibling
`SentientComputerUseService`, translates six MCP tools into newline-delimited JSON requests, and
preserves structured service errors. The service owns app discovery, bounded Accessibility snapshots,
ScreenCaptureKit capture, clicks, Unicode typing, keyboard shortcuts, and scrolling.

The supported tools are `list_apps`, `get_app_state`, `click`, `type_text`, `press_key`, and `scroll`.
Snapshots are local to the latest `get_app_state` call; stale indexes fail with `stale_snapshot`.
The service makes no network requests and does not persist Accessibility trees or typed text. Captures
are written under the process temporary directory's `SentientComputerUse/` folder and removed when the
service loop exits; a new capture also deletes the prior tracked capture.

## Build and automated verification

If `xcode-select` already points at Xcode, omit the `DEVELOPER_DIR` prefix. Otherwise use the installed
Xcode without changing the machine-wide selection:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift package --package-path NativeComputerUse clean
swift test --package-path NativeComputerUse

xcodebuild -project 'Sentient OS macOS.xcodeproj' \
  -scheme 'Sentient OS macOS' -configuration Debug \
  -derivedDataPath work/intel-cu-derived \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

Scripts/verify-intel-computer-use.sh \
  'work/intel-cu-derived/Build/Products/Debug/Sentient OS.app'

xcodebuild -project 'Sentient OS macOS.xcodeproj' \
  -scheme 'Sentient OS macOS' -configuration Debug \
  -derivedDataPath work/arm-cu-derived \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

Scripts/test-computer-use-config.sh
Scripts/test-intel-computer-use-scripts.sh
git diff --check
```

The Intel Xcode build runs `Scripts/build-intel-computer-use.sh`. It builds both SwiftPM executables in
Release as x86_64, stages them with `Plugin/` at `Contents/Resources/IntelComputerUse`, and signs each
staged executable with Xcode's expanded identity or ad hoc (`-`) when there is none. The arm64 phase
removes any stale Intel bundle instead.

For a local ad hoc-signed app when no Apple signing identity is installed:

```bash
xcodebuild -project 'Sentient OS macOS.xcodeproj' \
  -scheme 'Sentient OS macOS' -configuration Debug \
  -derivedDataPath work/intel-cu-signed-derived \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

codesign --verify --deep --strict \
  'work/intel-cu-signed-derived/Build/Products/Debug/Sentient OS.app'
```

An ad hoc build is only for local testing. Distribution still requires the normal Apple signing,
archive, notarization, and DMG workflow.

## Installation and selection

At compile time, `ComputerUseBackend.current` selects `.sentientIntel` for x86_64 and `.sky` for
arm64. On Intel, `ComputerUseSetup` validates and copies the signed bundle to:

```text
~/.codex/plugins/cache/sentient/computer-use/1.0.0/
├── .codex-plugin/plugin.json
├── .mcp.json
├── bin/SentientComputerUseMCP
├── bin/SentientComputerUseService
└── skills/computer-use/SKILL.md
```

It then enables this canonical table in `~/.codex/config.toml`:

```toml
[plugins."computer-use@sentient"]
enabled = true
```

If the OpenAI computer-use table already exists, Intel setup sets it to `enabled = false`. It refuses
ambiguous duplicate or dotted plugin keys rather than guessing. Intel setup never downloads, copies, or
launches Sky. Apple Silicon continues to install `computer-use@openai-bundled` from OpenAI's DMG.

## Permissions

On Intel, the responsible permission owner is **Sentient OS** (`jesai.Sentient-OS-macOS`):

- Accessibility is required to inspect controls and generate input.
- Screen Recording is required by `get_app_state` to capture the display.

Use Sentient's first-use gate or Settings → Health and grant both in System Settings. Do not edit TCC.
After enabling Screen Recording, relaunch the same signed Sentient build; the current process uses
`CGPreflightScreenCaptureAccess()` so a database row that is not effective yet remains blocked.

Changing the app path or ad hoc signature can make macOS treat a local build as a different permission
subject. Grant the exact build being accepted. On Apple Silicon the permission owner remains the
separately signed Codex Computer Use helper, and the Sky Automation lifecycle remains unchanged.

## Intel hardware acceptance

Use a scratch TextEdit document with no sensitive content. Keep the user present because this sequence
moves the pointer and generates input.

1. Build/sign the exact Intel app to accept, install it without overwriting a running copy, and launch it.
2. Through Sentient's normal gate, grant Accessibility and Screen Recording to Sentient OS in System
   Settings. Relaunch Sentient when instructed. Never script the toggles or modify TCC.
3. In Sentient, run: `Use computer use on a scratch TextEdit document: list apps, read TextEdit state,
   click inside the scratch document, type SENTIENT_INTEL_OK, press super+a, and scroll once.`
4. Confirm the run finishes without `Bad CPU type`, `failed to start`, cache deserialization, or
   `stale_snapshot` errors.
5. Start a second fresh `codex exec` session from Sentient and repeat the same flow.
6. Close the sessions and verify no service remains and no capture remains:

```bash
ps -axo pid=,comm= | awk '$2 ~ /\/SentientComputerUseService$/ { print }'
find "${TMPDIR:-/tmp}/SentientComputerUse" -type f -name '*.png' -print 2>/dev/null
```

Both commands must print no matching process/file. Delete the scratch TextEdit document if it was saved.

## Measured status (2026-07-20)

On a MacBookPro16,1 with an 8-core Intel Core i9 and 32 GB RAM, running macOS 26.5.2 (25F84) and
Xcode 26.5 (17F42):

- clean SwiftPM build: 74 tests, 0 failures;
- fresh x86_64 Debug app build: success; both bundled executables are x86_64;
- fresh arm64 Debug app build: success; Intel resources absent and Sky routing retained;
- Intel verifier and both script fixture suites: exit 0;
- local ad hoc-signed Intel app: deep/strict signature verification passed;
- two fresh direct MCP smoke processes: initialization succeeded, six tools were listed, `list_apps`
  returned 65 entries, and TextEdit state stopped at `permission_denied_screen_recording`;
- backend residue after smoke tests: 0 capture PNGs and 0 live service processes.

The Keychain had 0 valid code-signing identities, so no Apple Development/Developer ID build was made.
The signed local build is at `work/intel-cu-signed-derived/Build/Products/Debug/Sentient OS.app` and was
not installed or launched. The two full TextEdit interaction sessions remain **pending** until the user
grants Screen Recording to that exact build and relaunches it.

## Deferred Sky parity

The MVP intentionally defers drag-and-drop, secondary Accessibility actions, advanced text selection,
and full multi-display parity. Additions should extend the typed protocol without changing the six
existing request shapes.
