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
//  How a run uses it — the HYBRID transport: Sentient owns a long-lived daemon
//  (Driver/CuaDriverHost) and the codex agent reaches it two ways at once, both clients of the SAME
//  daemon. The EYES ride MCP: a thin `mcp --embedded --socket …` proxy exposing ONLY the four
//  vision tools (mcpTools), so every look is one call with the screenshot inline, at ~3k tokens of
//  schema. The HANDS ride the CLI: one-shot `<shim> <tool> '<json>'` calls for every action and
//  the whole browser family, taught by CuaDriverSkill at zero schema cost. The daemon is a DIRECT
//  child of Sentient, so macOS answers its Accessibility and Screen Recording checks with
//  SENTIENT's grants: the user grants twice, to the app they already trust, and no second helper
//  ever appears in System Settings. The daemon also owns the AppKit runloop that draws the agent
//  cursor — the reason this shape is worth its lifecycle code over `mcp --direct`.
//
//  Key members:
//   - version / tarballURL / tarballSHA256 → the pinned release (CuaDriverSetup fetches exactly this)
//   - binaryURL / isInstalled              → the resolved binary and its readiness probe
//   - mcpTools / codexOverrides()          → the eyes: the vision tools registered with codex over MCP
//   - shimURL / shotsDirURL                → the CLI shim + screenshot drop-box (CuaDriverHost writes them)
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

    /// The tools the model is ALLOWED to call, out of the 56 cua-driver advertises — spliced into
    /// CuaDriverSkill's manual as the explicit allowlist. The `mcpTools` subset arrives as real MCP
    /// tools; everything else here is CLI-only, taught by the skill text. Prompt-enforced (the
    /// daemon serves its full surface to any same-user client; a capability manifest can't narrow
    /// it for us because a manifest also origin-pins `browser_navigate`, and our tasks go to
    /// arbitrary URLs — verified against authorization.rs 2026-08-20). Same posture the old MCP
    /// `enabled_tools` trim had: advisory to the model, invisible tools simply never get taught.
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
        // Magnify a dense region to aim precisely (pairs with from_zoom on click/type_text).
        "zoom",
        // Exact values in and out of a field without a select-and-copy dance.
        "clipboard_read", "clipboard_write",
        // The typed browser route: a real page instead of pixels over a browser window.
        "browser_prepare", "get_browser_state", "browser_navigate",
        "browser_click", "browser_type", "browser_pointer", "browser_dialog",
    ]

    // MARK: The MCP eyes (the vision tools, and only them)

    /// The tools registered with codex over MCP — the model's EYES. Exactly the image-returning
    /// native-window tools, nothing else: their results land in context as real inline images (one
    /// call per look, no save-file → view-image hop), while their schemas cost only ~3k tokens —
    /// the expensive schemas (click ~1.6k, type_text ~1.4k…) belong to the action tools, which ride
    /// the CLI for free. `get_browser_state` is deliberately NOT here: browser targets and refs are
    /// session-scoped and a session never bridges transports (verified in run_call's namespace
    /// handling, 2026-08-21), so the whole browser family stays on the CLI where one shared
    /// `"session"` label keeps bind → snapshot → act coherent. The four below carry no session
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
    /// daemon, our own child, is what macOS charges). `--grant existing-profile` is NOT passed here
    /// — launch grants belong to the runtime, which is the daemon, and CuaDriverHost passes it there.
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

    /// Where the model saves every screenshot it takes (`--screenshot-out-file <here>/<step>.png`),
    /// then views it. These are content-bearing frames of the user's windows, so CuaDriverHost
    /// wipes the directory on every fresh daemon generation, and Uninstall's caches sweep takes the
    /// whole folder. NOTE: must stay a REAL directory path — the driver's output-path check refuses
    /// a symlinked ancestor like `/tmp` (field-found 2026-08-20), which caches paths never are.
    static var shotsDirURL: URL {
        cachesRoot.appendingPathComponent("cua-shots", isDirectory: true)
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
