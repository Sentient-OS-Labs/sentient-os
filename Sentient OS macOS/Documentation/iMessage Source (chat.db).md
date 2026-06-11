# iMessage Source (chat.db)

`Sources/iMessageSource.swift` — the `DataSource` over the Mac's iMessage store. Same shape as
WhatsApp: WAL-safe copy → extract → delete, conversation windows, per-chat opt-in, group/DM
triage routing. Needs Full Disk Access.

## The pieces

| File | Job |
|---|---|
| `Sources/iMessageSource.swift` | The source: `listChats()` → picker rows · `scan()` → windowed Candidates · the typedstream decoder |
| `Sources/ChatWindowing.swift` | Shared chat machinery (WhatsApp + iMessage): `ChatMessage`, `ChatInfo`, byte-budget `windows()`, `format()`, the connector limits |
| `Sources/AddressBookNames.swift` | Raw handles (`+1415…` / emails) → contact names, read straight from the AddressBook SQLite stores (FDA covers them — deliberately **no** Contacts-framework permission prompt) |
| `Views/ChatPicker.swift` | The shared opt-in sheet (was `WhatsAppChatPicker`); takes a source name + a `listChats` loader |

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
- **Limits (TODO plan):** 90-day floor AND newest-200k cap per connector, both in SQL — inner
  `ORDER BY date DESC LIMIT` subquery applies the cap across all chats, outer ORDER restores
  per-chat ascending iteration.

## Dedup / cursor

v1 matches WhatsApp: ledger-based dedup via stable window ids
(`imessage:c<chatROWID>:<firstROWID>-<lastROWID>`, signature = message count). A ROWID cursor +
active-tail hold-back is the Phase-4 (scheduler) hardening for both chat sources.

## Self-tests (`Self Tests - Temp/`, all need FDA on the *spawning* terminal)

- `SENTIENT_SELFTEST=imdecode` — decode-rate stats on the real chat.db (no model, no content
  printed; rows with both `text` and blob act as ground truth).
- `SENTIENT_SELFTEST=imchats` — picker enumeration + name resolution sanity.
- `SENTIENT_SELFTEST=imessage` — full window dump through the model
  (`SENTIENT_SELFTEST_CHATS="name|name"` to filter).
