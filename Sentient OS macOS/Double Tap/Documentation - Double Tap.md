# Double Tap (Double Tap/)

Double Tap is the fastest way to answer something. The cursor sits in a reply box (Gmail, Mail,
iMessage, WhatsApp, Slack, anything), the user taps the right ⌥ key twice, and about two seconds
later a reply written in their voice is sitting in the box, grounded in everything Sentient knows
about them. Nothing is sent: the user reads it, edits it if they like, and presses Send themselves.
If the screen is not an email or message reply box, the notch answers with a short aside instead.

Where Sidekick is "tell me what to do", Double Tap is one gesture with one meaning, and it is judged
on feel: the whole point is that the reply appears before the user could have started typing it.

## Files

| File | Job |
|---|---|
| `DoubleTap.swift` | The run: the screenshot of the display under the cursor, the downscale, the model call, the paste into the focused field (or the aside), the last run's timing report. Owns the fixed key (`key`), the double-tap window, the dev switch, and the hard deadline. |
| `DoubleTapInference.swift` | The one model call: packs the whole knowledge base, builds the prompt, streams the Responses API, parses the verdict (reply or `NOT_A_MESSAGE`), logs the timings. |

Three pieces live elsewhere. `CommandCoordinator` (Notch Magic/) owns the key listener and the
two-presses-in-a-window test, and adopts the run into the notch. `ScreenCapture` (Notch Magic/)
grew a single-display capture and a JPEG downscale for this feature. The server half is a
Cloudflare Worker Sentient runs; the app knows only its URL. The switch, the route picker, the
relay URL override, the dev key field, and the timing readout sit in Dev Tools
(`Views/Dev/DevToolsView.swift`).

## How a press works

1. **The key.** A second `SidekickHotkeyMonitor` listens on right ⌥, beside Sidekick's own monitor
   on its chosen key. Two presses within 0.35 s (press to press) count as a double tap. Nothing
   happens with the dev switch off, and nothing happens if Sidekick's hotkey is set to right ⌥ too:
   Sidekick keeps the key. A double tap while the notch is busy (a run, an open type field, a live
   hold) is ignored and logged.
2. **The notch.** The run adopts the notch exactly like a proactive card's fire: the one-task lock,
   the caption "Drafting your reply", and a Sidekick hotkey press as STOP. It does not record in
   Sidekick's history, because it is not a Sidekick task.
3. **The screenshot.** One display, the one under the cursor (the main display when the cursor is
   on none), captured with `screencapture` as JPEG and shrunk to a 2000 px long edge. A raw Retina
   frame is several megabytes; the shrunk one is a few hundred kilobytes, and every model downscales
   past this size anyway.
4. **The call.** `DoubleTapInference.draft` sends the screenshot and the entire knowledge base
   (README first, then every note in full, under a 600 KB ceiling) to the relay, Sentient's
   Cloudflare Worker. The Worker checks the caller's caps, builds the OpenAI request itself
   (`gpt-5.6-sol`, reasoning off, the prompt, `store: false`), adds Sentient's key, and streams
   the reply back. The screenshot is the first thing in the prompt, so every call is cold: no
   prefix cache can match a screen that differs on every press. A dev-only second route sends
   the same request straight to OpenAI with a key from Dev Tools.
5. **The verdict.** `NOT_A_MESSAGE`, tolerant of the decoration models add around it, becomes the
   notch aside "double tap in an email or message reply box". Anything else is the reply.
6. **The paste.** The reply goes on the pasteboard, one ⌘V is posted to the frontmost app, and the
   user's previous clipboard text is put back half a second later. Paste rather than keystrokes on
   purpose: in iMessage, WhatsApp, and Slack a typed Return sends, while a pasted newline is only a
   line break. Posting the key event rides Sentient's own Accessibility grant.
7. **The end.** The notch flourishes as any run does: ✓ "Reply pasted", "Stopped", or ✗ with the
   reason (no key, no vault, an HTTP error). A 30 s deadline cancels a run that never returns.

## The model, and why

Measured on 2026-09-19 with a real Gmail screenshot and an 88-note vault (about 18,400 input tokens
per press), all cold:

| Model | First text | Finished reply | Cost per press |
|---|---|---|---|
| gpt-5.6-luna, reasoning off | 0.9 to 1.6 s | 1.3 to 2.2 s | about 0.5 cents |
| gpt-5.6-sol, reasoning off | 1.2 to 1.4 s (one 5 s outlier) | 2.3 to 2.7 s | about 9 cents |
| gemini-3.8-flash, thinking low | 1.7 s | 1.7 s | about 1.4 cents |

The whole vault costs nothing measurable in latency next to the README alone, and the "fast"
service tier bought nothing, so neither is used. Sol was chosen for reply quality; luna and Gemini
were removed after the bake-off. The per-press cost is what OpenAI bills as a cache write, 1.25
times the listed input price, because a cold call writes the prefix cache every time.

The prompt opens and closes with a bold order to answer immediately, tells the model who the user
is (the person the vault describes, the "me" in the recipients), and forbids copying other replies
visible on screen.

## Rules and sharp edges

- **Cold on purpose.** Do not move the screenshot after the vault in the prompt to chase cache
  hits; presses are minutes apart and the cache expires in minutes, so the gain is illusory and
  it would make the latency depend on the previous press.
- **Never keystrokes.** The paste is the only safe insertion in chat apps; see step 6.
- **Only text is restored to the clipboard.** An image on the user's clipboard before a press is
  lost. Acceptable for now; noted.
- **The display choice is a proxy.** The display under the cursor stands in for keyboard focus;
  `screencapture -D` only guarantees its numbering matches `NSScreen` for the main display.
- **The vault path is `VaultGenerator.vaultRoot`.** No vault there means a ✗ "no knowledge base"
  caption, never a silent empty prompt.
- **Logs are numbers only.** Timings, token counts, byte sizes. The reply text is logged in DEBUG
  builds only.

## The relay: Sentient's key, the user's identity

Double Tap bypasses the FrontierRun seam that every other cloud call uses, because a `codex exec`
spawn costs seconds this feature cannot spend. The decision (2026-09-20) is that Sentient pays for
the model, through a relay it runs: a stateless Cloudflare Worker. The app never holds an OpenAI
key. What it holds instead is a **relay identity**: 32 random bytes minted once into the Keychain
(`doubletap.relay.identity`), sent as a bearer token. The Worker keeps a hash of it as the key for
that user's counters and stores nothing else; there are still no accounts.

What the relay enforces, per identity: 60 drafts an hour and 100 a day (config values on the
Worker). A global monthly ceiling exists as the kill switch against bulk-minted identities and
ships switched off. The prompt and every model setting live on the Worker, so the client can only
ever obtain Double Tap replies from it.

What this costs in feel: about 0.3 to 0.5 s over a direct call, measured; the Worker must hold the
whole body before forwarding it. What it costs in money: about 9 cents per admitted draft at sol's
rates, all of it Sentient's. The route switch and a direct-key fallback for testing live in Dev
Tools; the shipped default is the relay.

This is the first Sentient-funded inference in the product, and the first time raw screen content
transits a Sentient server, even though nothing is stored. The privacy copy and the Constitution
in the Claude context need to say so plainly before it ships to users.

## Related docs

- `Notch Magic/Documentation - Sidekick - General.md`: the coordinator, the hotkey monitor, the
  run model, adopted runs.
- `Notch Magic/Documentation - Sidekick - Notch Window & Visual.md`: the notch phases and the aside.
- `Vault/Documentation - Knowledge Base (Vault).md`: the vault Double Tap packs.
- `Views/Dev/Documentation - Dev Tools.md`: the switch, the key field, the timing readout.
