# Proofread

Select text in an editor, open the notch, and choose **Proofread** on the right side of the bottom row.
The global shortcut is `⌘.` (`Command-Period`, without Shift). It captures the active
selection without opening the notch or moving focus. An explicit voice or typed request such as
“proofread this” uses the same captured selection.
Proofread corrects clear writing errors while preserving meaning, language, tone and paragraph breaks.
A completed correction replaces the original selection when the target can still be verified.

## Capture before focus

`Proofread.prepareSelection` records the originating application before the notch becomes key.
Accessibility IPC runs off-main with bounded timeouts. A short, read-only hierarchy initialization
supports browser engines that publish their focused text field lazily. The notch waits for capture
before accepting keyboard focus. Input or application changes during capture invalidate the snapshot
so a delayed completion cannot steal focus.

A snapshot retains the selected text, its UTF-16 range, the element/window identity, and a bounded
local field value for later comparison. Secure fields are excluded. Only the selected text is sent
to inference; surrounding field content stays local. No arbitrary clipboard contents are treated as
a selection. Empty, unreadable and oversized selections receive an explanation without inference.

## Complete correction, then guarded replacement

The relay returns a strict `corrected_text` object. The client requires a complete provider response,
validates its shape and size, restores the selection's boundary whitespace, and preserves line-break
structure. Partial responses, refusals and malformed results cannot edit the document. An unchanged
result produces “Looks good” without creating an edit.

Before insertion, `ProofreadSelection` rechecks the foreground application, focused element, window,
selection range, literal UTF-16 field value, formatting suitability, and input activity. Unicode
canonical equivalence is not sufficient when validating offsets. New typing, clicking, scrolling,
window closure or changed text causes a corrected-copy fallback.

Supported editable fields use normal paste semantics, followed by a bounded read-back of the field.
The expected value includes the untouched text outside the selection. A posted key event alone is
not success. An uncertain result is never pasted again automatically. Read-only, mixed-format,
linked/attached or otherwise unsupported selections can produce a corrected copy instead.

The clipboard snapshot preserves materialized formats within a size bound and is restored only
while its change count still belongs to the operation. A newer user copy wins. No Return key is sent.
Native editor and WebKit textarea acceptance cover replacement and one-step Undo; editor capabilities
are checked at runtime rather than assuming universal compatibility.

Proofread excludes concurrent Sidekick actions and Double Tap insertion. Cancellation invalidates
late model callbacks. Once a paste has been posted, the editing gate remains held until bounded
verification and clipboard cleanup finish. Double Tap likewise retains its observable drafting task
through its paste cleanup. Closing result panels, reset and uninstall release ephemeral results.

## Voice, inference and privacy

Recognition happens once, after dictation finalizes. Bare commands and explicit requests are accepted;
mentions, negation, quoted commands and compound tasks remain ordinary Sidekick input. With no
selection, the user is asked to select text. There is no ambient microphone listener or automatic
proofreading of arbitrary dictated passages.

`POST /v1/proofread` receives only selected text. The relay pins GPT-6 Luna with Fast mode, low reasoning
effort, a strict response schema, output bounds and `store: false`. It treats the selection as data,
never as instructions to perform actions. The provider key remains server-side. Accessibility is
required for selection and insertion; Screen Recording and knowledge analysis are not prerequisites.
Microphone access applies only to voice entry. Missing Accessibility opens the shared
`QuickActionPermissionView`, using the same one-time setup shell, glow and Grant row as the other
permission windows. Screen Recording is omitted. Grant moves the window aside and opens the
draggable Sentient app guide. The view refreshes real permission state and enables Done only while
access is granted. Done closes setup; the user selects their text and invokes Proofread again.
The guide does not resume an old selection or treat a completed drag as permission.

Snapshots and corrections are held in memory, not saved into knowledge or conversation history.
OpenAI's processing/retention settings apply. Shared transport and installation identity live in
`Cloud/ScreenRelay.swift` and `ScreenRelayResponse.swift`; deployment details are in the repository's
`HostedInference/README.md`.

## Files and checks

| File | Responsibility |
|---|---|
| `Proofread.swift` | Snapshot preparation, one request, cancellation and editing lifetime |
| `ProofreadSelection.swift` | Accessibility capture, validation, paste, read-back and clipboard ownership |
| `ProofreadInference.swift` | Text-only request, strict decoding and structural preservation |
| `ProofreadRequest.swift` | Explicit command recognition |
| `ProofreadResultPanel.swift` | Literal, selectable corrected-copy and permission fallback |

`Scripts/test_proofread.py` covers real client transport against a local production relay, decoding,
Unicode, clipboard ownership and operation lifecycle with synthetic collaborators.
`test_notch_action_routing.py` checks the actual coordinator entry points.
`test_text_edit_overlap.py` covers Double Tap's paste-settlement exclusion and clipboard updates.
`test_proofread_ui.py` runs the signed app with disposable native and WebKit editors, verifies capture
before notch focus, replacement, Undo, formatting fallback, and captures the actual views.

`test_screen_actions_live.py --live` sends four fixed synthetic requests through the real Swift clients
and deployed relay. It requires explicit live-test intent, uses an isolated installation identity,
and writes receipts without reading the user's Keychain or sending real screen/document content.
