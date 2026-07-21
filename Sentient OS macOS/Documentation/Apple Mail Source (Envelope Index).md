# Apple Mail Source (Envelope Index)

`Sources/AppleMailSource.swift` — the reader over Apple Mail's local store. One email = one
Artifact, no windows, no picker (all non-deleted, non-Trash/Junk mail in; the cap + triage
filter). Wrapped by `MailConnector` (`Ingestion/Connectors/MailConnector.swift`) into a single
bucket for the iterative pipeline. Needs Full Disk Access.

This is the **on-device** email source — unlike Gmail/Calendar (which ride the Codex cloud
connector because there's no local store), Mail keeps everything on disk, so it's fully
privacy-first: no cloud, no account-linking sheet, just a source chip behind the same FDA gate as
Notes/iMessage/WhatsApp.

## The body decode (why `EMLXParser.swift` exists)

The Envelope Index is an **index**: sender, subject, date, mailbox, flags — but NOT the body. The
body lives in one `.emlx` file per message under the mailbox directory. `.emlx` is a three-part
format (reverse-engineered; corroborated by the Library of Congress format description
[fdd000615](https://www.loc.gov/preservation/digital/formats//fdd/fdd000615.shtml) and the PyPI
`emlx` package):

1. **Bytecount** — the first line is a decimal ASCII count of the message bytes. This makes
   extraction UNAMBIGUOUS: read the first line, take exactly that many bytes — no need to hunt for
   the plist marker (which would be ambiguous if a body itself contained `<?xml`).
2. **MIME message** — the full RFC 5322 message (headers + body + attachments).
3. **plist trailer** — Apple's metadata (`flags`, `subject`, `remote-id`, …). We don't need it.

`EMLXParser.plainText(fromMIME:)` walks the MIME tree: `multipart/alternative` (prefers
`text/plain`, falls back to de-tagged `text/html`), `multipart/mixed` (skips attachment parts),
decodes `quoted-printable` / `base64` / `7bit`/`8bit`, handles common charsets, decodes RFC 2047
encoded-word headers, unfolds folded headers, strips HTML tags + entities, and removes zero-width
tracking characters. Body capped at 6k chars.

**Fail-closed throughout:** any decode failure → nil body → the model judges from envelope
metadata alone (the same signal the Gmail connector works from). This mirrors how NotesSource
handles undownloaded iCloud notes — a missing body is a graceful degrade, never garbled input.

[MEASURED] on a live V10 store (macOS 27, an Exchange/EWS account): **10/10** recent Inbox
messages extracted clean bodies (Cloudflare, GitHub PR notifications, Claude Team, AppleSeed).
11/11 synthetic `.emlx` format tests pass (plain, QP, base64, both multipart shapes, HTML detag,
folded headers, entities, fail-closed truncation).

## The message → `.emlx` mapping (the hard part)

The on-disk layout nests under per-account UUID directories with per-mailbox sub-UUIDs and optional
sharding (`Data/Messages/` or `Data/{N}/{N}/Messages/`) — none of which are in the database. Rather
than hardcode that fragile path math, `buildEMLXIndex()` walks the store tree **once per run** to
build a `ROWID → [.emlx path]` index, then each message resolves its body by dict lookup. The key
fact: **the `.emlx` filename IS `messages.ROWID`** (verified: ROWID 33249 → `…/33249.emlx`). A
ROWID can have both a full `.emlx` and a `.partial.emlx` (attachments split off); the full one wins.

## Envelope Index facts — V10 (verified live 2026-07-20)

⚠️ The schema has drifted hard from the V2–V7 era most reverse-engineering docs describe. These are
measured on a live V10 store, NOT assumed:

- **Path:** `~/Library/Mail/V{N}/MailData/Envelope Index` (glob `V*`, highest version) via
  `SQLiteDB.walSafeCopy`. Store root (for the `.emlx` walk) = `~/Library/Mail/V{N}`.
- **No `uid` column.** Exchange/EWS accounts store a base64 `remote_id`; IMAP a numeric
  `remote_id`. Neither maps to the `.emlx` filename. **`messages.ROWID` is the join key** — it's
  the `.emlx` filename itself.
- **Sender join is DIRECT:** `messages.sender → addresses.ROWID`. The `senders` /
  `sender_addresses` tables exist but are a separate reputation/bucketing system, not the FK.
  `addresses` has `address` (email) + `comment` (display name).
- **Dedicated boolean columns** `read` / `flagged` / `deleted` (0/1) — NOT the jwz bit-flag
  layout from the `.emlx` plist era. The `flags` column still exists but its bits don't match the
  old spec. Deleted rows are filtered in SQL (`WHERE m.deleted = 0`).
- **Dates are Unix epoch seconds** (NOT Apple's 2001-01-01 reference date).
  `date_received = 1784591689` → 2026-07-20. Using `timeIntervalSinceReferenceDate` would yield
  2057.
- **Three URL schemes:** `ews://`, `imap://`, `local://`. The display name is the URL's last path
  component, percent-decoded. EWS names its junk folder **"Junk Email"** and trash **"Deleted
  Items"** — the exclude set covers both the IMAP and EWS naming.
- **Subjects:** `messages.subject → subjects.ROWID → subjects.subject`.

## Triage routing

`Triage.prompt` routes `.appleMail` through a dedicated **mail prompt** (`mailPrompt`): ruthless
junk-default (newsletters, marketing, OTP/2FA, automated notifications, system alerts), explicit
keeper guidance (real asks, deadlines, bookings, personal/financial/work matters), third-person
attribution, and a rule that quoted-reply history (`>` lines) is CONTEXT, not new facts about the
user. The model sees the envelope metadata plus the body when it was recovered — and is told to
fall back to the envelope alone when no body is shown.

## Incrementality

One `"mail"` bucket; each email keyed `(receivedDate, "mail:<rowid>")`, so a re-delivered message
is NOT re-summarized. High-water mark in CycleStore, advanced by IterativeRun (the connector is
pointer-dumb like every other).

## Follow-ups

- **User-configurable filters** — "ignore everything from X / matching Y" (a `CustomInstructions`
  hook into the mail prompt). Not built; the model's junk-default handles the common cases today.
- **Per-account / per-mailbox opt-in** — a picker like the chat sources, instead of all-or-nothing.
