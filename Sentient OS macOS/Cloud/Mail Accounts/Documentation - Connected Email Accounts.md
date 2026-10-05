# Connected email: a direct line to the founders

When a user finishes connecting Gmail or Outlook through a supported AI account, Sentient can save
their email address so the founders can occasionally reach out to a small sample of users to ask for
feedback. We do not collect their knowledge base or task content for product analytics. Asking
people directly is how we learn what they use Sentient for. Any feedback outreach will include a way
to opt out.

**For this feedback list, we collect the email address and nothing else, ever.** The Supabase contact
table contains one column: `email`. It has no connector, account owner, installation ID, timestamps,
message content, mailbox credentials, or usage history. Discovery needs to identify the connector
locally, but those details are discarded before contact persistence or upload.

This list is separate from normal email analysis, the optional knowledge mirror, diagnostics,
covered-inference credentials, and invitation or lifetime-access records. It does not create a
Sentient account for the user.

## Collection and disclosure

`MailAccountCollection.collect` runs after **Done** in the supported Gmail or Outlook Mail connection
sheet, which displays the storage disclosure inline. Opening a picker does not collect an address.
The normal flow does not ask the user to type one.

`MailAccountProbe` uses native connector metadata rather than a model turn:

- ChatGPT: the supported email connector's account metadata.
- Claude Gmail: a narrow sent-thread metadata request. `GmailSenderMetadata` uses senders on messages
  marked SENT and skips ambiguous or empty results.
- Claude Microsoft 365: the supported `get_me` identity response.

The collection path does not request message bodies, subjects or snippets. Unknown addresses or
missing connections are skipped. A collected sending alias is contact information, not proof of
mailbox ownership or permission to act on that mailbox. Apple Mail's local ingestion is a separate
path and does not populate this feedback list.

## Local queue

`MailAccountCloud` is an actor. It keeps only pending normalized addresses and its separate anonymous
Supabase Auth session in a device-only Keychain item. That authentication credential authorizes the
write; it is not attached to a contact row.

`save` queues and deduplicates up to 32 submitted addresses, then attempts a sync. Pending work retries
in the background and at launch. A single-flight drain preserves addresses added during a sync;
a successful sync clears the accepted queue. An upgrade decodes the previous local snapshot,
extracts addresses, discards connector metadata, and rewrites the reduced state.

## Server contract

The current schema is in
`supabase/migrations/20261004010000_email_only_feedback_contacts.sql`:

- `public.feedback_contact_emails` has a validated, normalized `email` primary key. RLS is enabled and
  forced. Anonymous and authenticated app clients cannot directly read or mutate the table.
- Authenticated clients call `add_feedback_emails(emails jsonb)`. The function validates the Auth
  identity and a bounded array of email strings, inserts with deduplication, and returns no signal
  about whether an address was already present. Objects containing metadata are rejected.
- The legacy `sync_connected_email_accounts(accounts jsonb)` RPC remains as a compatibility adapter:
  it extracts addresses from old payloads and discards the other fields. An empty array does not
  delete contacts. The previous metadata table and writer are removed by the migration.
- The app contains a publishable key, not an administrative credential. Privileged database operators
  can manage the feedback list. No contact row references the anonymous Auth identity.

## Retention and controls

Resetting or uninstalling Sentient does not remove addresses from the feedback list or erase
invitation/lifetime access. Reset preserves the local contact queue; uninstall calls
`forgetLocalState()` to cancel retries and remove the local contact credential and queue without
issuing a remote contact deletion.

There is no saved-address management or separate deletion button in Settings. Privacy and removal
requests can go to **feedback@sentient-os.ai**. The planned opt-out in founder outreach is not an
implemented in-app mailing preferences system. The contact list has no 30-day mirror lease.

## Files and verification

| File | Responsibility |
|---|---|
| `MailAccount.swift` | Discovery types, address normalization and validation. |
| `MailAccountProbe.swift` | Supported connector identity discovery without model inference. |
| `MailAccountCollection.swift` | Done flow, inline disclosure, address-only handoff. |
| `MailAccountCloud.swift` | Keychain queue, Auth, append-only sync, retry and local cleanup. |
| `../../../supabase/tests/feedback_contacts.sql` | Table grants, validation, compatibility, deduplication and retention checks. |
| `../../../Scripts/test_mail_account_rls.py` | Local PostgreSQL harness for the SQL checks. |
| `../../../Scripts/test_contact_retention.swift` | Offline actor checks for migration, payloads, retries, concurrency and retention. |
| `../../../Scripts/test_gmail_sender_metadata.swift` | Sender parsing and metadata-only discovery checks. |

These tests use synthetic contacts. Do not test documentation changes against real user records.

## Related documentation

[Hosted sources](../../Sources/Documentation%20-%20Sources%20-%20Cloud%20(Gmail,%20Calendar).md),
[diagnostics](../../Diagnostics/Documentation%20-%20Diagnostics%20(Sentry%20%26%20TelemetryDeck).md),
and [the security policy](../../../SECURITY.md).
