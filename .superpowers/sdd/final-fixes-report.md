# Final Fixes Report

Date: 2026-07-20  
Base reviewed: `083aa06`  
Final implementation: `a2ea63c`

## Outcome

All eight findings in `final-review-findings.md` are fixed. No TCC database, permission row, or
macOS security toggle was edited or automated. Physical TextEdit acceptance remains intentionally
pending the user's normal Screen Recording grant and Sentient OS relaunch.

## Finding resolution

1. **Discoverable marketplace** — added a valid bundled
   `NativeComputerUse/Marketplace/.agents/plugins/marketplace.json`, installed a dedicated local
   marketplace snapshot, registered `[marketplaces.sentient]` idempotently without changing unrelated
   marketplaces, and proved `computer-use@sentient 1.0.0` discovery with the real Codex CLI.
2. **App-scoped mutation** — every click, type, key, and scroll resolves the requested app, activates
   its `NSRunningApplication`, verifies its PID is frontmost within a bounded interval, and posts no
   global event on resolution/focus failure.
3. **Bounded lifecycle** — MCP response reads use bounded `poll`/`read` loops with timeouts and a 1 MiB
   ceiling; shutdown interrupts silent calls and escalates through bounded EOF/SIGTERM/SIGKILL; both
   executables ignore SIGPIPE; the service handles SIGINT/SIGTERM through normal loop cleanup and
   sweeps stale capture PNGs on startup.
4. **Strict backend config** — parser states are explicit (`absent`, `enabled`, `disabled`, `invalid`).
   Intel and Sky readiness both require active-enabled/inactive-disabled, and setup migrations enforce
   that state in both directions.
5. **Bounded output** — every AX string is capped by UTF-8 bytes with a visible marker, the complete AX
   snapshot is capped at 512 KiB, and service/MCP response lines are bounded.
6. **Transactional snapshot** — a failed capture no longer commits new accessibility references; the
   prior successful snapshot remains resolvable.
7. **Installed validation** — readiness/verifier parse required plugin and marketplace fields, require
   exact MCP command plus `cwd == "."`, require x86_64-only Mach-O binaries and valid strict signatures,
   and run a bounded initialize/tools-list MCP handshake.
8. **Wire contracts** — `list_apps` describes running GUI apps, `disableDiff` is documented honestly as
   compatibility-only, non-object structured content is wrapped in an object, and
   `unsupported_action` is preserved.

## Commits

- `10c96f5` — `fix: isolate native input to requested app`
- `e097ef8` — `fix: preserve snapshot on capture failure`
- `45fe02d` — `fix: bound accessibility and MCP output`
- `3bf1b3e` — `fix: bound native process lifecycle`
- `8ddacec` — `fix: enforce exclusive computer use backend config`
- `a2ea63c` — `fix: install discoverable Sentient marketplace`

## TDD evidence

Behavior changes were introduced behind failing tests/fixtures. RED logs are retained for this run in:

- `/tmp/sentient-red-app-isolation.log`
- `/tmp/sentient-red-transactional-snapshot.log`
- `/tmp/sentient-red-ax-byte-bounds.log`
- `/tmp/sentient-red-wire-contracts.log`
- `/tmp/sentient-red-service-response-bound.log`
- `/tmp/sentient-red-transport-bounds.log`
- `/tmp/sentient-red-signal-cleanup.log`
- `/tmp/sentient-red-explicit-plugin-state.log`
- `/tmp/sentient-red-marketplace-config.log`
- `/tmp/sentient-red-marketplace-contract.log`
- `/tmp/sentient-red-signature-validation.log`

The RED failures respectively showed missing app resolution/focus isolation, snapshot advancement on
capture failure, missing byte/line bounds and wire behavior, blocking/unbounded child lifecycle,
signal exits plus stale PNG retention, conflated/absent config states, missing marketplace registration
and layout validation, and acceptance of a tampered signature. Matching GREEN logs are stored alongside
them under `/tmp/sentient-green-*.log`.

## Final verification

### SwiftPM from clean state

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift package --package-path NativeComputerUse clean
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path NativeComputerUse
```

Result: `Executed 89 tests, with 0 failures (0 unexpected)`.

### Fresh app artifacts

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Sentient OS macOS.xcodeproj' -scheme 'Sentient OS macOS' \
  -configuration Debug -derivedDataPath work/final-intel-cu-derived \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Sentient OS macOS.xcodeproj' -scheme 'Sentient OS macOS' \
  -configuration Debug -derivedDataPath work/final-arm-cu-derived \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Results: both `** BUILD SUCCEEDED **`; app executables report `x86_64` and `arm64` respectively; the
arm64 artifact contains no `IntelComputerUse` resource.

### Bundle, handshake, and real CLI discovery

```sh
Scripts/verify-intel-computer-use-discovery.sh \
  'work/final-intel-cu-derived/Build/Products/Debug/Sentient OS.app' \
  "$(command -v codex)"
```

Result with `codex-cli 0.145.0-alpha.18`:

```text
Intel computer-use bundle verified: marketplace, signed x86_64 binaries, MCP handshake, no Sky service reference
Real Codex CLI discovered computer-use@sentient 1.0.0 from the local Sentient marketplace
```

The discovery script uses a temporary isolated `CODEX_HOME`, invokes
`codex plugin marketplace list --json` and
`codex plugin list --marketplace sentient --available --json`, and deletes the temporary home.

### Config, corruption, timeout, signal, and cleanup smokes

```sh
Scripts/test-computer-use-config.sh
Scripts/test-intel-computer-use-scripts.sh all
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path NativeComputerUse \
  --filter 'ServiceProcessTransportTests/testSilentChildCallTimesOutAndCanBeReaped|ServiceProcessTransportTests/testShutdownInterruptsSilentCallAndLeavesNoChild|ServiceLoopTests/testServiceSIGINTAndSIGTERMExitThroughNormalCleanup|ScreenCapturerTests/testInitializationSweepsStaleCapturePNGs'
```

Results: config fixtures passed; every corruption fixture was rejected; selected timeout/signal/cleanup
tests passed `4/4`; final process scan found `0` Sentient MCP/service children and the temporary capture
scan found `0` stale PNGs. `git diff --check` passed. Existing untracked `work/` artifacts were preserved.

## Pending physical acceptance

Run the documented scratch TextEdit flow only after granting Screen Recording to the exact signed
Sentient OS build through System Settings and relaunching it. This remains a normal user-controlled macOS
permission step and was not bypassed during automated verification.
