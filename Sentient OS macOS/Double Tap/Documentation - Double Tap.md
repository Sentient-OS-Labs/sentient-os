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

Two seams live elsewhere. `CommandCoordinator` (Notch Magic/) owns the key listener and the
two-presses-in-a-window test, and adopts the run into the notch. `ScreenCapture` (Notch Magic/)
grew a single-display capture and a JPEG downscale for this feature. The switch, the OpenAI key
field, and the timing readout sit in Dev Tools (`Views/Dev/DevToolsView.swift`).

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
4. **The call.** `DoubleTapInference.draft` sends the screenshot, the instructions, and the entire
   knowledge base (README first, then every note in full, under a 600 KB ceiling) to `gpt-5.6-sol`
   with reasoning off, streamed, `store: false`. The screenshot is the first thing in the prompt,
   so every call is cold: no prefix cache can match a screen that differs on every press.
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

## Open decision: whose key

The call goes straight to OpenAI's API with a key from the Keychain, bypassing the FrontierRun seam
that every other cloud call uses, because a `codex exec` spawn costs seconds this feature cannot
spend. Today that key is entered in Dev Tools. Who supplies it in the shipped product is not yet
decided: the user's own key (keeps every invariant, user pays about 9 cents a press), a
Sentient-run proxy (a new server, and the first Sentient-funded inference in the product), or the
user's ChatGPT login through codex (no key, slower). Until it is decided, the controls stay in Dev
Tools and the architecture doc carries the entry.

## Related docs

- `Notch Magic/Documentation - Sidekick - General.md`: the coordinator, the hotkey monitor, the
  run model, adopted runs.
- `Notch Magic/Documentation - Sidekick - Notch Window & Visual.md`: the notch phases and the aside.
- `Vault/Documentation - Knowledge Base (Vault).md`: the vault Double Tap packs.
- `Views/Dev/Documentation - Dev Tools.md`: the switch, the key field, the timing readout.
