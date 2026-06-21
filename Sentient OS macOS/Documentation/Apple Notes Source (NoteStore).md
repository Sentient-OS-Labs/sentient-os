# Apple Notes Source (NoteStore.sqlite)

`Sources/NotesSource.swift` — the reader over Apple Notes' local store. Simplest source
shape: one note = one Artifact, no windows, no picker (all notes in; the cap + triage filter).
Wrapped by `NotesConnector` (`Ingestion/Connectors/NotesConnector.swift`) into a single bucket for
the iterative pipeline. Needs Full Disk Access.

## The decode (the whole reason this file exists)

`ZICNOTEDATA.ZDATA` is double-wrapped: **gzip outside** (magic `1f 8b 08`), **protobuf inside**.

1. `gunzip(_:)` — validate magic, skip the header (incl. optional FLG fields), raw-DEFLATE
   inflate via the Compression framework (`COMPRESSION_ZLIB` = raw deflate; the gzip trailer
   past end-of-stream is ignored).
2. `firstMessage(field:in:)` — a minimal protobuf wire-format walker (varint +
   length-delimited; no schema, no library). Follow **fields 2 → 3 → 2**; the bytes there are
   the note text, UTF-8.

Fail-closed: undecodable → the note is skipped (never garbled text to the model).
[MEASURED] 100% decode: 249 notes in research, 87/87 live during this build. Rows with
NULL/non-gzip `ZDATA` exist (6/94 on the dev Mac — likely iCloud notes not downloaded
locally) — they're skipped and counted in the self-test.

## NoteStore facts

- **Path:** `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` via
  `SQLiteDB.walSafeCopy`.
- **Join:** `ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON o.ZNOTEDATA = d.Z_PK` —
  `ZICCLOUDSYNCINGOBJECT` is one giant table for all entity types; note rows are the ones
  with `ZNOTEDATA` set. Folder names: `o.ZFOLDER → (folder row).ZTITLE2`, fallback `"Notes"`
  (orphans exist).
- **Skip in SQL:** `ZISPASSWORDPROTECTED`, `ZMARKEDFORDELETION`.
- **Dates are seconds since 2001** (`+ 978307200` → Unix) — NOT ns like iMessage. Creation
  date column name varies by macOS version → `COALESCE(ZCREATIONDATE3, …2, …1, ZCREATIONDATE)`.
- **Limit:** newest **1,000** by that creation date (`ORDER BY created DESC LIMIT 1000`,
  `NotesSource.maxNotes`). No time floor — old notes are often the most knowledge-worthy.
- **Ordering key = creation date, NOT modification date.** Each note's `ItemKey` is
  `(creationDate, "notes:<uuid>")`, and the bucket's high-water mark advances by it. Creation date
  never moves, so an edited note is **NOT** re-summarized — a deliberate choice in `eligibleNotes()`
  (the id `notes:<ZIDENTIFIER>` is a stable UUID, used only as the tiebreak / `Candidate.id`).

## Triage routing

`Triage.prompt` routes both `.file` and `.notes` through the **file prompt** (a note is a document
the user wrote; the knowledge-base-worthiness framing fits). The model sees
`"Apple Notes · <folder> · <title>"` as the display path + the note text capped at 8k chars
(`maxContentChars`, same cap as files). No dedicated notes prompt until dumps prove verdicts need one.

## Self-tests (`Self Tests - Temp/`, need FDA on the spawning terminal)

- `SENTIENT_SELFTEST=notesdecode` — decode-rate stats on the real store (no model, no content).
- `SENTIENT_SELFTEST=notes` — full dump through the model (`SENTIENT_SELFTEST_N` to limit).
