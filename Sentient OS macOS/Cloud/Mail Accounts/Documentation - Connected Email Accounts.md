# Connected email accounts

This feature records Gmail and Outlook addresses during disclosed connection setup in Sentient. It is separate
from message ingestion, anonymous diagnostics and the encrypted knowledge-base mirror. The address,
provider, engine and connection key are contact metadata, not proof of mailbox ownership.

## Collection and confirmation

`MailAccountProbe` starts the user's installed CLI in a temporary working directory with a sanitized
environment. It sends control-protocol requests only; no model turn or message-body read is started.

- Codex: `mcpServerStatus/list` returns tools whose `_meta.link_owner_profile.email` identifies the
  connected account. Only the reviewed Gmail and Outlook Email connector IDs are accepted. Results
  are deduplicated by link ID. Missing metadata fails visibly; there is no email-header inference.
- Claude: `mcp_status` locates the hosted Gmail and Microsoft 365 installations. Microsoft 365
  uses `get_me` with empty arguments, reading `mail`; `userPrincipalName` is not substituted.
  Gmail calls `search_threads` once with `query: "in:sent"`, `pageSize: 1` and
  `view: "THREAD_VIEW_METADATA_ONLY"`. `GmailSenderMetadata` reads senders only on messages labeled
  `SENT`, ignoring received replies and recipient addresses. It accepts the structured, JSON-string
  and MCP text-block response forms. One distinct normalized sender becomes the candidate; an
  empty, ambiguous, failed or malformed result skips address collection. It refuses inference
  if the result contains message bodies, subjects or snippets. It never falls back to a broader
  search, an LLM prompt or scraping conversation history.

Codex metadata and Claude's direct `mcp_call` control request are CLI-version-sensitive surfaces.
Protocol drift produces an actionable error rather than guessing an identity. Discovery has bounded
response size, pagination and time, and cancellation terminates its subprocess. No CLI credentials
or mailbox contents are copied to Supabase.

The Gmail connection flow discloses cloud storage before Done. A clear Claude Gmail result then
saves automatically with no address-confirmation step, including when the cloud sync must queue for
retry. Settings' explicit Add or update addresses action also uses this automatic path for detected
Gmail senders; unresolved peers are skipped. Missing or ambiguous results are skipped without an email-entry field. A connected
mailbox with no detectable address can still be selected as a knowledge source. If discovery finds no
connection, the connection popup returns to the picker without marking a new connection as linked.
Existing installations retain the initial storage disclosure; discovery alone does not silently
enroll them in storage.
Other connections and knowledge-source toggles are independent.

## Persistence and ownership

`MailAccountCloud` holds the local snapshot and Supabase Auth session in a dedicated, device-only
Keychain item. Anonymous Auth provides a unique authenticated owner without a login form. There is
no cross-device account merge and no association with the mirror secret or analytics identifier.
The first save creates the Auth identity; discovery alone does not.

Only `MailAccountCloudConfiguration`'s public project URL and publishable key are embedded. All
access is subject to database RLS. Never add a service-role key or database password to the app.

The onboarding source picker uses these same connection sheets. Lookup starts on **Done** after the
user has linked/selected their account on the provider's page; merely opening the picker does not run
it. Settings uses the same trigger. This is not a separate check on Start Analysis. Completing the explicit Gmail flow also records
that its storage disclosure was already shown, so a skipped address does not immediately reopen
the migration sheet on the home screen.

Saving one provider preserves records for other providers and engines. In a mixed result, detected
addresses can save while unresolved connection IDs retain any previously saved records. An entirely
skipped result does not call the cloud save path or create a cloud identity. Concurrent saves are
serialized into atomic cloud snapshots; revisions prevent a completed old request from clearing a
newer pending edit. Offline data remains pending in Keychain and retries on launch, foreground or the
Settings retry action. A pending save also retries in the background with backoff up to five minutes,
including while only the menu bar is open. Expired access tokens are refreshed and rotated credentials are persisted.
A rejected refresh credential is an error, never permission to silently mint a replacement owner.

Addresses are refreshed when the user confirms a connection or chooses Add or update addresses.
Disconnecting at the upstream provider does not automatically erase saved contact metadata. The
Settings delete action, Reset and Uninstall delete the remote identity and its records before
discarding the only credential that authorizes deletion; offline deletion remains retryable.

## Database

The project is `sentient-os-app-data` (`hjqedlalhfoxwehxhton`, us-west-2). The table
`public.connected_email_accounts` references `auth.users` with cascade deletion. It has:

- Enabled and forced RLS, with owner-scoped SELECT, INSERT, UPDATE and DELETE policies.
- No public/anon table grants. Authenticated clients cannot write owner IDs or server timestamps.
- A unique owner/engine/provider/connection key; addresses are not globally unique.
- Bounded, validated email/provider/source fields and a disclosure-version field.
- `sent_mail_metadata` provenance for the inferred Claude Gmail sender, restricted to that
  engine/provider pair. Profile reads remain `connector_profile`; legacy `user_entered` records remain readable,
  but current setup never asks the user to type an email address. A sending alias is not represented as a verified primary mailbox.

`sync_connected_email_accounts` is an invoker RPC, validates a maximum 32-entry snapshot, rejects
duplicates and unknown fields, and applies RLS inside one transaction. The parameterless
`delete_connected_email_identity` is a narrowly scoped definer RPC with an empty search path; it
deletes only `auth.uid()` when that user is anonymous. Database administrators still have privileged
access. The advisor's anonymous-user and self-deletion-definer warnings are expected, reviewed design
choices, not permission for unrestricted public access.

Apply checked-in changes with the Supabase CLI from the repository root:

```sh
supabase config diff --project-ref hjqedlalhfoxwehxhton --workdir .
supabase config push --project-ref hjqedlalhfoxwehxhton --workdir .
supabase db push --project-ref hjqedlalhfoxwehxhton --workdir . --dry-run
supabase db push --project-ref hjqedlalhfoxwehxhton --workdir .
```

The live HTTP isolation suite is `Scripts/test_mail_account_rls.py`. It uses only a publishable key
and two disposable anonymous identities, verifies cross-owner denial and atomicity, and removes its
test identities afterward. The temporary app acceptance harness additionally exercised the actual
Swift probe, Auth, snapshot, refresh, concurrency, offline-persistence and deletion paths. No test
records or acceptance credentials belong in production app configuration or version control.

Parser and flow-decision fixtures can be run without network or credentials:

```sh
xcrun --sdk macosx swiftc -target arm64-apple-macos15.0 -swift-version 5 \
  -parse-as-library "Sentient OS macOS/Cloud/Mail Accounts/MailAccount.swift" \
  "Sentient OS macOS/Cloud/Mail Accounts/GmailSenderMetadata.swift" \
  Scripts/test_gmail_sender_metadata.swift -o /tmp/sentient-gmail-sender-tests
/tmp/sentient-gmail-sender-tests
```
