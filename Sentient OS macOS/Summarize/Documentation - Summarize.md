# Summarize

Summarize reads the active document, including accessible offscreen content, and turns it into a short, readable explanation. Open the notch and choose
**Summarize** on the left side of its bottom row, or finish an explicit spoken or typed request such
as “summarize this.” The result appears in a separate, selectable reading window. The global shortcut is `⌘,`
(`Command-Comma`, without Shift); it works without opening the notch first.

## Flow and ownership

`CommandCoordinator` remembers the active application/window and display before the notch takes focus.
`SummaryAccessibility` traverses AXChildren, including offscreen nodes, instead of visible children.
Chromium/Electron accessibility is enabled when needed. Browsers read the whole loaded page.
WhatsApp, Messages, Claude, ChatGPT/Codex and Slack use conversation-specific boundaries described below. Native PDFs whose local document URL is
exposed use PDFKit to include offscreen pages. Toolbars, menus and secure fields are excluded.
The traversal has time, depth, node, frontier and collected-byte bounds. Large documents retain the
opening, representative middle excerpts and ending within a conservative 26 KB UTF-8 text allowance.
The relay bounds all textual input, including instructions/metadata, below 30k tokens using a byte
upper bound. Loaded content is not the same as unloaded virtualized history or collapsed replies.

`SummaryCapture` asks for Accessibility when denied. It always attempts one window image alongside
the primary accessibility text, requiring Screen Recording. Capture starts in parallel with AX traversal
to minimize temporal drift. The image supplies diagrams, layout and visible text missing from AX.
The still is tied to the same application's window using its captured geometry and title; an unrelated
foreground app cannot obscure or replace it. Only a request without a window target uses the chosen display.
`SummaryWindowSelection` handles WindowServer-abbreviated titles and AX browser-name suffixes.
It requires a unique match, with matching geometry for abbreviated titles, so two maximized browser
windows cannot be confused. A non-permission image failure preserves readable AX text and continues
the summary; a missing image and missing text still fail. Permission failures and cancellation remain
explicit. The reader hides its pending-source badge when capture fails instead of claiming to be reading.
Debug preference `summary.disableScreenshots` disables image capture entirely for text-only acceptance;
an empty text-only capture fails instead of hiding an extraction problem with image inference.
It does not scroll, attach a browser debugger, require an extension, or read the knowledge base.

`CommandCoordinator` owns `SummarySessions`. Every activation creates a fresh `Summarize` request
and a separate window, including while earlier requests are still streaming. Completed windows stay
open so the user can switch tabs, press `⌘,` again and compare results. Each request captures promptly;
it does not wait for another request's inference to finish.

Each `Summarize` owns its source text/optional pixels, preference, stream, retry and panel. Retry reuses only that window's
snapshot. Closing a window cancels only its request, clears its image/text and removes it from the
collection. Sleep or leaving the active session closes all windows; reset/uninstall also dismiss the
whole collection. Relaunch waits while any summary is busy. Request IDs fence late callbacks within
each window, and responses can complete in any order without replacing another result.

New panels cascade within the chosen display and do not request keyboard focus, allowing the user to
keep switching tabs in the source app. Clicking a reader gives it normal text-selection and keyboard
controls; Escape or Command-W closes that reader. Capture excludes Sentient's transient panels even
when another Summary opens during capture, while ordinary Sentient windows remain valid content.

The reader has Copy and close controls. A quiet source chip beside **Summary** replaces the footer;
its tooltip retains the capture time and whether the source was excerpted. Text reads show
**Read offscreen text too** when the capture actually includes offscreen text, otherwise **Read text**.
A recognized YouTube video shows **Fetching video transcript…** during retrieval, then
**Fetched video transcript** only after the relay confirms it. The pending icon is a video icon;
only verified retrieval gets a checkmark. A narrow window uses the shorter **Transcript** chip.
Failed retrieval never reports a fetched transcript or leaves the badge claiming it is still fetching.
The panel keeps stable geometry while text arrives. `SummaryReader` uses one native TextKit document
for wrapping, scrolling and selection across paragraphs. Markdown horizontal rules render as thin
dividers that follow the reading width, including after a resize. Newly streamed lines fade in over 400 ms,
respecting Reduce Motion and leaving already-rendered text steady. Selection temporarily freezes displayed
updates. Its content is not added to the conversation or the shared Markdown cache. Copy uses the
complete current text. Interrupted responses retain readable partial text with an explicit error.

Accessibility is the primary permission; Screen Recording provides the accompanying visual context.
Both use the existing permission setup shell and live grant checks. Microphone permission
applies only to voice entry. There is no knowledge-analysis prerequisite or dependency on the selected
Sidekick provider. This read-only request has its own lifetime rather than occupying Sidekick's
computer-action lock.

## Inference and data

`SummarizeInference` sends bounded document text, source metadata, an accompanying JPEG and summary preference to `POST /v1/summarize` on
the covered relay. The relay pins GPT-6.1 Terra with Fast mode, low reasoning effort, streaming, and
`store: false`. It supplies the instructions and output bound. All captured content is source material, never instructions. Native YouTube URLs are canonicalized and
fetched through Supadata in `native` mode; no generated transcript fallback is permitted. Missing
transcripts fail explicitly. Only the canonical video URL goes to Supadata; the key stays in Worker secrets.
YouTube requests also keep the screenshot for visual context, but the native transcript is authoritative
for spoken content. Text-only requests remain supported for older clients and independent AX tests.
Combined requests reserve visual-token space by limiting textual instructions and source to 21 KB;
text-only requests retain the 29 KB textual bound. Both keep representative excerpts and endings.

`Cloud/ScreenRelay.swift` preserves the existing installation identity and endpoint preference keys.
`ScreenRelayResponse.swift` bounds and parses SSE, distinguishes interruption from completion, and
uses ephemeral URL sessions. The provider key remains in the Worker. Image and summary content are
not written to application logs, the relay counter store, knowledge, or chat history. Provider
processing and retention settings still apply; `store: false` is not a separate retention contract.

The shared summary prompt asks for a direct takeaway, plain language and selective Markdown bold for
key ideas, decisions, dates and short bullet labels. It adapts emphasis to articles, conversations,
videos and app records. Generic source preambles such as “In the available excerpts” are excluded;
specific coverage limits that affect meaning belong at the end. Normal summaries begin with a
one- or two-sentence **TL;DR:**, followed by a Markdown horizontal rule (`---`) and the fuller
summary. Genuinely short/simple material gets one concise summary without the label, divider or
duplicated longer section. No closing TL;DR is added. This applies to
accessible documents, screenshot fallbacks and native YouTube transcripts.

The relay emits `x-summary-source` and `x-summary-truncated` only after source retrieval and successful
upstream admission. `ScreenRelayResponse` exposes validated response headers to `SummarizeInference`,
which decodes only known source kinds. `Summarize` fences metadata callbacks by request ID just like text.

The deployment entry point, flags, shared limits and runtime requirements are described in
`HostedInference/README.md` at the repository root.

## Files

| File | Responsibility |
|---|---|
| `SummarySessions.swift` | Owns the open-window collection, fresh activations, aggregate busy state and dismiss-all |
| `Summarize.swift` | One request’s state, capture, retry, cancellation and panel ownership |
| `SummarizeInference.swift` | Image request and summary-specific response errors |
| `SummaryRequest.swift` | Explicit-request recognition; mentions, negation and unrelated tasks remain ordinary input |
| `SummaryWindowController.swift` | Display placement, dismissal, and session/display lifecycle |
| `SummaryView.swift` | Loading, result, copy, retry and permission presentation |
| `SummaryReader.swift` | Native scrolling text, also used for literal proofreading results |
| `../Views/ReadingPanel.swift` | Shared native reading-window shell and keyboard dismissal |
| `../Notch Magic/ScreenCapture.swift` | Stable-display, memory-only capture with overlay exclusions |

## Verification

`Scripts/test_summarize.py` exercises production matching, payload construction, streaming and
lifecycle logic against a loopback production relay with synthetic upstream responses.
`test_notch_action_routing.py` verifies coordinator routing. `test_summarize_ui.py` uses the isolated
signed-app fixture for layout, selection, scrolling, retry and dismissal, plus concurrent windows,
independent native text, cascading, preserved source focus and per-window/all-window cleanup.

`test_screen_actions_live.py --live` is an explicitly opted-in, billable check of the real Swift
clients and deployed relay. It uses only fixed synthetic text and a generated screen image. Live
provider checks complement native capture/UI tests; they do not replace multi-display acceptance.

### Live accessibility acceptance (November 6, 2026)

The signed-app audit (`test_summary_app_live.py --cases <JSON> --live`) independently verifies
required source phrases, URL, offscreen element counts, payload image presence and optional summary
facts. Its text-only mode intentionally disables screenshots so vision cannot hide missing AX data.
Edge, Chrome, Safari and Dia passed a 64-section article with offscreen final decisions, a nested
iframe and shadow DOM, then native YouTube transcript summaries. Claude's open conversation also
passed with offscreen text. These results cover the tested pages, not every site or browser.

A 114 KB single-paragraph fixture verifies that Chrome and Safari preserve the opening and final
decision within the text budget. A canvas-only fixture verifies selected-window capture when another
application covers the target, including image-only summarization with zero readable AX text.
Edge, Safari and Dia also passed selected-window screenshot capture while retaining their AX text and URL.

The deployed combined-input route passed a 25,938-byte AX excerpt with a screenshot and a native
YouTube transcript request with a screenshot. Firefox and Brave were not part of this live pass.


### Conversation boundaries

`SummaryConversation` selects only the active conversation subtree. WhatsApp uses
`ChatMessagesTableView` and message descriptions; Messages uses `TranscriptCollectionView` and
preserves sender/timestamp descriptions without duplicating its nested balloon text. Claude and
ChatGPT use their conversation containers, excluding sidebars, composers, hidden accessibility
headings and tool/status chrome. Capture begins at the first currently visible message and includes that entire message, even when its beginning is above the viewport, followed by subsequent loaded messages. Unread dividers do not override the visible starting point. Claude article boundaries, ChatGPT/Codex message headings, and Slack message containers preserve whole-message boundaries instead of trimming at the first visible text node.
Browser pages continue to use whole-page capture, even when scrolled.

Native WhatsApp and Messages virtualize their AX children. `SummaryConversationStore` optionally
fills in newer text from the same local chat, using existing file access, without scrolling or copying
a database. Connections are SQLite read-only with a 40 ms busy timeout and a 1.2 s query deadline.
Two distinct, unambiguous visible text anchors in chronological order must identify exactly one chat;
WhatsApp also requires the active chat name. iMessage additionally verifies the active chat name or contact identity; its candidate lookup is bounded to recent 50,000 row IDs. Ambiguous, unavailable or changed schemas retain the narrower AX capture. No other chat is added by the local-store reader. Large continuations retain their beginning and newest tail, report truncation,
and still pass through the shared text budget. The shared `MessageBody` decoder handles modern
Apple attributed message bodies. No conversation is marked read, edited or sent by these readers.

The relay is told to respect the visible/unread boundary even if the accompanying window screenshot
contains older text or other chat previews. It merges overlap between AX and local continuation.
`Scripts/test_summary_conversations.py` verifies scope, sidebars/drafts, clipped content, unread
markers, identity ambiguity, database immutability, and preservation of the newest tail. The opt-in
signed-app audit exercises current real windows both with screenshots disabled and through live
inference. Slack now has a dedicated message-container reader: it keeps sender/time, drops reactions and sidebar controls, and includes subsequent loaded messages. Its virtualized, unloaded history still needs a continuation source; capture is explicitly marked as excerpts. Discord remains unverified.
