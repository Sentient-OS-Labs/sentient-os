# Magic Reply: a reply in your voice

Double tap your Sidekick key, **right Command by default**, with a reply field focused. Sentient reads
what is on screen, draws on your knowledge and writing examples, and pastes an **unsent draft** for
you to review. No copying a conversation into a chat window and no explaining the background again.

A client asks for a project update. A friend asks about dinner. A colleague needs the detail you
already discussed elsewhere. Double Tap is designed for these everyday replies: the visible thread
supplies the immediate question, your knowledge supplies useful context, and your writing examples
help the reply sound like you. It should use supported facts, not invent an answer to fill a gap.

## Entry points and readiness

The interface calls this feature **Magic Reply**. Double-tap the configured Sidekick key, use
Magic Reply in the notch, or make an explicit reply request. The notch route releases its own
keyboard focus before starting the shared drafting run. Settings → Magic Reply contains the
provider, writing examples and instructions; Settings → Notch & Shortcuts changes the shared key.
The onboarding lesson demonstrates an unsent reply with fictional content and no provider call.

Direct drafting requires completed initial analysis or a readable, nonempty imported knowledge
note within the context budget. Writing samples alone do not satisfy readiness. This never marks
analysis as complete or changes source consent. Missing setup gets a bounded pointer-following
notice without capture or inference. Accessibility, Screen Recording and provider checks apply.

The agent-facing `magic_reply` tool uses the same inference engine but returns draft text with
`applied: false` and `sent: false`. The agent displays or inserts it through its ordinary verified
editing tools. Every route leaves sending to the user.

## Your drafting provider

Double Tap has its **own provider setting**, independent of Sidekick and proactive intelligence.
Open **Settings → Magic Reply** to choose the provider, model, custom reply instructions, and writing
examples.

To keep Double Tap responsive, the default route uses **GPT-6.1 Sol** through the OpenAI API with **Zero Data Retention**,
covered by Sentient for our first users. No API key is needed. A screenshot of the display under your
pointer, your knowledge base including selected one-time writing examples, and your instructions pass
through Sentient's relay to generate the draft. This is cloud drafting; the local understanding stage
has a different data path.

You can instead use your own OpenAI or OpenRouter API key, Ollama, LM Studio, or a compatible endpoint.
Custom endpoints support **Responses or Chat Completions**. Choose a model that can understand images
and handle the supplied context. When the endpoint and compatible model run on your Mac, drafting
stays on your Mac; hosted endpoints follow your chosen provider's processing settings.

API keys live in Keychain. The covered route uses a random installation credential for usage limits.
Responses requests set `store: false`; that request flag is distinct from the covered service's Zero
Data Retention arrangement. See the in-app privacy policy for the service's data controls.

## A one-time snapshot of your voice

`Vault/WritingStyle.swift` prepares `writingstyle.md` inside `~/Sentient OS - Knowledge Base/`.
It saves examples of your own sent messages only from explicitly selected one-to-one iMessage and
WhatsApp chats and enabled, connected supported sent-email sources. A connected account that is off
for analysis does not supply writing samples. The collector does not discover unrelated local
databases or Contacts; a cloud-only selection never requires Full Disk Access. Recipient labels come
from the selected source, with raw handles retained when no name is available. Apple Mail's local
analysis does not currently supply this writing-style collector.

Unavailable sources are omitted from the setup selection. No eligible sent examples leaves the
snapshot absent; automatic setup never publishes an empty file that would prevent later collection.
A read failure or changed selection never publishes a partial file. While no snapshot exists, a new
source/consent identity can trigger another idle attempt; Settings → Magic Reply → Collect examples
provides an explicit retry using only the currently selected, connected sources.

**Sentient does not continuously collect new writing-style examples.** If the file already exists,
setup leaves it alone, and knowledge updates preserve your edits. Use **Show writing examples in
Finder** in Settings → Magic Reply to inspect or edit the snapshot anytime. It is not listed as an
ordinary note in the Knowledge window's tree. Existing empty files are preserved too, because Sentient
cannot infer whether the user intentionally emptied them. Removing the file allows setup again.

Writing examples are optional: Double Tap can draft from the visible conversation, knowledge and
custom instructions when the snapshot is absent or empty. The hotkey never collects new sources on
demand. An existing unreadable or oversized snapshot still reports its own error rather than silently
changing or shortening user-authored examples.

The snapshot is included in Double Tap requests. It also belongs to the knowledge folder uploaded if
you enable optional cloud MCP sharing. Explicit custom reply instructions take priority over inferred
style; writing samples are examples of voice, not instructions or current facts.

## How a draft is made

1. The hotkey monitor recognizes two presses of the selected Sidekick key within 0.35 seconds.
   The first press waits for the double-tap window before opening Sidekick; the second starts drafting
   after initial analysis or with populated knowledge. Otherwise the caret swirl gathers and fades,
   followed by “Finish Sentient setup and analysis to use Double Tap.” beside the mouse for three
   seconds. The message follows the pointer across displays, never takes focus or intercepts clicks,
   and dismisses automatically. Reduce Motion skips the swirl. This path makes no capture or model
   request, and repeated taps cannot stack feedback or open Sidekick during it.
2. The app checks setup, Accessibility for paste, Screen Recording, and provider configuration.
3. `ScreenCapture.grabDisplayUnderCursor()` captures the display under the pointer as a temporary JPEG,
   bounded to a 2,000-pixel long edge. This is one display, not the all-display Sidekick capture.
4. `DoubleTapInference` packs the knowledge Markdown within a byte budget, reserving space for the
   complete writing snapshot. README comes first, followed by other notes in path order. Hidden files,
   symbolic links and paths outside the knowledge folder are excluded. An oversized snapshot fails
   with an explanation rather than silently dropping writing examples.
5. The chosen endpoint receives the instructions, packed context and image. Direct connections to
   the covered relay use the system curl over HTTP/2/TCP, with TLS verification, a 25-second bound,
   and temporary request files in an owner-only directory that is removed when the call finishes.
   This avoids intermittent QUIC upload stalls observed with fresh URLSession connections.
   Direct providers, local development relays and system-proxy routes retain URLSession. The prompt asks for a
   reply only when a suitable conversation and focused reply field are visible. `NOT_A_MESSAGE`
   shows “Couldn’t find a reply box. Use Magic Reply to respond to a message or email.” after
   the swirl fades. This uses the same three-second, pointer-following notice as setup guidance.
   The draft lock stays held until the notice dismisses, and cancellation dismisses it promptly.
6. The caret feedback animates while drafting. A successful reply is pasted with Command-V, never
   sent. The previous text clipboard value is restored after the paste delay only if the clipboard still belongs to that paste; this is not a general
   preservation guarantee for every clipboard format. Temporary screenshot files are removed.

A 30-second deadline bounds the operation. Only one Double Tap request runs at a time; it does not
occupy Sidekick's shared computer-task lock, so drafting can happen while another task is running.
The current interface uses feedback at the caret, not a separate notch task with a STOP button. Drafting stays busy through bounded paste cleanup, including cancellation, and excludes Proofread until that cleanup finishes.

## Implementation map

| File | Responsibility |
|---|---|
| `DoubleTap.swift` | Hotkey coordination, setup gates, screenshot, deadline, feedback and paste. |
| `DoubleTapInference.swift` | Context packing, prompt, streaming API calls, response validation and relay identity. |
| `DoubleTapKnowledge.swift` | Readiness from readable, nonempty imported notes without changing analysis history. |
| `DoubleTapSetupNotice.swift` | Three-second, click-through setup and reply-box explanations that follow the mouse. |
| `DoubleTapRelayTransport.swift` | Bounded HTTP/2 transport for direct covered-relay requests, with system-proxy fallback. |
| `DoubleTapProvider.swift` | Independent provider, endpoint, API format, model and Keychain preferences. |
| `WritingStyleSetupView.swift` | The setup surface when writing examples are needed. |
| `../Vault/WritingStyle.swift` | One-time sample collection and snapshot preservation. |
| `../Views/Settings/DoubleTapPane.swift` | Provider controls, reply instructions, privacy explanation and Finder access. |
| `../Views/Onboarding/OnboardingMagicReplyView.swift` | The introductory Magic Reply lesson. |

Provider/model defaults and context limits belong in the source rather than a dated benchmark table.
The relay owns the covered model choice. Text precedes the screenshot in requests; supported OpenAI
routes use the configured prompt-caching controls. Preserve this ordering when changing the payload.

## Related documentation

- [Sidekick](../Notch%20Magic/Documentation%20-%20Sidekick%20-%20General.md)
- [Knowledge base](../Vault/Documentation%20-%20Knowledge%20Base%20(Vault).md)
- [Optional sharing](../Cloud/Documentation%20-%20Cloud%20-%20MCP%20Mirror.md)
- [Settings and privacy copy](../Views/Settings/Documentation%20-%20Settings.md)
