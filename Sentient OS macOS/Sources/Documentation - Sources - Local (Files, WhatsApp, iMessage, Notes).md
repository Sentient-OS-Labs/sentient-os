# Sources: the local readers (Sources/)

The four sources that are read straight off the Mac's disk: **Files**, **WhatsApp**, **iMessage**, and
**Apple Notes**. Plus the shared pieces every source uses (the value types, the persisted source
selection, the WAL-safe SQLite copy, chat windowing, and contact-name resolution). The two cloud
sources (Gmail, Calendar) have their own doc in this folder.

The three database sources need **Full Disk Access**; the Files source reads the standard folders and
any custom roots. All of it is on-device; nothing here touches the network.

## Files

| File | Job |
|---|---|
| `DataSource.swift` | The shared value types: `SourceKind` (file / whatsapp / imessage / notes / gmail / calendar), `Candidate` (a cheap, content-free work item), `Artifact` (a candidate plus its extracted text or image). |
| `SourceSelection.swift` | The ONE reader of the source-selection preferences and `CustomRoots` (persisted user-added folders). Settings, the home popover, onboarding, Dev Tools, and the 3 AM run all read the same keys. |
| `SQLiteDB.swift` | `walSafeCopy(of:)` and the small `SQLiteReader`. Live databases are open by their owning apps in WAL mode, so we never read them in place. |
| `ChatWindowing.swift` | Shared by WhatsApp and iMessage: `ChatMessage`, `ChatInfo`, the byte-budgeted window slicing, the prompt framing, and the limits. |
| `AddressBookNames.swift` | Raw iMessage handles (phones, emails) → contact names, read from the AddressBook SQLite stores (already covered by FDA; no Contacts-framework prompt). |
| `FilesSource.swift` | Folder walk with skip rules and caps, content extraction (PDF, Word, text, downsized images), and the `FileRoot` enum. |
| `WhatsAppSource.swift` | ChatStorage.sqlite reader: session whitelist, group naming, per-chat windows. |
| `iMessageSource.swift` | chat.db reader: the typedstream body decoder, hidden-chat filtering, per-chat windows. |
| `NotesSource.swift` | NoteStore.sqlite reader: gunzip + protobuf walk to the note text. |

The connectors that adapt these to the pipeline are in `Ingestion/Connectors/`.

## Shared machinery

**Selection (`SourceSelection`).** The preference keys are historical `dbg.*` names but they ARE the
production keys, persisted on user machines: `dbg.run.downloads` / `desktop` / `documents` (default on),
`dbg.run.notes` / `whatsapp` / `imessage` (default off), the chat pickers' `dbg.whatsapp.chats` /
`dbg.imessage.chats` (comma-separated ids), and the cloud pair `dbg.gmail.connected` + `dbg.run.gmail`
(same for calendar). Never rename them without a migration. `CustomRoots` stores user-added folders as
one newline-joined string under `files.customRoots` so any view can watch it with `@AppStorage`.
`SourceSelection.current(fdaGranted:)` builds the run's `[RunSource]`; `selectionCount` counts armed
selections for the shared **four-selection minimum** that onboarding's ready screen and Settings both
enforce (each folder, each chat source with chats picked, Notes, and each connected cloud source count
as one; cloud sources only count on the ChatGPT backend).

**WAL-safe copy (`SQLiteDB`).** Copy the database plus its `-wal` and `-shm` siblings into a fresh temp
directory, open the COPY read-write so SQLite replays the WAL, read, and delete the directory the moment
extraction is done. A plaintext copy of someone's messages must never linger. A `prepare` failure on our
static SQL means a schema change and emits the `db.schema_error` diagnostic.

**Chat windows (`ChatWindowing`).** The unit of analysis for chats is a **conversation window**: a
time-ordered slice of one chat, sized by a UTF-8 byte budget (`maxWindowBytes = 12,000`; a byte-level
tokenizer emits at most one token per byte, so bytes are a hard upper bound on tokens even for emoji
or CJK). One message is capped at 1,000 characters. The chat engine's KV cache is 16,384 tokens
(`kvCacheTokens`), and `clampToContext` is the backstop that trims a rendered window on a message
boundary so a chat prompt can never exceed it. Limits: the last **90 days** and the newest **100,000
messages** per connector, whichever cuts first. `format()` frames a window for the model with the chat
name, DM vs group, and the "you ("Me") sent N of M messages" participation line the group prompt relies
on. `groupName(of:)` names unnamed groups from their current members ("Alex, Sam & 2 others").

**Contact names (`AddressBookNames`).** One pass over `AddressBook-v22.abcddb` (the root store plus one
per synced account) builds a map keyed by lowercased email or the last 10 digits of a phone number
(chat.db stores E.164; the address book stores whatever the user typed).

## Files (`FilesSource`)

Reads a folder root (Downloads, Desktop, Documents, or a custom folder), keeps only whitelisted
extensions (`pdf doc docx md txt png jpg jpeg heic`), and extracts a bounded amount of content per type:
the first 3 pages of a PDF, Word text via `NSAttributedString` (best-effort), plain text capped at 8,000
characters, and images downsized to a 768 px JPEG for the vision model (Gemma 4 resizes to 768 anyway).

Items are keyed on **date added** (what Finder shows), future-clamped, never on modification time, so
edits are not reprocessed. Never Spotlight (silent failures).

Three free layers decide what never reaches the model, all from filesystem metadata:

1. **Subtree pruning** (`pruneReason`): `.noindex` names, dependency/build/dataset directory names, the `.metadata_never_index` marker, any `.git` (a survey of 38 repos found zero notes repos), known project manifests (`package.json`, `Cargo.toml`, `Makefile`, …), `.xcodeproj` / `.sln` bundles, code-density (≥10 extensioned entries and code or data/markup is the majority), and dataset folders (≥100 files, ≥90% one extension, ≥80% machine-generated names). Obsidian and Logseq vaults are always kept. Explicitly added custom roots are never themselves prune-checked (the escape hatch).
2. **Per-file rejects** (`fileRejectReason`), by name and size only: camera-roll photo names (`IMG_`, `PXL_`, `DSC`, …; screenshots are deliberately kept), lock/temp files (`~$`), boilerplate names (README, LICENSE, …), empty files, and files over ~100 MB (the hang guard).
3. **Caps** (`cappedNewestFirst`): a 1-year age cutoff on Downloads only, at most 300 files per directory, and the newest 1,000 per root. Do not lower the per-directory cap casually; a busy screenshots folder loses real keepers.

Walk bounds: max depth 3, symlinks never followed, plus `IterativeRun`'s 30 s extraction timeout.
`FileRoot.source` builds the correctly configured `FilesSource` for each root; use it rather than
constructing one by hand. Thresholds were tuned on real Macs but are judgment calls; tune with evidence.

## WhatsApp (`WhatsAppSource`)

Database: `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`
(plaintext, WAL). Message dates are seconds since 2001, exactly Swift's reference date. `isInstalled`
is a LaunchServices lookup on `net.whatsapp.WhatsApp` (no FDA needed) and hides the WhatsApp chip
everywhere when the app is not on the Mac.

- **Session whitelist:** `ZSESSIONTYPE IN (0, 1)` (DMs and real groups), which excludes broadcast lists, status, and community homes automatically. A second clause removes community *announcement* channels, which are stored as ordinary groups but share the community's exact name. The `IS NOT NULL` guards inside that clause are essential: SQL's `NOT IN` over a set containing a NULL hides every group.
- **Naming:** unnamed groups roll up from their *active* members; the saved contact name is often an empty string, so the profile push-name is the reliable fallback. `cleanName` rejects WhatsApp's opaque LID tokens (a single long or slashed token) so they never reach a summary; multi-word names are always real.
- **Windows:** one bucket per opted-in chat (`whatsapp:<jid>`), each window keyed by its last message row id, newest first. The message query filters to the opted-in sessions first so a busy un-opted chat cannot eat the budget.
- Diagnostics: installed-but-zero-sessions and opted-in-but-nothing-matched both emit structured events.

There is no separate WhatsApp Business Mac app; business accounts share the same database.

## iMessage (`iMessageSource`)

Database: `~/Library/Messages/chat.db`. Dates are nanoseconds since 2001.

- **Bodies live in `attributedBody`** for ~99% of modern rows (`text` is NULL). The decoder is a small heuristic, deliberately not a full typedstream parser: find the `NSString` / `NSMutableString` marker, skip 5 bytes, read a 1-byte length (or `0x81` plus 2 bytes little-endian), decode UTF-8. Measured at 99.97% on 12,017 real messages; a collapse under 50% (with a real sample) emits `imessage.decode.degraded`.
- **Filtering in SQL:** tapbacks (`associated_message_type != 0`) and system items (`item_type != 0`) are dropped, or every window fills with "Loved …" noise. Chats Messages itself hides are dropped too: `is_filtered` is a category code, not a bool (0 known sender, 1 unknown sender, 2 spam, 3+ the iOS SMS-filter category chats that iCloud syncs into chat.db but no Mac UI shows), so only `is_filtered <= 1` and `is_blackholed = 0` survive.
- **Names:** `chat.style` 43 = group, 45 = DM; the opt-in key is `chat.guid`. Sender handles resolve through `AddressBookNames`; unnamed groups get the participant roll-up. A DM whose handle resolves to no contact and has no display name is marked `isSaved = false`, and the shared `ChatPicker` hides those behind a default-off "Show unsaved numbers" checkbox (presentation only; an already-selected chat is never hidden).
- **Windows:** one bucket per opted-in chat (`imessage:<guid>`), keyed by the last ROWID.

## Apple Notes (`NotesSource`)

Database: `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`. Notes join
`ZICCLOUDSYNCINGOBJECT` (one giant table for every entity type) to `ZICNOTEDATA`. Locked
(`ZISPASSWORDPROTECTED`) and deleted (`ZMARKEDFORDELETION`) notes are skipped in SQL; the creation-date
column name varies by macOS version, hence the `COALESCE`.

- **The body is double-wrapped:** gzip outside (magic `1f 8b 08`), protobuf inside. `decodeBody` gunzips via the Compression framework, then walks the protobuf wire format down fields 2 → 3 → 2 with no schema. Fail-closed: anything undecodable is skipped. Measured at 100% on real notes; a real drop emits `notes.decode.degraded` (undownloaded iCloud notes are excluded from the denominator).
- **One note = one item**, through the file-flavoured triage prompt (a note is a document the user wrote). Newest 1,000 by creation date, no time floor (old notes are often the most valuable). Keyed on **creation date**, so an edited note is not re-summarized.
- One bucket, `notes`.

## Rules

- Never read a live database in place; always `walSafeCopy` and delete the copy immediately.
- Never log a chat JID, a chat GUID, or a file path in a line that ships in Release.
- The `dbg.*` preference keys are production keys; do not rename them.
- The date-added key for files and the creation-date key for notes are deliberate; do not switch either to modification time.

## Related docs

`Ingestion/Documentation - Ingestion Pipeline.md` (how these are driven), `Engine/Documentation - On-Device Engine & Triage.md` (the prompts they feed), `Sources/Documentation - Sources - Cloud (Gmail, Calendar).md`, `Views/Documentation - Views - Home, Processing & Shared UI.md` (`ChatPicker`, the source chips).
