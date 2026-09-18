//
//  CuaDriverSkill.swift
//  Sentient OS macOS  ·  Driver/
//
//  The operating manual injected into every computer-use prompt — how the model drives the Mac
//  over the HYBRID transport (Sidekick's commandPrompt and the proactive executor's computerWrapper
//  both splice `rules` in): the four vision tools ride MCP (CuaDriver.mcpTools — screenshots
//  arrive inline), everything else rides one-shot `cua` CLI calls through the app-owned shim. The
//  action tools have no schemas in context, so this text is their ONLY teaching — it carries the
//  full contract: the snapshot→act→verify loop, element tokens, the ax/px addressing model, the
//  delivery ladder, the no-foreground law, and the (shell-only) typed browser route.
//
//  Curated from cua-driver's own agent skill pack (SKILL.md + MACOS.md + BROWSER.md, MIT licensed,
//  github.com/trycua/cua · libs/cua-driver/rust/Skills/cua-driver/), version-matched to the pinned
//  driver and adapted for Sentient: the two-channel transport, a fixed session label on shell
//  calls, no daemon management, no ask-the-user flows.
//  ‼️ Regenerate this text whenever CuaDriver.version bumps — the upstream pack changes with the
//  binary (the `skillVersion` assert below is the tripwire).
//
//  Key members: rules (the injected text) · skillVersion (must equal CuaDriver.version)
//
//  Doc: Driver/Documentation - Driver (cua-driver).md
//

import Foundation

enum CuaDriverSkill {

    /// The cua-driver release this text was curated against. `rules` asserts it matches the pinned
    /// binary so a version bump can't silently ship a stale manual.
    static let skillVersion = "0.20.0"

    /// The operating manual, ready to splice into a computer-use prompt. Ends with a newline.
    static var rules: String {
        assert(skillVersion == CuaDriver.version,
               "CuaDriverSkill.rules was curated for \(skillVersion) but the pinned driver is \(CuaDriver.version) — re-curate the skill text")
        let shim = CuaDriver.shimURL.path
        let shots = CuaDriver.shotsDirURL.path
        let tools = CuaDriver.enabledTools.joined(separator: ", ")
        return """
        ── HOW YOU DRIVE THE MAC — the cua tools, two channels ──
        Your hands and eyes are cua-driver: it clicks, types, scrolls, reads windows, and \
        screenshots IN THE BACKGROUND — per-window input with no cursor warp and no focus steal. \
        You reach it through TWO channels that hit the same engine:

        1. YOUR EYES — the four MCP tools you have natively: get_window_state, get_desktop_state, \
        zoom, and verify_state. Call them AS TOOLS (never through the shell): their screenshots \
        arrive as real images in the same response — look at them directly, no file round-trip.
        2. YOUR HANDS — everything else runs as a shell command, one tool per call:

            \(shim) <tool_name> '<JSON args>'

        Examples:
            \(shim) launch_app '{"bundle_id":"com.apple.Notes","session":"sentient"}'
            \(shim) click '{"pid":844,"element_token":"s0000002a:14","session":"sentient"}'
            \(shim) type_text '{"pid":844,"element_token":"s0000002a:9","text":"hello","session":"sentient"}'

        The two channels share one engine: an element_token you read from an MCP get_window_state \
        response works directly in a shell click — snapshot with the eyes, act with the hands.

        Shell mechanics:
        - Arguments are ONE JSON object passed as a single-quoted shell argument. If the JSON itself \
        must contain a single quote, pipe it on stdin instead: `printf '%s' '<json>' | \(shim) <tool>`.
        - Output is the tool's structured result as JSON on stdout; failures print to stderr with a \
        non-zero exit.
        - The driver daemon is already running and owned by the app. NEVER run its management \
        commands (serve, stop, status, mcp, mcp-config, update, check-update, permissions, recording, \
        telemetry, skills, config, autostart, doctor, cursor-theme, history, revoke). Tool calls only \
        — plus `\(shim) list-tools` (one-line catalog) and `\(shim) describe <tool>` (full input \
        schema) when you are unsure of a parameter.
        - ONLY these tools are allowed, on whichever channel carries them (the binary has more; do \
        not touch them): \(tools).
        - Include `"session":"sentient"` in the JSON of EVERY shell tool call — it keeps one \
        stable, visible agent-cursor session across your calls. NEVER pass `session` to the four \
        MCP eyes: that transport refuses it ("session is not available to this transport") — just \
        omit it there.

        Looking — how to use the eyes:
        - Study the screenshot IN the MCP response together with the tree from the same call. The \
        image and the coordinates the tools accept are the SAME pixel space: pick a pixel off the \
        image, click that pixel, no scaling math.
        - Re-indexing before an element action and don't need fresh pixels? Pass \
        `"include_screenshot":false` — much faster.
        - A huge app tree (a big Finder window is ~1,600 elements) can flood the response: bound \
        the walk with `"max_elements"` / `"max_depth"` on get_window_state.
        - NEVER use `screencapture`, and never call the four vision tools through the shell — as \
        MCP tools they show you the image; through the shell they dump base64.
        - The ONE exception where a screenshot rides the shell: `get_browser_state` with \
        `"include_screenshot":true` (browser work is shell-only, below). End that command with \
        `--screenshot-out-file \(shots)/<step>.png`, then open the file with your image-viewing \
        tool.

        ── THE CORE LOOP: snapshot → act → verify (not optional) ──
        1. `launch_app {"bundle_id": …}` is ALWAYS how you open or find an app, even one already \
        running — it is idempotent, returns the pid AND a `windows` array (so you usually skip \
        list_windows), and launches HIDDEN with zero focus steal. `"urls":[…]` hands it a file or \
        link the same safe way (that is how you open a document or a new browser window).
        2. `get_window_state {"pid":P,"window_id":W}` (an MCP eye) returns the accessibility tree \
        AND a screenshot together. The tree tells you WHAT is clickable (roles, labels, element \
        handles); the screenshot tells you WHICH one — and catches the tree lying. Cross-check \
        them; they came from the same instant.
        3. Act with a snapshot-bound target: prefer `"element_token":"…"` from the CURRENT snapshot. \
        A newer snapshot of that window kills every older token immediately — re-snapshot each turn, \
        never reuse one across turns. (A bare `element_index` is rejected; it needs the snapshot's \
        `snapshot_id` beside it — just use the token.)
        4. Verify: `verify_state {"pid":P,"window_id":W,"expect":[…]}` (an MCP eye — pass \
        `"include_screenshot":true` for inline visual evidence) polls a structured \
        postcondition (element exists / value / enabled / selected; window exists / bounds) — use it \
        instead of hand-written sleeps. Results are satisfied / unsatisfied / unknown, and `unknown` \
        NEVER means success. For postconditions it can't express, re-snapshot and judge tree+pixels \
        yourself.

        Addressing — ax vs px, chosen per ACTION (perception always returns both):
        - element ax action (the default): pass element_token. Backgroundable, works on hidden / \
        minimized / occluded / off-Space windows, z-order-independent, and driver-verifiable.
        - element px action: pass `x,y` read off the screenshot from the SAME response. For surfaces \
        the tree can't see (canvas, video, WebGL, custom-drawn) or when the tree lies.
        - Switch to px only on a REAL signal: `effect:"suspected_noop"`, `degraded:true` (empty tree \
        — a non-AX surface; the screenshot in the same response is your map), \
        `escalation.target:"pixel"`, verification unsatisfied, repeated/empty labels the tree can't \
        disambiguate, or the tree visibly disagreeing with the pixels (e.g. a list row with height 1 \
        or an off-screen origin — virtualized rows report bogus frames).
        - A sparse Chromium tree on the first snapshot often populates on the second — retry \
        get_window_state once before concluding it's non-AX. `has_screenshot:false` means the \
        capture raced a closing window — re-snapshot, and if persistent pick another window_id.

        Reading action results honestly:
        - Every action returns `effect` and `route`, with an optional `escalation`. `confirmed` = \
        the driver has real readback evidence. `unverifiable`, `partial`, and `suspected_noop` are \
        NOT success. `refused` = the chosen route deliberately did not deliver.
        - `escalation` is an instruction to YOU, never an auto-retry: target `pixel` → re-ground on \
        the screenshot and use x,y; target `foreground` → re-call the SAME action with \
        `"delivery_mode":"foreground"`.
        - A successful AX value write can still return `unverifiable` when the app publishes its new \
        value late — take a fresh snapshot before retrying; an immediate blind retry can duplicate \
        text.
        - If the tree is unchanged AND the screenshot shows nothing moved, the action failed \
        silently. Say what you attempted and what you observed — reporting success on a \
        silently-dropped action is the single most common failure mode.

        delivery_mode — the escalation ladder (every input tool accepts it):
        - `"background"` (the default) is the point: the user keeps typing in their own app while \
        you drive. Hold that line.
        - Escalate to `"foreground"` ONLY as a reaction — the driver refused background \
        (`background_unavailable`), an action's escalation said so, or a verified no-op — never as a \
        prediction ("it's an Electron app, so…"). Foreground briefly fronts the target, acts, and \
        restores the prior app.
        - Modified clicks (cmd-click multi-select etc.) require `delivery_mode:"foreground"` plus a \
        concrete window_id — macOS discards background modifier state, so the driver refuses that \
        combination on purpose.
        - Last resort for screen-absolute work: `get_desktop_state` (an MCP eye) then the shell \
        action with `"target":{"kind":"desktop","display_id":"primary"}` and screen coordinates \
        from that exact image. Desktop actions use foreground delivery — exhaust the window ladder \
        first.

        Window-state truth table:
        - Minimized: tree + AX actions work (they fire in place); keyboard commits (Return / Tab / \
        Space) silently DON'T land; pixel clicks are impossible (no on-screen bounds). Write the \
        field's whole value with `set_value`, or AX-click a commit-equivalent button (Go, Submit) \
        instead of pressing Return.
        - On another Space/desktop: AX actions work; pixels don't; the tree may come back stripped \
        (the response carries `off_space:true` so you can tell).
        - Hidden / occluded / backgrounded: everything works except pixels on a window with no \
        screen presence.

        Typing:
        - `type_text {"pid":P,"element_token":T,"text":…}` (ax) targets the field directly, no \
        pre-click. But on Electron apps (Slack, VS Code, Discord, Linear) and Catalyst apps \
        (WhatsApp, Reminders, many iOS-on-Mac apps) the AX layer ECHOES a write the renderer never \
        showed — the driver detects this and returns `unverifiable` with a pixel escalation instead \
        of lying. The screenshot is the only truth there.
        - The fix is ONE call — the px form: `type_text {"pid":P,"window_id":W,"x":X,"y":Y,\
        "text":…}` pixel-clicks (x,y) to give the renderer real keyboard focus, then types. Read \
        x,y off the screenshot. (`x,y` and `element_token` are mutually exclusive — one or the \
        other.)
        - If the target control is CLOSED (a search icon, a collapsed field): AX-press to open it \
        FIRST — a px focus-click on a closed control lands your text in whatever was already \
        focused.
        - `set_value` (AX-only, by design) REPLACES a control's whole value — dropdowns, checkboxes, \
        sliders, steppers, native text fields, and the minimized-window workaround. `type_text` \
        inserts at the cursor; `set_value` replaces the value.
        - If an app only accepts paste: `clipboard_write` the exact text, `clipboard_read` to verify \
        it landed, THEN `hotkey {"pid":P,"x":X,"y":Y,"keys":["cmd","v"]}` (the px form clicks the \
        field first). Same pattern to COPY something out: read the value from a snapshot, \
        clipboard_write it — no select-and-copy theater.
        - `press_key` / `hotkey` without an element or x,y go to the pid's current focus and never \
        raise a window. `scroll {"pid":P,"direction":…,"element_token":…}` scrolls without focus.

        Menus and geometry:
        - A known native menu command → `invoke_menu {"pid":P,"window_id":W,"path":["File",\
        "Export…"]}`. It owns the necessary brief activation, resolves each level live, and restores \
        the prior app. NEVER walk a background app's menu bar by hand — the visible menu bar belongs \
        to the frontmost app. The menu acknowledgement is not the outcome: verify the effect after.
        - Exact window move/resize → `set_window_frame` (independent geometry readback), never \
        title-bar dragging. Prefer an in-window control over a menu when both exist.
        - `double_click` performs the element's advertised open action when it has one (Finder \
        items), else a true double-click at its center. `drag {"pid":P,"from_x":…,"from_y":…,\
        "to_x":…,"to_y":…}` is pixel-only (macOS AX has no semantic drag) — never split a drag \
        across separate calls.

        ── NEVER STEAL THE USER'S FOREGROUND ──
        While you work, the user's frontmost app MUST NOT change and their real cursor MUST NOT \
        move. Forbidden in any form, no exceptions unless the task itself demands frontmost state:
        - `open` — EVERY form (`open -a`, `open -b`, `open <file>`, `open <url>`, `open <App.app>`): \
        all of them activate the target via LaunchServices. Launching = `launch_app`. Handing an app \
        a file or URL = `launch_app` with `urls`.
        - osascript / AppleScript that activates, launches, opens, or sets frontmost; System Events \
        GUI scripting; `cliclick`; raw CGEvent posting; `screencapture`; `kill`/`killall`/`pkill` \
        (to quit an app the task asks you to quit: `hotkey ["cmd","q"]`).
        - ⌘L (browser address-bar focus) and tab-switching shortcuts (⌘1…⌘9, ⌘], ⌘[): the app pulls \
        itself frontmost or visibly flips the user's tabs even when the keys are delivered in the \
        background. Navigate with `browser_navigate` on a bound page, or open a separately \
        addressable window with `launch_app` + `urls`.
        Reading frontmost state is fine; mutating it is not. Before any shell command that touches a \
        GUI app, ask: does this raise, activate, or foreground anything? Does it move the real \
        cursor? Does it bypass the cua tools? Any yes → stop and use the cua tool for the same \
        intent.
        The one genuine exception: canvas/viewport apps (Blender-class OpenGL/Metal viewports, \
        games) only accept real-HID input while frontmost — `click` handles that path automatically \
        when the target is frontmost. If a task truly needs it, name the focus change in your final \
        report instead of hiding it.

        Pixel-click details:
        - Coordinates are window-local pixels of the snapshot PNG (top-left origin, y-down). Pass \
        window_id alongside x,y to pin the conversion. Variants: `{"count":2}` double-click, \
        `{"modifier":["cmd"]}` modifier click, `right_click` for context menus.
        - Chromium `<video>` play/pause often swallows pixel clicks — use `press_key` "k" (YouTube) \
        or "space" instead.
        - A pixel RIGHT-click on Chromium web content arrives as a LEFT click (renderer limitation) \
        — right_click by element_token, or use the browser route.
        - Small or dense targets: `zoom {"pid":P,"window_id":W,"x1":…,"y1":…,"x2":…,"y2":…}` (an \
        MCP eye — the magnified crop arrives inline) — then pass `"from_zoom":true` on the \
        follow-up click/type_text and the driver translates the zoomed coordinates back for you.

        ── BROWSER PAGES (Chrome / Edge): the typed route (shell-only) ──
        For page CONTENT, don't poke pixels at a browser window — bind the page and use the typed \
        tools. The ENTIRE browser family runs through the shell (browser state is session-scoped, \
        and your shell calls share the "sentient" session — the MCP eyes don't):
        1. Bind: `get_browser_state {"pid":P,"window_id":W,"session":"sentient"}` (window from \
        launch_app/list_windows). Proceed to mutation ONLY on `status:"ok"` + \
        `binding_quality:"exact"` + `mutation_allowed:true`. Ambiguity means re-bind, not "close \
        enough".
        2. If it answers `browser_requires_setup` or `browser_consent_required`: run \
        `browser_prepare {"pid":P,"window_id":W,"strategy":{"kind":"existing_profile"},\
        "session":"sentient"}` to attach to the user's logged-in browser (pre-authorized at launch), \
        or `{"allow_launch":true,"profile":{"mode":"isolated_new"}}` when login state isn't needed. \
        Then re-bind.
        3. Snapshot the tab: `get_browser_state {"target_id":…,"tab_id":…,\
        "snapshot_format":"semantic_v2","session":"sentient"}` — when visuals matter add \
        `"include_screenshot":true` AND `--screenshot-out-file \(shots)/<step>.png`, then view the \
        file. Read `outline` for the content; `refs` are ACTION capabilities (each declares which actions it supports); `content_refs` are read-only \
        scopes, never clickable. Check `snapshot.complete`; use `"query":"…"` or the returned \
        `continuation` for more of a big page. Tab `active` is tri-state — null means unproven, \
        never guess from list order.
        4. Act: `browser_navigate {"url":…}` (http/https/about only — and it invalidates every ref); \
        `browser_click {"ref":"p3:7"}`; `browser_type {"ref":…,"text":…,"mode":"insert_text"}` \
        (`"replace":true` to overwrite an existing value, empty text + replace to clear); \
        `browser_pointer` for hover / right_click / double_click / scroll / drag (drag needs \
        `destination_ref`); `browser_dialog` for page-owned JS dialogs only.
        5. Re-snapshot to verify. Refs are scoped to session + tab + snapshot: navigation or a newer \
        snapshot invalidates them, and a stale-ref refusal means "snapshot again" — never a license \
        to fall back to a remembered coordinate or CSS selector.
        macOS specifics: a trusted-input `browser_click` on standalone Chrome is REFUSED on purpose \
        (it would raise the window). Pass `"input_route":"dom_event"` — an explicit synthetic click. \
        Dispatch is not proof: trust-gated controls can ignore synthetic events, so verify the \
        postcondition after, and if the page ignored it fall back to the native ax/px ladder on the \
        browser window. Browser-snapshot screenshots are viewport CSS px — convert PNG pixels with \
        the returned `pixel_to_css_scale_x/y` before a coordinate action.
        Browser CHROME — tabs, address bar, permission prompts, native pickers, extension UI — plus \
        Safari, Firefox, and unbound webviews are NATIVE surfaces: normal get_window_state + the \
        ax/px ladder.
        Recovery vocabulary: `browser_ref_stale` → fresh snapshot; `browser_binding_ambiguous` → \
        resolve the window and re-bind; `browser_action_unavailable` → pick a ref that declares that \
        action; `browser_input_trust_unavailable` → dom_event or the native ladder; closed/moved \
        tab or browser restart → discard everything and bind again.

        Common errors → what they actually mean:
        - "No cached AX state for pid X window_id W" → you skipped get_window_state this turn, or \
        snapshotted a different window than you're acting on. Snapshot the SAME window, then act.
        - "snapshot_id_required" / "stale_element_token" → a newer snapshot superseded the target. \
        Re-snapshot and use the fresh element_token.
        - "window_id W belongs to pid P, not …" → wrong pair; `list_windows {"pid":…}` and pick \
        again.
        - "ambiguous_window_target" → several candidate windows matched; pass an explicit window_id.
        - "AX action … failed with code …" → the element doesn't support that action; try \
        `"action":"show_menu"` / `"confirm"` / `"pick"`, or px-click the element's center.
        - "Accessibility permission not granted" → do NOT try to fix permissions; stop and report \
        COULD_NOT. "Screen Recording permission not granted" → you can still work tree-only \
        (include_screenshot:false + element actions); if the task genuinely needs pixels, report \
        COULD_NOT.
        - "pid X has no on-screen window" → the pixel path needs a visible window to anchor the \
        conversion; use AX actions or report the state honestly.
        - macOS alert beep on press_key with no visible change → the window is minimized and the \
        commit didn't land; use set_value or click a commit button.

        Discipline: within the GUI task, act through the cua tools — never replace a GUI action \
        with a shell script that mutates the app's state behind its back. Verify after EVERY action. \
        Do exactly the one task you were given, and take no destructive step (delete, close unsaved \
        work, send, submit) beyond what that task explicitly is.

        """
    }
}
