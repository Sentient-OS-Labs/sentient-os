# Proofread

Select text, open the notch and choose Proofread, or press Command-Period.
The correction replaces the selection in place. No result popup and no Return key.

## External editor flow

1. Before the notch takes focus, passively bookmark the source editor and optional selected range through AX. Opening or dismissing Sidekick sends no keys and does not touch the clipboard.
2. Only after explicit Proofread, restore the bookmarked editor as needed, save clipboard formats, issue normal Command-C, read the new text, and restore the clipboard. Empty copies are never confused with old clipboard content.
3. Correct only the selected text through the existing relay.
4. For a notch invocation, return focus to the bookmarked editor and restore its selection when its AX range is available.
5. Copy again and require an exact text match. If the selection changed, stop without pasting.
6. Save the clipboard, put the correction on it, issue normal Command-V, allow the editor to consume it, and restore the clipboard if still owned.

AX provides a focus bookmark and optional range, not a requirement for complete document text,
settable values, text markers, or a particular rich-text implementation. The runtime capture uses
`captureByCopy`; the older AX capture/validate helpers remain for diagnostic fixtures only.
Normal Paste preserves the editor's insertion and Undo semantics. A dispatched paste is not claimed
as independently verified insertion in every app. No automatic second paste is attempted.
Secure AX fields are excluded. Copy is bounded to 500 ms and selected text to 12,000 UTF-8 bytes.
The original application must remain in front; new input during inference stops insertion.
Our own Copy event is accounted for before the inference-to-insertion activity check.

## Home

Home uses an owned draft snapshot, without system Copy/Paste. Its selected range (or whole draft
when there is no selection) is corrected only while its text and conversation generation still
match. Home and notch retain independent unsent drafts and share submitted conversation state.

## Inference and lifecycle

The existing text-only relay returns a strict corrected_text result. Boundary whitespace,
paragraph breaks, incomplete-response handling and cancellation remain unchanged.
Proofread excludes concurrent Sidekick and Double Tap insertion. Once Paste is posted, clipboard
cleanup finishes before the editing lock is released, including after cancellation.
Only selected text goes to inference; clipboard contents and AX context stay local.

## Checks

`test_proofread.py`: passive preparation versus explicit Copy, transport, parsing, clipboard formats, ownership and cancellation.
`test_proofread_focus.py`: separate native editor, panel handoff, normal Copy/Paste,
collapsed selection restoration, exact replacement and refusal of changed text.
`test_home_proofread_routing.py`: Home draft isolation and focus-loss routing.
`test_notch_action_routing.py`: coordinator button and shortcut paths.
