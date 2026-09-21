//
//  CuaDriver.swift
//  Sentient OS macOS  ·  Driver/
//
//  The cua-driver binary as Sentient sees it: where it lives, whether it's ready, and the exact
//  codex flags that hand it to a computer-use run. cua-driver (MIT, github.com/trycua/cua) is one
//  self-contained Mach-O that speaks MCP over stdio and drives macOS apps IN THE BACKGROUND —
//  per-window clicks and keystrokes with no cursor warp and no focus steal — plus per-window
//  screenshots and accessibility trees. Browsers are driven the same way, as native windows; the
//  driver's typed CDP route into Chrome is deliberately off (see `enabledTools`).
//
//  How a run uses it — the HYBRID transport: Sentient owns a long-lived daemon
//  (Driver/CuaDriverHost) and the codex agent reaches it two ways at once, both clients of the SAME
//  daemon. The EYES ride MCP: a thin `mcp --embedded --socket …` proxy exposing ONLY the four
//  vision tools (mcpTools), so every look is one call with the screenshot inline, with only four
//  schemas. The HANDS ride the CLI: one-shot `<shim> <tool> '<json>'` calls for every action,
//  taught by CuaDriverSkill at zero schema cost. The daemon is a DIRECT
//  child of Sentient, so macOS answers its Accessibility and Screen Recording checks with
//  SENTIENT's grants: the user grants twice, to the app they already trust, and no second helper
//  ever appears in System Settings. The daemon also owns the AppKit runloop that draws the agent
//  cursor — the reason this shape is worth its lifecycle code over `mcp --direct`.
//
//  Key members:
//   - version / tarballURL / tarballSHA256 → the pinned release (CuaDriverSetup fetches exactly this)
//   - binaryURL / isInstalled              → the resolved binary and its readiness probe
//   - mcpTools / codexOverrides()          → the eyes: the vision tools registered with codex over MCP
//   - shimURL                              → the CLI shim (CuaDriverHost writes it)
//   - enabledTools                         → the full allowlist CuaDriverSkill teaches the model
//
//

import Foundation

enum CuaDriver {

    // MARK: The pinned release

    /// The cua-driver release Sentient runs. PINNED on purpose: upstream ships breaking changes
    /// almost daily (0.9 → 0.20 in 27 days, six of them breaking), so "latest" is never an option —
    /// each Sentient release carries the one driver version it was tested against, and bumping it
    /// is a deliberate edit here plus a fresh `tarballSHA256`.
    static let version = "0.20.0"

    /// The bare-binary tarball from the release's own GitHub assets (`cua-driver`, plus SDK
    /// artifacts we don't extract). Deliberately NOT their `install.sh`: that installs a
    /// CuaDriver.app into /Applications, edits the user's shell PATH, and fires an install
    /// telemetry event — none of which belongs in a Sentient setup.
    static var tarballURL: URL {
        URL(string: "https://github.com/trycua/cua/releases/download/cua-driver-rs-v\(version)/cua-driver-rs-\(version)-darwin-universal-binary.tar.gz")!
    }

    /// SHA-256 of that exact asset, checked against upstream's published `checksums.txt` and
    /// re-verified locally (2026-09-19). Their installer does NOT checksum its download; ours does,
    /// so a swapped or truncated asset can never reach the user's Mac.
    static let tarballSHA256 = "07a88ea2c28a9ead66b2d9f6f93fab4b1189a1f7c704d2cd7b6d12c30eee9984"

    /// Roughly 39 MiB compressed — named for the setup line, not
    /// used as a gate.
    static let tarballBytes: Int64 = 40_625_908

    /// Cua AI's Apple Developer Team ID. The extracted binary must satisfy a codesign requirement
    /// naming it, so we only ever run something Cua actually signed — the provenance half of the
    /// check the hash can't make (a hash proves "the bytes we pinned", this proves "and they came
    /// from Cua").
    static let signingTeamID = "YCK386LBJ7"

    // MARK: Where it lives

    /// `~/Library/Application Support/SentientOS/CuaDriver/` — inside the one namespaced root, so
    /// Uninstall's existing sweep of `URL.sentientSupport` already takes the driver with it.
    static var installRoot: URL {
        URL.sentientSupport.appendingPathComponent("CuaDriver", isDirectory: true)
    }

    /// The binary for the PINNED version. Version-keyed, so an app update that bumps the pin lands
    /// its own copy beside the old one (which the next successful setup sweeps) instead of racing a
    /// running driver over the same path.
    static var binaryURL: URL {
        installRoot.appendingPathComponent(version, isDirectory: true).appendingPathComponent("cua-driver")
    }

    /// Ready to drive? The pinned binary is on disk and executable. Cheap enough for a UI refresh;
    /// the signature and smoke checks happen once, at install (CuaDriverSetup).
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    /// An installed older release is evidence of CUA setup, not a legacy Codex migration.
    /// Ignore staging directories and unrelated files. The receipt survives a missing binary and
    /// Factory Reset (which preserves installed dependencies); Uninstall removes the entire root.
    static var installedVersions: [String] { installedVersions(at: installRoot) }

    static func installedVersions(at root: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter {
            isReleaseVersion($0) && fm.isExecutableFile(atPath:
                root.appendingPathComponent($0).appendingPathComponent("cua-driver").path)
        }.sorted()
    }

    static func isReleaseVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static var hasInstallationHistory: Bool { hasInstallationHistory(at: installRoot) }

    static func hasInstallationHistory(at root: URL) -> Bool {
        if let receipt = try? String(contentsOf: root.appendingPathComponent(".installed-version"), encoding: .utf8),
           isReleaseVersion(receipt.trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
        return !installedVersions(at: root).isEmpty
    }

    /// Adopt pre-receipt installations before deciding which upgrade experience to show.
    static func rememberExistingInstallation() {
        guard let installed = isInstalled ? version : installedVersions.last else { return }
        do { try recordInstallation(installed, at: installRoot) }
        catch { Log("CuaDriver: could not persist installation receipt (\(ErrorLabel(error)))") }
    }

    static func recordInstallation(_ installed: String, at root: URL) throws {
        try (installed + "\n").write(to: root.appendingPathComponent(".installed-version"),
                                     atomically: true, encoding: .utf8)
    }

    // MARK: The tool surface handed to the model

    /// The tools the model is ALLOWED to call, out of the 56 cua-driver advertises — spliced into
    /// CuaDriverSkill's manual as the explicit allowlist. The `mcpTools` subset arrives as real MCP
    /// tools; everything else here is CLI-only, taught by the skill text. Prompt-enforced (the
    /// daemon serves its full surface to any same-user client; its bounded permission mode with a
    /// reviewed capability manifest is a different runtime posture, not an allowlist). Same posture
    /// the old MCP `enabled_tools` trim had: advisory to the model, invisible tools simply never
    /// get taught. The one hard gate that matters lives in the daemon: CuaDriverHost passes no
    /// launch grant, so the daemon refuses to attach to the user's browser profile at all.
    ///
    /// Deliberately OUT — the whole `browser_*` family (decided 2026-09-20). The driver's typed
    /// CDP route reaches the user's logged-in Chrome only through Chrome's own remote-debugging
    /// toggle (Chrome ≥136 ignores the debugging flag on the real profile), and in that mode Chrome
    /// activates its window and raises an "Allow remote debugging?" dialog on EVERY new
    /// connection, with no way to remember the answer; the toggle also persists in Chrome's Local
    /// State. Browsers are driven as native windows instead — screenshot + accessibility tree +
    /// the same ax/px ladder — which is how the driver already treats Safari and Firefox.
    /// Also out: `page` (its legacy Apple Events route can quit the user's browser and rewrite
    /// every profile's Preferences), `kill_app`, `bring_to_front` (steals the foreground and never
    /// restores it — per-action `delivery_mode: "foreground"` is the honest escalation),
    /// `check_for_update` (a network call the model could make), `install_ffmpeg`,
    /// `replay_trajectory`, the recording family, and the session/cursor/config/history
    /// management tools.
    static let enabledTools = [
        // See, then act, then check.
        "list_apps", "launch_app", "list_windows", "get_window_state", "get_desktop_state",
        "click", "double_click", "right_click", "drag", "scroll",
        "type_text", "press_key", "hotkey", "set_value", "invoke_menu",
        "set_window_frame", "verify_state",
        // Magnify a dense region to aim precisely (pairs with from_zoom on click/type_text).
        "zoom",
        // Exact values in and out of a field without a select-and-copy dance.
        "clipboard_read", "clipboard_write",
    ]

    // MARK: The MCP eyes (the vision tools, and only them)

    /// The tools registered with codex over MCP — the model's EYES. Exactly the image-returning
    /// native-window tools, nothing else: their results land in context as real inline images (one
    /// call per look, no save-file → view-image hop), while action schemas stay out of the initial
    /// context and ride the CLI, with describe available on demand. The four carry no session
    /// coupling — the element cache is daemon-owned, keyed (pid, window_id) — so a token read over
    /// MCP works in a CLI click.
    static let mcpTools = ["get_window_state", "get_desktop_state", "zoom", "verify_state"]

    // MARK: The codex wiring (MCP = eyes only)

    /// The `-c` overrides that register the eyes with ONE codex run. Per-run on purpose (the same
    /// law as the frontier-model overrides): nothing is ever written into the user's own
    /// `~/.codex/config.toml`. `enabled_tools` filters the daemon's 56-tool surface down to
    /// `mcpTools` harness-side — the model never sees a byte of the other schemas.
    ///
    /// `mcp --embedded --socket <path>` is a PROXY: it forwards tool calls to Sentient's daemon and
    /// never executes anything itself, so codex spawning it is harmless to TCC attribution (the
    /// daemon, our own child, is what macOS charges).
    ///
    /// The env block is NOT optional: cua-driver ships with product telemetry ON (PostHog) and a
    /// daily GitHub update check, and neither belongs on a Sentient user's machine on our behalf.
    static func codexOverrides(socketPath: String) -> [String] {
        let tools = mcpTools.map { "\"\($0)\"" }.joined(separator: ",")
        return [
            "mcp_servers.cua_driver.command=\"\(binaryURL.path)\"",
            "mcp_servers.cua_driver.args=[\"mcp\",\"--embedded\",\"--socket\",\"\(socketPath)\"]",
            "mcp_servers.cua_driver.env={CUA_DRIVER_EMBEDDED=\"1\",CUA_DRIVER_RS_TELEMETRY_ENABLED=\"false\",CUA_TELEMETRY_ENABLED=\"false\",CUA_DRIVER_RS_UPDATE_CHECK=\"false\"}",
            "mcp_servers.cua_driver.enabled_tools=[\(tools)]",
            // Eyes that fail to open must fail the RUN, not quietly leave the model blind (it
            // would happily "finish" the task off the tree alone).
            "mcp_servers.cua_driver.required=true",
            // A single window snapshot on a big app can take a while; codex's 60 s default cuts
            // real work short.
            "mcp_servers.cua_driver.tool_timeout_sec=120",
            "mcp_servers.cua_driver.startup_timeout_sec=30",
        ]
    }

    // MARK: The Claude wiring (the same eyes, in `--mcp-config` dialect)

    /// The `--mcp-config` JSON that registers the eyes with ONE `claude -p` run — the
    /// codexOverrides twin (same proxy command, same socket, same telemetry/update kill
    /// switches). Passed with `--strict-mcp-config`, so this is the ONLY MCP server the run
    /// sees. Timeouts ride env vars on the Claude side (MCP_TIMEOUT / MCP_TOOL_TIMEOUT —
    /// ClaudeCLI sets both); the enabled_tools trim rides `claudeDisallowedMcpTools` below.
    static func claudeMcpConfig(socketPath: String) -> String {
        let config: [String: Any] = ["mcpServers": ["cua_driver": [
            "type": "stdio",
            "command": binaryURL.path,
            "args": ["mcp", "--embedded", "--socket", socketPath],
            "env": ["CUA_DRIVER_EMBEDDED": "1",
                    "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
                    "CUA_TELEMETRY_ENABLED": "false",
                    "CUA_DRIVER_RS_UPDATE_CHECK": "false"],
        ]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"mcpServers":{}}"#   // unreachable (the dict is static-shaped); fail closed
        }
        return json
    }

    /// The full tool surface the daemon serves over MCP for the PINNED version — captured from
    /// `cua-driver list-tools` (56 tools, verified 2026-09-19 on 0.20.0). Claude Code has no
    /// per-server enabled_tools filter, so the trim is a DENY list: everything except the four
    /// eyes, each denied by its `mcp__cua_driver__<name>` rule, which removes the tool from the
    /// model's context entirely. Version-pinned like the skill: bump `version`, re-capture this.
    static let toolCatalogVersion = "0.20.0" // checked by Scripts/check_cua_contract.py at build time
    private static let allMcpServedTools = [
        "bring_to_front", "browser_click", "browser_dialog", "browser_download",
        "browser_navigate", "browser_pointer", "browser_prepare", "browser_set_input_files",
        "browser_type", "check_for_update", "check_permissions", "click", "clipboard_read",
        "clipboard_write", "double_click", "drag", "end_session", "escalate_session",
        "get_accessibility_tree", "get_agent_cursor_state", "get_browser_state", "get_config",
        "get_cursor_position", "get_desktop_state", "get_recording_state", "get_screen_size",
        "get_session", "get_session_state", "get_window_state", "health_report", "hotkey",
        "install_ffmpeg", "invoke_menu", "kill_app", "launch_app", "list_apps", "list_sessions",
        "list_windows", "move_cursor", "page", "press_key", "replay_trajectory", "right_click",
        "scroll", "set_agent_cursor_enabled", "set_agent_cursor_motion", "set_agent_cursor_theme",
        "set_config", "set_value", "set_window_frame", "start_recording", "start_session",
        "stop_recording", "type_text", "verify_state", "zoom",
    ]

    /// The deny list a Claude computer-use run passes to `--disallowedTools`: every daemon MCP
    /// tool that is NOT one of the four eyes. Actions stay CLI-only (the hybrid transport's
    /// whole point), and the deliberately-out tools (page, kill_app, …) are genuinely absent.
    static let claudeDisallowedMcpTools: [String] =
        allMcpServedTools.filter { !mcpTools.contains($0) }.map { "mcp__cua_driver__\($0)" }

    // MARK: The CLI shim (how a codex run reaches the daemon)

    /// The one-line launcher a computer-use run invokes as `<shim> <tool> '<json>'`. It lives at a
    /// SPACE-FREE path on purpose (the real binary sits under "Application Support", and an LLM
    /// writing shell commands around a spaced path is a per-call quoting hazard), bakes in the
    /// daemon's per-generation `--socket`, and pins the privacy env (telemetry + update check off)
    /// so no one-shot call ever phones home. CuaDriverHost rewrites it on every daemon generation;
    /// the PATH is stable, so CuaDriverSkill can reference it from a prompt built before the run.
    /// Parent dir is `~/Library/Caches/<bundleID>` — already inside Uninstall's sweep.
    static var shimURL: URL {
        cachesRoot.appendingPathComponent("cua")
    }

    /// `~/Library/Caches/<bundleID>/` — the app's own caches namespace (created on demand by
    /// CuaDriverHost). Chosen over the Application Support root for the one property that matters
    /// here: no spaces anywhere in the path.
    private static var cachesRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS",
                                    isDirectory: true)
    }
}
