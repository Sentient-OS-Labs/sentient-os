# WhatsApp Source (ChatStorage.sqlite)

Reads WhatsApp's local database on the Mac. **[MEASURED on 86,762 real messages.]** WhatsApp keeps its
history in plaintext SQLite, so the whole source is a local read — nothing leaves the device.

File: `Sources/WhatsAppSource.swift` · connector: `Ingestion/Connectors/ChatConnectors.swift`
(`WhatsAppConnector`) · shared chat machinery: `Sources/ChatWindowing.swift` (same as iMessage).

## The database

`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` — unencrypted,
WAL mode. Read the **WAL-safe way** (shared with every SQLite source): copy the DB **plus its `-wal`
and `-shm`** to a temp dir → open the copy read-only → read → **delete the copy immediately** (a
plaintext copy of the whole chat history must never linger). Requires Full Disk Access.

Message text is the plaintext `ZWAMESSAGE.ZTEXT`; the chat is `ZWACHATSESSION`. Epoch: `ZMESSAGEDATE`
is **seconds since 2001**, which is exactly Swift's reference date — used directly via
`Date(timeIntervalSinceReferenceDate:)`, no offset.

## Install detection

`WhatsAppSource.isInstalled` — a LaunchServices lookup
(`NSWorkspace.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp")`), keyed on the **same
bundle** the group-container path above assumes, so "installed" and "readable" never disagree. It only
asks LaunchServices whether the app exists, so it needs **no Full Disk Access** (unlike actually
reading the DB).

It's the single gate for **hiding WhatsApp in the connections UI when the app isn't on the Mac** —
there's nothing to read, nothing to offer:

- the source picker omits the WhatsApp chip, and `SourceSelection.current` won't arm WhatsApp from a
  stale pref after an uninstall;
- the home's Analysis popover drops the WhatsApp pill (`HomeSources.whatsappAvailable`, fed from
  `RootView`).

## The unit of analysis: a conversation window

Not one message — one **conversation window** (a time-ordered slice of a single chat, sized by a UTF-8
byte budget). The windowing, the per-message "you sent N of M" formatting, and the caps all live in
`ChatWindowing.swift`, shared with iMessage. One window = one `Artifact` = one Triage verdict through
the chat-flavored prompt (DM vs group). The model sees the chat name, DM-vs-group, and each message's
sender, with "Me" anchored to the user.

## The connector & incrementality

`WhatsAppConnector.buckets()` wraps `WhatsAppSource.eligibleWindows()`. **One bucket per chat**
(`"whatsapp:<jid>"`); each window is keyed by `ItemKey(rowID:)` = the last (max) message `Z_PK` in the
window (row ids are unique + monotonic, so no tiebreak), listed newest-first. Incrementality is the
standard per-bucket high-water mark held in `CycleStore` (a `BucketPointer`) and advanced by
`IterativeRun` — there is **no cursor object and no ledger**; the highest processed message `Z_PK`
per chat is the whole story.

**Opt-in per chat:** only the JIDs the picker selected are read (`chatJIDs`). The cap is spent only on
opted-in chats — the message query filters to the opted-in sessions *first* (`analyzedPKs`), so a busy
un-opted chat can't eat the budget.

**Caps:** newest `ChatWindowing.maxMessages` (100k) within a 90-day lookback floor
(`ChatWindowing.lookbackFloor`).

## Picking the right chats (the hardening)

`sessionFilter` is a **whitelist** — `ZSESSIONTYPE IN (0, 1)` (0 = DM, 1 = real group). That
auto-excludes broadcast lists (2), status (3), community homes (4), and anything WhatsApp invents next.

A second clause removes **community announcement channels**: they're stored as ordinary type-1 groups
but always wear the community's exact `ZPARTNERNAME` (a name-twin of the type-4 community home — the
only marker in this schema; no parent-JID column exists). Community *sub-groups* are indistinguishable
from normal groups and deliberately stay (they're real conversations, and the per-chat opt-in gates
them anyway).

⚠️ **Both `IS NOT NULL` guards in that `NOT IN` are load-bearing.** SQL's `NOT IN` over a set
containing a single NULL evaluates to NULL (not true) — one NULL and it would silently hide EVERY
group.

## Naming

- **Unnamed groups** roll up from their *current active* members (`ZWAGROUPMEMBER` where
  `ZISACTIVE = 1`, so a shrunk group is named after who's actually in it) — "Priya, Marco & 2
  others", the way WhatsApp itself does it. [MEASURED] the saved contact name (`ZCONTACTNAME`) is
  usually an empty *string*, not NULL, so the reliable source is the self-set profile push-name
  (`ZWAPROFILEPUSHNAME`, by member JID) — which is what WhatsApp's own chat list shows.
- **LID-blob guard:** WhatsApp stores an opaque base64-ish LID token as the "name" for some
  privacy-mode members — that must never reach a summary. A name with a space is always real (slashes
  and all — a saved contact like "Ravi Uncle 12/3B"); a single long or slashed token
  (`> 24` chars or containing `/`) is rejected as a blob. A chat we can't name shows a clean generic.

## WhatsApp Business

There is **no separate WhatsApp Business Mac app** — business accounts link into the same app and the
same `ChatStorage.sqlite`. Nothing to build; verify with a business-linked account during dogfood.

## Self-test

*(Self-test modes are scaffolding — `Self Tests - Temp/` is kept empty; recreate the harness per `Self-Testing (Eval Harness).md` first.)*

`SENTIENT_SELFTEST=whatsapp` dumps the windows the model would see (chats, sender labels, group
roll-ups) for eyeballing.
