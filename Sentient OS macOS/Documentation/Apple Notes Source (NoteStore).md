# Apple Notes Source (NoteStore.sqlite)

`Sources/NotesSource.swift` — the `DataSource` over Apple Notes' local store. Simplest source
shape: one note = one Artifact, no windows, no picker (all notes in; the cap + triage filter).
Needs Full Disk Access.

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
- **Limit:** newest **1,000** by `ZMODIFICATIONDATE1` (TODO-plan cap). No time floor — old
  notes are often the most vault-worthy.
- **Reprocess-on-edit:** id = `ZIDENTIFIER` (stable UUID), signature = modification date —
  an edited note changes signature and re-enters the pipeline (the Files `size:mtime` pattern).

## Triage routing

`Triage.prompt` routes `.notes` through the **file prompt** (a note is a document the user
wrote; vault-worthiness framing fits). Model sees `"Apple Notes · <folder> · <title>"` +
text capped at 8k chars (same cap as files). No dedicated notes prompt until dumps prove
verdicts need one.

## Self-tests (`Self Tests - Temp/`, need FDA on the spawning terminal)

- `SENTIENT_SELFTEST=notesdecode` — decode-rate stats on the real store (no model, no content).
- `SENTIENT_SELFTEST=notes` — full dump through the model (`SENTIENT_SELFTEST_N` to limit).
