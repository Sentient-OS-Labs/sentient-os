# Double Tap: a reply in your voice

Double tap your Sidekick key, **right Command by default**, with a reply field focused. Sentient reads
what is on screen, draws on your knowledge and writing examples, and pastes an **unsent draft** for
you to review. No copying a conversation into a chat window and no explaining the background again.

A client asks for a project update. A friend asks about dinner. A colleague needs the detail you
already discussed elsewhere. Double Tap is designed for these everyday replies: the visible thread
supplies the immediate question, your knowledge supplies useful context, and your writing examples
help the reply sound like you. It should use supported facts, not invent an answer to fill a gap.

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
It saves selected examples of your own sent messages from available one-to-one iMessage and WhatsApp
conversations and supported connected sent email, with recipient or conversation context to help
match your tone. This setup is separate from the chats selected for regular knowledge analysis.
Apple Mail's local analysis does not currently supply this writing-style collector.

**Sentient does not continuously collect new writing-style examples.** If the file already exists,
setup leaves it alone, and knowledge updates preserve your edits. Use **Show writing examples in
Finder** in Settings → Double Tap to inspect or edit the snapshot anytime. It is not listed as an
ordinary note in the Knowledge window's tree. Removing the file can trigger setup again.

The snapshot is included in Double Tap requests. It also belongs to the knowledge folder uploaded if
you enable optional cloud MCP sharing. Explicit custom reply instructions take priority over inferred
style; writing samples are examples of voice, not instructions or current facts.

## How a draft is made

1. The hotkey monitor recognizes two presses of the selected Sidekick key within 0.35 seconds.
   The first press waits for the double-tap window before opening Sidekick; the second starts drafting.
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
| `DoubleTapProvider.swift` | Independent provider, endpoint, API format, model and Keychain preferences. |
| `WritingStyleSetupView.swift` | The setup surface when writing examples are needed. |
| `../Vault/WritingStyle.swift` | One-time sample collection and snapshot preservation. |
| `../Views/Settings/DoubleTapPane.swift` | Provider controls, reply instructions, privacy explanation and Finder access. |
| `../Views/Onboarding/OnboardingDoubleTapView.swift` | The introductory Double Tap lesson. |

Provider/model defaults and context limits belong in the source rather than a dated benchmark table.
The relay owns the covered model choice. Text precedes the screenshot in requests; supported OpenAI
routes use the configured prompt-caching controls. Preserve this ordering when changing the payload.

## Related documentation

- [Sidekick](../Notch%20Magic/Documentation%20-%20Sidekick%20-%20General.md)
- [Knowledge base](../Vault/Documentation%20-%20Knowledge%20Base%20(Vault).md)
- [Optional sharing](../Cloud/Documentation%20-%20Cloud%20-%20MCP%20Mirror.md)
- [Settings and privacy copy](../Views/Settings/Documentation%20-%20Settings.md)
