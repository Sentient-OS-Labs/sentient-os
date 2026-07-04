# iMessage Source (chat.db)

`Sources/iMessageSource.swift` — the reader over the Mac's iMessage store. Same shape as
WhatsApp: WAL-safe copy → extract → delete, conversation windows, per-chat opt-in, group/DM
triage routing. Wrapped by `iMessageConnector` (`Ingestion/Connectors/ChatConnectors.swift`) for
the iterative pipeline. Needs Full Disk Access.

## The pieces

| File | Job |
|---|---|
| `Sources/iMessageSource.swift` | The source: `listChats()` → picker rows · `eligibleWindows()` → windowed Candidates, one `Bucket` per chat · the typedstream decoder |
| `Ingestion/Connectors/ChatConnectors.swift` | `iMessageConnector` (+ `WhatsAppConnector`): wraps `eligibleWindows()` for the `Connector` protocol; `load()` returns the window text |
| `Sources/ChatWindowing.swift` | Shared chat machinery (WhatsApp + iMessage): `ChatMessage`, `ChatInfo`, byte-budget `windows()`, `format()`, the connector limits |
| `Sources/AddressBookNames.swift` | Raw handles (`+1415…` / emails) → contact names, read straight from the AddressBook SQLite stores (FDA covers them — deliberately **no** Contacts-framework permission prompt) |
| `Views/ChatPicker.swift` | The shared opt-in sheet; takes a source name + a `listChats` loader. Soft-hides unsaved-number DMs (below) behind a default-off "Show unsaved numbers" checkbox |

## chat.db facts (the ones that bite)

- **Path:** `~/Library/Messages/chat.db`. Read via `SQLiteDB.walSafeCopy` like every DB source.
- **~99% of modern rows have `text = NULL`** — the body lives in `attributedBody` as an Apple
  typedstream blob. Decoder = the proven `imessage_tools` heuristic ([MEASURED] 99.97% on 12,017
  real messages): find `NSString`/`NSMutableString`, skip 5 bytes, length = 1 byte or `0x81` +
  2-byte LE, UTF-8. Deliberately NOT a full typedstream parser — don't overbuild it.
- **Dates are ns since 2001-01-01:** `date/1e9 + 978307200` → Unix. (Pre-2017 rows used seconds;
  unreachable inside the 90-day lookback, so unhandled on purpose.)
- **Tapbacks are message rows** (`associated_message_type` 2000-range) — filtered in SQL or every
  window fills with `Loved "…"` noise. System events (renames, etc.) = `item_type != 0`, also filtered.
- **Group vs DM:** `chat.style` 43 = group, 45 = DM. Opt-in key = `chat.guid` (stable).
  Sender per message via `handle.id` (E.164 phone or email — chat.db stores **no names**, hence
  AddressBookNames). Unnamed groups get a participant roll-up name ("Alex, Sam & 2 others").
- **Hidden chats: `chat.is_filtered` is a category code, NOT a bool** — 0 = known sender,
  1 = unknown sender (both shown in Messages' main list), 2 = Spam, 3+ = the iOS SMS-filter
  category chats (Promotions / Transactions + Finance/Orders/Reminders subtypes; the category is
  baked into `chat_identifier` as a suffix — `56249(smsfp)`, `53849(smsft_fi)` — one chat row per
  sender-category). iOS 26 rolled those folders out to everyone (not just India SIMs), and Messages
  in iCloud syncs the rows into the Mac's chat.db even though **no Mac UI ever shows them**.
  `chats()` therefore keeps only `is_filtered <= 1` (+ `is_blackholed = 0` defensively) — the
  iMessage twin of WhatsApp's `ZSESSIONTYPE` whitelist. Without it, OTP/promo shortcodes flood the
  picker and the pipeline. [MEASURED on a real dual-SIM DB: 749 chat rows, only 164 Messages-visible;
  the picker collapsed 106 → 45 active chats, matching the Messages sidebar exactly.]
- **Unsaved numbers are a second, softer tier** (survive the guard — Messages shows them — but are
  rarely worth analyzing): a DM whose handle resolves to no contact AND has no explicit
  `display_name` gets `ChatInfo.isSaved = false` (groups are always "saved" — deliberate). The
  picker hides those rows behind its default-off "Show unsaved numbers" checkbox; an already-
  selected chat is never hidden, and "All DMs" only sweeps the visible list. Data still flows if
  opted in — this is picker presentation, not a pipeline filter. WhatsApp never sets the flag
  (its names come from the DB), so the checkbox simply never appears there. Note Siri's
  "Maybe: …" names live outside the AddressBook stores → those count as unsaved.
- **Limits (`ChatWindowing`):** 90-day floor AND newest-100k cap, both in SQL — an inner subquery
  filters to the opted-in chats, applies `WHERE date >= floor`, then `ORDER BY date DESC LIMIT
  100000` to cap across them; the outer `ORDER BY chat_id, ROWID` restores per-chat ascending
  iteration. Spending the budget only on analyzed chats is deliberate (`ChatWindowing.maxMessages`,
  `ChatWindowing.lookbackDays`).

## Incrementality (the per-chat high-water mark)

`eligibleWindows()` returns one `Bucket` per chat (`"imessage:<guid>"`), each window an item keyed
by its last (max) ROWID (`ItemKey(rowID:)` — ROWIDs are unique and monotonic, so no tiebreak),
newest-first. There is NO ledger and NO cursor object: `CycleStore` keeps a single high-water mark
per bucket, and `IterativeRun` decides new-vs-done purely from it (everything past the mark is new;
the mark climbs as windows process). The window id `imessage:c<chatROWID>:<firstROWID>-<lastROWID>`
survives only as a stable `Candidate.id`. The `cursorKey`/`cursorValue` the source still sets are
vestigial — nothing reads them.

## Self-tests (recreate per `Self-Testing (Eval Harness).md` — `Self Tests - Temp/` is kept empty; all need FDA on the *spawning* terminal)

- `SENTIENT_SELFTEST=imdecode` — decode-rate stats on the real chat.db (no model, no content
  printed; rows with both `text` and blob act as ground truth).
- `SENTIENT_SELFTEST=imchats` — picker enumeration + name resolution sanity.
- `SENTIENT_SELFTEST=imessage` — full window dump through the model
  (`SENTIENT_SELFTEST_CHATS="name|name"` to filter).
