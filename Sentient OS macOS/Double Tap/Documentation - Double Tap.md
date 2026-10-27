# Double Tap: a reply in your voice

Double tap your Sidekick key, **right Command by default**, with a reply field focused. Sentient reads
what is on screen, draws on your knowledge and writing examples, and pastes an **unsent draft** for
you to review. No copying a conversation into a chat window and no explaining the background again.

A client asks for a project update. A friend asks about dinner. A colleague needs the detail you
already discussed elsewhere. Double Tap is designed for these everyday replies: the visible thread
supplies the immediate question, your knowledge supplies useful context, and your writing examples
help the reply sound like you. It should use supported facts, not invent an answer to fill a gap.

## Finding Double Tap

Home keeps a **Double Tap** button beside Analysis. It opens a short lesson showing the currently
configured key; it does not capture or draft anything. Double Tap is ready after initial analysis or
when a populated knowledge base already exists, including one copied from another Mac. Without either,
the lesson explains setup and links to analysis progress. Once the analysis milestone is saved, a gentle ready
hint waits for the next visible Home visit and is acknowledged once per initial-analysis completion.
If the user leaves before seeing the full hint, it stays pending. The demonstration uses two small
key presses, with a static equivalent for Reduce Motion and Low Power Mode.

An imported vault belongs at `~/Sentient OS - Knowledge Base/`. A readable, nonempty Markdown note
within the draft size budget is enough; an empty folder or writing samples alone are not. Readiness
is checked on each gesture, and Home refreshes while visible, so importing does not require a restart.
This never marks analysis or personal setup as completed. Onboarding must still admit the user to Home,
and the normal Accessibility, Screen Recording and provider checks still apply.

## Your drafting provider

Double Tap has its **own provider setting**, independent of Sidekick and proactive intelligence.
Open **Settings → Double Tap** to choose the provider, model, custom reply instructions, and writing
examples.

To keep Double Tap responsive, the default route uses the OpenAI API with **Zero Data Retention**,
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
source/consent identity can trigger another idle attempt; Settings → Double Tap → Collect examples
provides an explicit retry using only the currently selected, connected sources.

**Sentient does not continuously collect new writing-style examples.** If the file already exists,
setup leaves it alone, and knowledge updates preserve your edits. Use **Show writing examples in
Finder** in Settings → Double Tap to inspect or edit the snapshot anytime. It is not listed as an
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
5. The chosen endpoint receives the instructions, packed context and image. The prompt asks for a
   reply only when a suitable conversation and focused reply field are visible. `NOT_A_MESSAGE`
   produces no paste.
6. The caret feedback animates while drafting. A successful reply is pasted with Command-V, never
   sent. The previous text clipboard value is restored after the paste delay; this is not a general
   preservation guarantee for every clipboard format. Temporary screenshot files are removed.

A 30-second deadline bounds the operation. Only one Double Tap request runs at a time; it does not
occupy Sidekick's shared computer-task lock, so drafting can happen while another task is running.
The current interface uses feedback at the caret, not a separate notch task with a STOP button.

## Implementation map

| File | Responsibility |
|---|---|
| `DoubleTap.swift` | Hotkey coordination, setup gates, screenshot, deadline, feedback and paste. |
| `DoubleTapInference.swift` | Context packing, prompt, streaming API calls, response validation and relay identity. |
| `DoubleTapKnowledge.swift` | Readiness from readable, nonempty imported notes without changing analysis history. |
| `DoubleTapSetupNotice.swift` | Three-second, click-through setup explanation that follows the mouse. |
| `DoubleTapProvider.swift` | Independent provider, endpoint, API format, model and Keychain preferences. |
| `WritingStyleSetupView.swift` | The setup surface when writing examples are needed. |
| `../Vault/WritingStyle.swift` | One-time sample collection and snapshot preservation. |
| `../Views/Settings/DoubleTapPane.swift` | Provider controls, reply instructions, privacy explanation and Finder access. |
| `../Views/Onboarding/OnboardingDoubleTapView.swift` | The introductory Double Tap lesson. |
| `../Views/HomeShortcuts.swift` | The ongoing Home affordance, current-key lesson, and one-shot ready hint. |

Provider/model defaults and context limits belong in the source rather than a dated benchmark table.
The relay owns the covered model choice. Text precedes the screenshot in requests; supported OpenAI
routes use the configured prompt-caching controls. Preserve this ordering when changing the payload.

## Related documentation

- [Sidekick](../Notch%20Magic/Documentation%20-%20Sidekick%20-%20General.md)
- [Knowledge base](../Vault/Documentation%20-%20Knowledge%20Base%20(Vault).md)
- [Optional sharing](../Cloud/Documentation%20-%20Cloud%20-%20MCP%20Mirror.md)
- [Settings and privacy copy](../Views/Settings/Documentation%20-%20Settings.md)
