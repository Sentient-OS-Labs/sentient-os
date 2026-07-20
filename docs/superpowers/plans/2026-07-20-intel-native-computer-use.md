# Intel Native Computer Use Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native x86_64 Computer Use backend that lets Sentient OS list apps, inspect accessible UI, capture the screen, click, type, press keys, and scroll on Intel Macs while preserving Sky unchanged on Apple Silicon.

**Architecture:** A standalone Swift package builds a testable core library plus two x86_64 executables: an NDJSON native automation service and a thin MCP stdio adapter. The Xcode app bundles these artifacts, installs an Intel-specific local plugin on x86_64, and retains the existing DMG/Sky setup on arm64.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, ApplicationServices/AXUIElement, CoreGraphics/CGEvent, ScreenCaptureKit, XCTest, MCP JSON-RPC over stdio, Xcode 16.

## Global Constraints

- The MVP supports `list_apps`, `get_app_state`, `click`, `type_text`, `press_key`, and `scroll` only.
- The service and MCP adapter must build as `x86_64` and run on macOS 15.0 or newer.
- Intel setup must never download or execute the arm64 Sky helper.
- Apple Silicon must keep the current Sky setup and behavior unchanged.
- The native backend must not bypass macOS TCC or write directly to a TCC database.
- Screen pixels, accessibility trees, and typed text must not be persisted by the backend.
- Existing tool names and useful argument shapes must match Sky's current interface.

---

## File Structure

- `NativeComputerUse/Package.swift` — SwiftPM products, macOS floor, and test targets.
- `NativeComputerUse/Sources/SentientComputerUseCore/Protocol.swift` — NDJSON request/result/error types.
- `NativeComputerUse/Sources/SentientComputerUseCore/ApplicationCatalog.swift` — GUI app enumeration and resolution.
- `NativeComputerUse/Sources/SentientComputerUseCore/AccessibilityInspector.swift` — bounded AX snapshots and element-index lifetime.
- `NativeComputerUse/Sources/SentientComputerUseCore/InputController.swift` — semantic clicks and CGEvent input.
- `NativeComputerUse/Sources/SentientComputerUseCore/ScreenCapturer.swift` — ScreenCaptureKit capture abstraction.
- `NativeComputerUse/Sources/SentientComputerUseCore/ServiceDispatcher.swift` — validated operation dispatch.
- `NativeComputerUse/Sources/SentientComputerUseService/main.swift` — NDJSON stdin/stdout loop.
- `NativeComputerUse/Sources/SentientComputerUseMCP/MCPServer.swift` — MCP initialize/tools/list/tools/call implementation.
- `NativeComputerUse/Sources/SentientComputerUseMCP/main.swift` — MCP process entry point and service-child transport.
- `NativeComputerUse/Plugin/.codex-plugin/plugin.json` — bundled Intel plugin metadata.
- `NativeComputerUse/Plugin/.mcp.json` — launches the installed MCP adapter.
- `NativeComputerUse/Plugin/skills/computer-use/SKILL.md` — runtime/tool instructions and existing confirmation policy.
- `NativeComputerUse/Tests/SentientComputerUseCoreTests/*Tests.swift` — deterministic unit tests.
- `NativeComputerUse/Tests/SentientComputerUseMCPTests/MCPServerTests.swift` — protocol-level MCP tests.
- `Sentient OS macOS/Cloud/ComputerUseBackend.swift` — architecture selection and Intel bundle/install paths.
- `Sentient OS macOS/Cloud/ComputerUseSetup.swift` — routes Intel setup locally and arm64 setup to Sky.
- `Sentient OS macOS/System/Permissions.swift` — backend-aware permission identity/status.
- `Sentient OS macOS/Views/Permissions/ComputerUseGate.swift` — backend-aware required grants.
- `Sentient OS macOS/Views/Permissions/ComputerUseGateView.swift` — Intel permission copy/actions.
- `Sentient OS macOS.xcodeproj/project.pbxproj` — prebuild/package and copy-resources integration.

---

### Task 1: Create the Swift package and wire protocol types

**Files:**
- Create: `NativeComputerUse/Package.swift`
- Create: `NativeComputerUse/Sources/SentientComputerUseCore/Protocol.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `ServiceRequest`, `ServiceResponse`, `ServiceOperation`, `ServiceError`, and `ServiceErrorCode` as `Codable`, `Sendable`, `Equatable` types.
- Consumes: newline-delimited UTF-8 JSON; one complete request or response per line.

- [ ] **Step 1: Write the failing protocol round-trip tests**

```swift
import XCTest
@testable import SentientComputerUseCore

final class ProtocolTests: XCTestCase {
    func testRequestRoundTripsWithoutLosingIdentifierOrArguments() throws {
        let request = ServiceRequest(id: "r1", operation: .click,
            arguments: ["app": .string("TextEdit"), "element_index": .int(7)])
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ServiceRequest.self, from: data), request)
    }

    func testErrorResponseCarriesStableCode() throws {
        let response = ServiceResponse.failure(id: "r2",
            ServiceError(code: .permissionDeniedAccessibility, message: "Accessibility is required"))
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ServiceResponse.self, from: data), response)
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `swift test --package-path NativeComputerUse --filter ProtocolTests`

Expected: FAIL because `SentientComputerUseCore` and its protocol types do not exist.

- [ ] **Step 3: Add the package manifest and minimal protocol implementation**

Define `JSONValue` with `.string`, `.int`, `.double`, `.bool`, `.array`, `.object`, and `.null`; define the six operation cases exactly as `list_apps`, `get_app_state`, `click`, `type_text`, `press_key`, and `scroll`. Encode `ServiceResponse` with either `result` or `error`, never both. Use these exact error raw values: `permission_denied_accessibility`, `permission_denied_screen_recording`, `application_not_found`, `element_not_found`, `stale_snapshot`, `unsupported_action`, `invalid_request`, `capture_failed`, and `internal_error`.

- [ ] **Step 4: Run the tests and verify GREEN**

Run: `swift test --package-path NativeComputerUse --filter ProtocolTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse
git commit -m "feat: define native computer use protocol"
```

---

### Task 2: Implement application enumeration and bounded accessibility snapshots

**Files:**
- Create: `NativeComputerUse/Sources/SentientComputerUseCore/ApplicationCatalog.swift`
- Create: `NativeComputerUse/Sources/SentientComputerUseCore/AccessibilityInspector.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/ApplicationCatalogTests.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/AccessibilityInspectorTests.swift`

**Interfaces:**
- Produces: `ApplicationDescriptor { name, bundleIdentifier, path, processIdentifier }`.
- Produces: `AccessibilitySnapshot { token, app, text, elements }` and `SnapshotElement { index, role, title, value, frame, actions }`.
- Produces: `AccessibilityInspecting.snapshot(app:maxDepth:maxElements:)` and `element(snapshotToken:index:)`.
- Consumes: injectable `WorkspaceProviding` and `AXProviding` protocols; production adapters call `NSWorkspace` and `AXUIElement`.

- [ ] **Step 1: Write failing tests for resolution order and snapshot bounds**

Test that exact bundle identifier wins over a display-name match, that a missing app returns `.applicationNotFound`, that traversal stops at `maxElements`, and that an index from an older snapshot returns `.staleSnapshot` after a new snapshot for the same app.

```swift
func testSnapshotIsBoundedAndIndexesAreSnapshotLocal() throws {
    let ax = FakeAXProvider(tree: .chain(length: 20))
    let inspector = AccessibilityInspector(provider: ax)
    let first = try inspector.snapshot(app: .fixture, maxDepth: 8, maxElements: 5)
    XCTAssertEqual(first.elements.count, 5)
    let second = try inspector.snapshot(app: .fixture, maxDepth: 8, maxElements: 5)
    XCTAssertThrowsError(try inspector.element(snapshotToken: first.token, index: 0)) {
        XCTAssertEqual($0 as? ServiceError, ServiceError(code: .staleSnapshot, message: "Snapshot expired"))
    }
    XCTAssertNoThrow(try inspector.element(snapshotToken: second.token, index: 0))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path NativeComputerUse --filter ApplicationCatalogTests && swift test --package-path NativeComputerUse --filter AccessibilityInspectorTests`

Expected: FAIL because the catalog and inspector are absent.

- [ ] **Step 3: Implement catalog resolution and breadth-first AX traversal**

Resolve in this order: bundle identifier, canonical executable path, case-insensitive exact display name, then unique case-insensitive prefix. Ignore background-only processes. Traverse breadth-first, cap default depth at 12 and default elements at 500, skip repeated AX references, normalize whitespace, and omit empty attributes. Keep raw `AXUIElement` references in a private per-app snapshot cache with a capacity of one.

- [ ] **Step 4: Run focused and full package tests**

Run: `swift test --package-path NativeComputerUse`

Expected: PASS with no test warnings.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse
git commit -m "feat: inspect accessible macOS applications"
```

---

### Task 3: Implement validated clicks, typing, key presses, and scrolling

**Files:**
- Create: `NativeComputerUse/Sources/SentientComputerUseCore/InputController.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/InputControllerTests.swift`

**Interfaces:**
- Produces: `InputControlling.click(element:coordinate:button:count:)`, `typeText(_:)`, `pressKey(_:)`, and `scroll(direction:pages:anchor:)`.
- Consumes: `EventPosting` and `AccessibilityActionPerforming` protocols so tests never move the real cursor.

- [ ] **Step 1: Write failing behavior tests**

Cover semantic `AXPress` before coordinate fallback, rejection of a click with neither element nor coordinate, left/right/middle button mapping, click counts 1...3, Unicode typing, `super+c` parsing, named keys (`Return`, `Tab`, `Escape`, arrows), and scroll direction/page scaling.

```swift
func testSemanticPressWinsOverCoordinateFallback() throws {
    let events = RecordingEventPoster()
    let actions = RecordingAXActionPerformer(supported: [kAXPressAction])
    let controller = InputController(events: events, actions: actions)
    try controller.click(element: .fixture, coordinate: CGPoint(x: 20, y: 30), button: .left, count: 1)
    XCTAssertEqual(actions.performed, [kAXPressAction])
    XCTAssertTrue(events.events.isEmpty)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --package-path NativeComputerUse --filter InputControllerTests`

Expected: FAIL because `InputController` does not exist.

- [ ] **Step 3: Implement the minimal controller**

Validate finite on-screen coordinates, button/count ranges, page range 1...10, and known key syntax. Use `CGEvent` with `.cgAnnotatedSessionEventTap`; post modifier down events, key down/up, then modifier up in reverse order. Use `CGEventKeyboardSetUnicodeString` for text. Return `.unsupportedAction` for unknown keys instead of guessing.

- [ ] **Step 4: Run the full package suite and verify GREEN**

Run: `swift test --package-path NativeComputerUse`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse
git commit -m "feat: add native macOS input control"
```

---

### Task 4: Implement screen capture and service dispatch

**Files:**
- Create: `NativeComputerUse/Sources/SentientComputerUseCore/ScreenCapturer.swift`
- Create: `NativeComputerUse/Sources/SentientComputerUseCore/ServiceDispatcher.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/ScreenCapturerTests.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/ServiceDispatcherTests.swift`

**Interfaces:**
- Produces: `ScreenCapturing.captureMainDisplay() async throws -> CaptureResult`.
- Produces: `ServiceDispatcher.handle(_:) async -> ServiceResponse`.
- Consumes: catalog, inspector, input controller, permission checker, and screen capturer protocols.

- [ ] **Step 1: Write failing permission and dispatch tests**

Verify `get_app_state` fails with `permission_denied_accessibility` before touching AX, capture failure maps to `capture_failed`, every public operation dispatches to exactly one dependency, unknown/malformed arguments map to `invalid_request`, and response identifiers always match requests.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --package-path NativeComputerUse --filter ScreenCapturerTests && swift test --package-path NativeComputerUse --filter ServiceDispatcherTests`

Expected: FAIL because capture and dispatch are absent.

- [ ] **Step 3: Implement capture and dispatch**

Use `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` and `SCScreenshotManager.captureImage` for the main display. Encode the image once as PNG under `FileManager.default.temporaryDirectory/SentientComputerUse/<UUID>.png`. The dispatcher validates arguments before checking permissions, checks Accessibility for inspection/input and Screen Recording for capture, and never includes typed text in errors or logs.

- [ ] **Step 4: Run all tests and verify GREEN**

Run: `swift test --package-path NativeComputerUse`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse
git commit -m "feat: dispatch native computer use operations"
```

---

### Task 5: Build the NDJSON service process

**Files:**
- Create: `NativeComputerUse/Sources/SentientComputerUseService/main.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseCoreTests/ServiceLoopTests.swift`

**Interfaces:**
- Produces: `ServiceLoop.run(input:output:dispatcher:) async`.
- Consumes: one JSON request per input line; emits one compact JSON response per line and flushes immediately.

- [ ] **Step 1: Write a failing multi-line recovery test**

Feed valid request, malformed JSON, and another valid request. Assert three responses are emitted, the middle response uses `invalid_request`, and processing continues after the malformed line.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --package-path NativeComputerUse --filter ServiceLoopTests`

Expected: FAIL because `ServiceLoop` is absent.

- [ ] **Step 3: Implement the service loop and production dependency assembly**

Read with `FileHandle.read(upToCount:)`, buffer partial lines, impose a 1 MiB line limit, decode on a serial actor, encode compact JSON, append `\n`, and call `synchronizeFile()`. Handle EOF cleanly and SIGTERM through normal process termination.

- [ ] **Step 4: Run tests and build x86_64**

Run: `swift test --package-path NativeComputerUse && swift build --package-path NativeComputerUse -c release --arch x86_64 --product SentientComputerUseService && file NativeComputerUse/.build/x86_64-apple-macosx/release/SentientComputerUseService`

Expected: tests PASS; `file` reports `Mach-O 64-bit executable x86_64`.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse
git commit -m "feat: add Intel computer use service process"
```

---

### Task 6: Implement the MCP adapter and Intel plugin

**Files:**
- Create: `NativeComputerUse/Sources/SentientComputerUseMCP/MCPServer.swift`
- Create: `NativeComputerUse/Sources/SentientComputerUseMCP/main.swift`
- Create: `NativeComputerUse/Tests/SentientComputerUseMCPTests/MCPServerTests.swift`
- Create: `NativeComputerUse/Plugin/.codex-plugin/plugin.json`
- Create: `NativeComputerUse/Plugin/.mcp.json`
- Create: `NativeComputerUse/Plugin/skills/computer-use/SKILL.md`

**Interfaces:**
- Produces: MCP methods `initialize`, `notifications/initialized`, `tools/list`, and `tools/call` over stdio.
- Produces: the six Sky-compatible tool definitions from the approved spec.
- Consumes: `ServiceTransport.call(operation:arguments:) async throws -> JSONValue`.

- [ ] **Step 1: Write failing MCP transcript tests**

Test initialization capability negotiation, exact six-tool listing, argument forwarding, structured service-error preservation, unknown method JSON-RPC error `-32601`, invalid params `-32602`, and notification requests producing no response.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --package-path NativeComputerUse --filter MCPServerTests`

Expected: FAIL because the MCP target is absent.

- [ ] **Step 3: Implement the adapter and plugin metadata**

The adapter launches `SentientComputerUseService` from its own directory, keeps one child for its lifetime, serializes requests, and fails pending calls with `internal_error` if the child exits. `.mcp.json` launches `./bin/SentientComputerUseMCP`. The skill documents only the six available tools and app-level confirmation policy; it must not mention unavailable drag, selection, or secondary-action tools.

- [ ] **Step 4: Run tests and verify both binary architectures**

Run: `swift test --package-path NativeComputerUse && swift build --package-path NativeComputerUse -c release --arch x86_64 --product SentientComputerUseMCP && file NativeComputerUse/.build/x86_64-apple-macosx/release/SentientComputerUseMCP`

Expected: tests PASS; `file` reports x86_64.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse
git commit -m "feat: expose Intel computer use over MCP"
```

---

### Task 7: Bundle artifacts and route setup by architecture

**Files:**
- Create: `Sentient OS macOS/Cloud/ComputerUseBackend.swift`
- Modify: `Sentient OS macOS/Cloud/ComputerUseSetup.swift`
- Modify: `Sentient OS macOS/Cloud/CodexSetup.swift`
- Modify: `Sentient OS macOS.xcodeproj/project.pbxproj`
- Create: `Scripts/build-intel-computer-use.sh`

**Interfaces:**
- Produces: `ComputerUseBackend.current`, `.sky`, `.sentientIntel`, `isInstalled`, and `install(force:onLine:)`.
- Consumes: bundled resource directory `Contents/Resources/IntelComputerUse` containing `bin/` and plugin metadata.

- [ ] **Step 1: Add a failing architecture/setup verification script**

Create `Scripts/verify-intel-computer-use.sh` that exits nonzero unless both bundled executables are x86_64, `.mcp.json` references `SentientComputerUseMCP`, and no installed Intel plugin path references `SkyComputerUseService`. Run it before integration and confirm it fails because the bundle does not exist.

- [ ] **Step 2: Implement compile-time backend selection**

Use `#if arch(x86_64)` to return `.sentientIntel`, otherwise `.sky`. Extract the existing setup body into a private `installSky` path. Intel installation copies only the signed bundled `IntelComputerUse` tree into `~/.codex/plugins/cache/sentient/computer-use/1.0.0`, patches an idempotent `[plugins."computer-use@sentient"] enabled = true` block, disables the OpenAI computer-use plugin block if present, and validates both executable architectures before reporting ready.

- [ ] **Step 3: Add the build/copy phase**

`Scripts/build-intel-computer-use.sh` runs two release x86_64 SwiftPM builds, stages both binaries plus `Plugin/` into `${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/IntelComputerUse`, and signs the staged executables with `${EXPANDED_CODE_SIGN_IDENTITY:--}`. Add this phase before Xcode's final app signing. Skip the phase for non-x86_64 app builds unless `BUILD_INTEL_COMPUTER_USE=YES` is explicitly set for CI verification.

- [ ] **Step 4: Build and run verification**

Run: `xcodebuild -project 'Sentient OS macOS.xcodeproj' -scheme 'Sentient OS macOS' -configuration Debug -derivedDataPath work/intel-cu-derived ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build && Scripts/verify-intel-computer-use.sh 'work/intel-cu-derived/Build/Products/Debug/Sentient OS.app'`

Expected: BUILD SUCCEEDED and verification exits 0.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse Scripts 'Sentient OS macOS' 'Sentient OS macOS.xcodeproj/project.pbxproj'
git commit -m "feat: install native computer use on Intel"
```

---

### Task 8: Make permissions and health UI backend-aware

**Files:**
- Modify: `Sentient OS macOS/System/Permissions.swift`
- Modify: `Sentient OS macOS/Views/Permissions/ComputerUseGate.swift`
- Modify: `Sentient OS macOS/Views/Permissions/ComputerUseGateView.swift`
- Modify: `Sentient OS macOS/Views/Settings/HealthPane.swift`
- Modify: `Sentient OS macOS/System/HealthCaution.swift`

**Interfaces:**
- Produces: `Permissions.computerUsePermissionOwnerBundleID`, `computerUsePermissionOwnerName`, `hasComputerUseAccessibility`, and `hasComputerUseScreenRecording`.
- Consumes: `ComputerUseBackend.current`.

- [ ] **Step 1: Establish expected Intel behavior with source assertions**

Extend `Scripts/verify-intel-computer-use.sh` to assert the Intel build does not call `grantComputerUseAutomation`, does not gate on `com.openai.sky.CUAService`, and contains user-facing copy naming `Sentient OS` for Accessibility and Screen Recording. Run it and confirm failure before editing the UI.

- [ ] **Step 2: Implement backend-aware permission ownership**

For `.sentientIntel`, query the main Sentient bundle identifier because the bundled service is launched as Sentient's child and input/capture permission is attributed to Sentient. Do not create or self-heal an Apple Events grant. For `.sky`, preserve all current helper bundle ID and Automation behavior. Update gate rows and Health copy to name the active owner and explain that Screen Recording takes effect after relaunch.

- [ ] **Step 3: Build and verify both architecture branches**

Run Intel command from Task 7, then run: `xcodebuild -project 'Sentient OS macOS.xcodeproj' -scheme 'Sentient OS macOS' -configuration Debug -derivedDataPath work/arm-cu-derived ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`

Expected: both builds succeed; Intel verification exits 0; the arm64 app still contains the existing Sky setup code path.

- [ ] **Step 4: Commit**

```bash
git add Scripts 'Sentient OS macOS'
git commit -m "feat: adapt computer use permissions by backend"
```

---

### Task 9: End-to-end verification and documentation

**Files:**
- Modify: `Sentient OS macOS/Documentation/Computer-Use Bootstrap (Codex Reverse-Engineering).md`
- Modify: `Sentient OS macOS/Documentation/Permission Guide (First-Use Grants).md`
- Create: `NativeComputerUse/README.md`

**Interfaces:**
- Consumes: completed package, bundled plugin, architecture router, and permission UI.
- Produces: reproducible developer and hardware acceptance instructions.

- [ ] **Step 1: Run the complete automated suite**

Run:

```bash
swift test --package-path NativeComputerUse
xcodebuild -project 'Sentient OS macOS.xcodeproj' -scheme 'Sentient OS macOS' -configuration Debug -derivedDataPath work/intel-cu-derived ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
Scripts/verify-intel-computer-use.sh 'work/intel-cu-derived/Build/Products/Debug/Sentient OS.app'
git diff --check
```

Expected: all tests pass, build succeeds, verifier exits 0, and `git diff --check` is silent.

- [ ] **Step 2: Install a signed local Intel build and grant normal macOS permissions**

Use the existing Intel release/signing workflow. In System Settings, the user grants Accessibility and Screen Recording to Sentient OS when macOS requests them. Do not edit TCC databases or automate the permission toggles.

- [ ] **Step 3: Run the hardware acceptance sequence twice**

From Sentient, run a harmless task against a scratch TextEdit document that lists apps, reads TextEdit state, clicks in the scratch document, types `SENTIENT_INTEL_OK`, presses `super+a`, and scrolls. Repeat in a second fresh `codex exec` session. Expected: both runs finish without `Bad CPU type`, `failed to start`, cache deserialization, or stale-snapshot errors.

- [ ] **Step 4: Update documentation with measured results**

Document the architecture decision, installed paths, permission owner, exact automated commands, Intel hardware/macOS version, and observed acceptance results. Clearly mark deferred Sky-parity features.

- [ ] **Step 5: Commit**

```bash
git add NativeComputerUse 'Sentient OS macOS/Documentation'
git commit -m "docs: document Intel computer use backend"
```

---

## Final Verification Gate

Before claiming completion:

1. `swift test --package-path NativeComputerUse` passes from a clean package build.
2. The x86_64 Xcode build succeeds and contains two x86_64 native executables.
3. The arm64 Xcode build succeeds without changing Sky behavior.
4. `Scripts/verify-intel-computer-use.sh` exits 0.
5. Two consecutive real Intel Computer Use sessions complete the harmless TextEdit acceptance flow.
6. No permission was granted by editing TCC, and no screenshot or typed text remains in backend storage.
