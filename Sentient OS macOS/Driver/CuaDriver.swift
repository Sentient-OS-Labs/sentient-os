//
//  CuaDriver.swift
//  Sentient OS macOS  ·  Driver/
//
//  The cua-driver binary as Sentient sees it: where it lives, whether it's ready, and the exact
//  codex flags that hand it to a computer-use run. cua-driver (MIT, github.com/trycua/cua) is one
//  self-contained Mach-O that speaks MCP over stdio and drives macOS apps IN THE BACKGROUND —
//  per-window clicks and keystrokes with no cursor warp and no focus steal — plus per-window
//  screenshots and accessibility trees, and a typed route into a Chromium page over CDP.
//
//  How a run uses it: Sentient owns a long-lived daemon (Driver/CuaDriverHost) and a codex run gets
//  a thin `mcp --embedded --socket …` proxy that forwards to it and executes nothing itself. The
//  daemon is a DIRECT child of Sentient, so macOS answers its Accessibility and Screen Recording
//  checks with SENTIENT's grants: the user grants twice, to the app they already trust, and no
//  second helper ever appears in System Settings. The daemon also owns the AppKit runloop that
//  draws the agent cursor — the reason this shape is worth its lifecycle code over `mcp --direct`.
//
//  Key members:
//   - version / tarballURL / tarballSHA256 → the pinned release (CuaDriverSetup fetches exactly this)
//   - binaryURL / isInstalled              → the resolved binary and its readiness probe
//   - codexOverrides()                     → the `-c` block that registers it with codex
//   - enabledTools                         → the trimmed tool surface the model actually gets
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
    /// re-verified locally (2026-08-19). Their installer does NOT checksum its download; ours does,
    /// so a swapped or truncated asset can never reach the user's Mac.
    static let tarballSHA256 = "07a88ea2c28a9ead66b2d9f6f93fab4b1189a1f7c704d2cd7b6d12c30eee9984"

    /// Roughly 39 MB compressed (a ~60 MB universal Mach-O inside) — named for the setup line, not
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

    // MARK: The tool surface handed to the model

    /// The tools codex exposes to the model, out of the 56 cua-driver advertises. Trimmed for two
    /// reasons: cost (the full surface is ~148 KB of JSON schema — measured 35k tokens on a task
    /// that needs 15k with a trimmed list) and blast radius (the excluded ones are management, not
    /// action). Every excluded tool still exists in the binary; the model simply never sees it.
    ///
    /// Deliberately OUT: `page` (its legacy Apple Events route can quit the user's browser and
    /// rewrite every profile's Preferences), `kill_app`, `bring_to_front` (steals the foreground
    /// and never restores it — per-action `delivery_mode: "foreground"` is the honest escalation),
    /// `check_for_update` (a network call the model could make), `install_ffmpeg`,
    /// `replay_trajectory`, the recording family, the session/cursor/config/history management
    /// tools, and `browser_download` / `browser_set_input_files` (nothing we fire needs them yet).
    static let enabledTools = [
        // See, then act, then check.
        "list_apps", "launch_app", "list_windows", "get_window_state", "get_desktop_state",
        "click", "double_click", "right_click", "drag", "scroll",
        "type_text", "press_key", "hotkey", "set_value", "invoke_menu",
        "set_window_frame", "verify_state",
        // Exact values in and out of a field without a select-and-copy dance.
        "clipboard_read", "clipboard_write",
        // The typed browser route: a real page instead of pixels over a browser window.
        "browser_prepare", "get_browser_state", "browser_navigate",
        "browser_click", "browser_type", "browser_pointer", "browser_dialog",
    ]

    // MARK: What the model needs to know

    /// Operating rules injected into the app-authored computer-use prompts (Sidekick's
    /// commandPrompt, the executor's computerWrapper) ON THE CUA DRIVER ONLY — empty on `.codex`,
    /// so the shipped, field-proven prompts stay byte-identical there.
    ///
    /// Why any at all: cua-driver's own MCP `instructions` teach the snapshot → act → verify loop,
    /// and its tool descriptions are unusually good. What they do NOT carry is the no-foreground
    /// discipline — the whole reason we would run this driver — which upstream keeps in a 4,000-line
    /// skill pack the model never sees here. These are the lines from that pack that change what the
    /// model does, compressed.
    static var promptRules: String {
        guard ComputerUseDriver.current == .cua else { return "" }
        return """
        How to use the cua_driver tools (they act INSIDE one window; the cursor never moves and the         frontmost app never changes — keep it that way):
        - Look before every action and check after it. `get_window_state(pid, window_id)` returns the         element tree AND a screenshot together. Element tokens die the moment you take a newer         snapshot of that window, so re-snapshot each turn rather than reusing one.
        - Address elements by `element_token` whenever the tree has them; reach for x/y pixels only         for canvas, video, or custom-drawn surfaces the tree can't see.
        - Background delivery is the default and it is the point. Escalate to         `delivery_mode: "foreground"` only after the driver actually refuses or an action verifiably         did nothing — never up front because an app "seems like" it will need it.
        - The tree lies on Electron and Catalyst apps (Slack, WhatsApp, VS Code): a write can read         back as applied while the real field never changed. The screenshot in the same response is         the truth. When a typed value doesn't take, use the pixel form — `type_text(pid, window_id,         x, y, text)` — which clicks to focus and then types.
        - Keyboard commits (Return, Tab) don't land on a minimized window; `set_value` writes the         field directly instead.
        - In a browser, never send ⌘L or the tab-switching shortcuts: the browser pulls itself to the         front and the user sees their tabs move. Open a page with `launch_app(bundle_id, urls)` or         `browser_navigate`.
        - For page content, bind the window with `get_browser_state` and use the `browser_*` tools.         On macOS a trusted `browser_click` is refused on purpose (it would raise the window) — pass         `input_route: "dom_event"`, then verify with a fresh snapshot, and if the page ignored the         synthetic click fall back to a normal `click` on the browser window. A pixel right-click on         web content arrives as a left-click; right-click by element token instead.
        - Read the `effect` field honestly. `unverifiable` or `suspected_noop` is not success, and a         refusal tells you which rung to try next. Never report a task done on an action you could         not confirm.


        """
    }

    // MARK: The codex wiring

    /// The `-c` overrides that register cua-driver with ONE codex run. Per-run on purpose (the same
    /// law as the frontier-model overrides): nothing is ever written into the user's own
    /// `~/.codex/config.toml`, so a Sentient experiment can't reshape their codex.
    ///
    /// One driver per run is enforced by the RUN being hermetic (`--ignore-user-config`, added in
    /// runAgentCommand): OpenAI's computer-use plugin lives in ~/.codex, and a hermetic run never
    /// loads it. Verified 2026-08-19 that this is the only lever which works — `-c` overrides on
    /// `plugins.*` don't take, and disabling the plugin's MCP server still leaves its SKILL
    /// advertised, which is what sent the model on a "using the computer-use skill" detour.
    ///
    /// `mcp --embedded --socket <path>` is a PROXY: it forwards tool calls to Sentient's daemon and
    /// never executes anything itself, so codex spawning it is harmless to TCC attribution (the
    /// daemon, our own child, is what macOS charges). `--grant existing-profile` is NOT passed here
    /// — launch grants belong to the runtime, which is the daemon, and CuaDriverHost passes it there.
    ///
    /// The three environment variables are NOT optional for us: cua-driver ships with product
    /// telemetry ON (PostHog) and a daily GitHub update check, both of which would put a Sentient
    /// user's machine on someone else's network on our behalf. codex hands the child a curated base
    /// environment (HOME, PATH, TMPDIR, USER, SHELL, LANG) and merges these on top, so this is the
    /// child's whole world.
    static func codexOverrides(socketPath: String) -> [String] {
        let tools = enabledTools.map { "\"\($0)\"" }.joined(separator: ",")
        return [
            "mcp_servers.cua_driver.command=\"\(binaryURL.path)\"",
            "mcp_servers.cua_driver.args=[\"mcp\",\"--embedded\",\"--socket\",\"\(socketPath)\"]",
            "mcp_servers.cua_driver.env={CUA_DRIVER_EMBEDDED=\"1\",CUA_DRIVER_RS_TELEMETRY_ENABLED=\"false\",CUA_TELEMETRY_ENABLED=\"false\",CUA_DRIVER_RS_UPDATE_CHECK=\"false\"}",
            "mcp_servers.cua_driver.enabled_tools=[\(tools)]",
            // A driver that fails to start must fail the RUN, not quietly leave the model with no
            // hands (it would happily "finish" the task by doing nothing).
            "mcp_servers.cua_driver.required=true",
            // A single window snapshot on a big app can take a while; codex's 60 s default cuts
            // real work short.
            "mcp_servers.cua_driver.tool_timeout_sec=120",
            "mcp_servers.cua_driver.startup_timeout_sec=30",
        ]
    }
}
