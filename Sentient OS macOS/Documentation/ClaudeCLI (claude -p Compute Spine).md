# ClaudeCLI — the `claude -p` compute spine

`ClaudeCLI.swift` is the wrapper every cloud-model feature rides on (Arch §5): vault
generation, the daily updater, and proactive intelligence all call the user's own Claude Code
headlessly instead of our API key. One actor, three methods.

## API

```swift
// Is claude usable on this Mac? (binary found AND authenticated — cached per launch)
let availability = await ClaudeCLI.shared.validate()        // force: true to re-probe

// One headless call
var inv = ClaudeCLI.Invocation(prompt: bigPrompt)           // prompt goes over STDIN, never argv
inv.model = .opus1M                                         // or .sonnet
inv.allowedTools = ["Write", "Edit", "Read", "Glob", "Grep"]
inv.cwd = stagingDir.path                                   // the agent's working directory
inv.resumeSessionID = priorSessionID                        // continue after a usage limit
let envelope = try await ClaudeCLI.shared.run(inv)
// envelope: result · stopReason · sessionID · numTurns · durationMS · totalCostUSD
//           · permissionDenialCount · input/outputTokens · raw JSON
```

## The mechanics (all pre-verified live — Arch §5 receipts)

- **Discovery:** `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`,
  `/usr/local/bin/claude`, then `zsh -lc "which claude"` (GUI apps don't inherit the user's
  PATH). Cached in UserDefaults, re-verified on every read.
- **Sanitized env:** just `HOME`, `USER`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin` + the absolute
  binary path. Keychain OAuth resolves itself; no TTY needed.
- **STDIN prompts:** corpora run hundreds of KB; argv caps at 1 MB on macOS. The stdin write
  overlaps the child's reads on its own queue (a >64 KB write would otherwise deadlock), and
  closing the handle is the EOF the CLI waits for.
- **Envelope:** `--output-format json` parsed leniently; parsed BEFORE checking the exit code,
  because limit failures emit a JSON envelope alongside a non-zero exit.
- **Usage limits:** typed `CLIError.usageLimit(message:sessionID:)` — the session id is what
  makes reschedule-and-resume natural for agentic jobs.
- **Timeout:** watchdog `terminate()`; default 1 h (agentic vault runs are long), ping 15 s.

## Self-test

```sh
SENTIENT_SELFTEST=claudecli "<DerivedData>/.../Sentient OS.app/Contents/MacOS/Sentient OS"
```

Dumps discovery → availability → a tiny real run with the full envelope. No model file needed.

## Future (don't pre-build)

`--output-format stream-json` for live-token UI · `--json-schema` is already plumbed for
proactive's `{time, text}` · the Bedrock tier slots in BESIDE this as waterfall tier 3.
