# Security Policy

**On-device understanding. Your choice of AI. Knowledge you own.**

Sentient uses on-device inference to understand the local sources you enable, keeps your knowledge
in a folder on your Mac, and lets you choose the AI that organizes it and helps you act. The app and
supporting infrastructure are open source. We do not sell personal information or share it for
cross-site targeted advertising.

This document explains the implementation's security boundaries and how to report vulnerabilities.
The in-app privacy policy describes the associated data practices and controls.

## Reporting a vulnerability

Email **security@sentient-os.ai**. Please do not report vulnerabilities through public GitHub issues.
Include the issue and its impact, steps to reproduce, the version or commit tested, and any suggested
fix. We will acknowledge reports within 48 hours and keep you informed while we work on a fix.

Everything Sentient ships is in scope: the macOS app, hosted MCP mirror and server code, covered
Double Tap relay, feedback-contact storage and its Auth boundary, and release/update infrastructure.
For live testing, use your own data and accounts. Avoid disruptive testing or resource exhaustion.
If you believe you can reach another user's knowledge or records, stop at the minimum proof needed
and report it.

## Understanding on your Mac

The local model analyzes enabled files, saved screenshots, Apple Notes, selected iMessage and
WhatsApp conversations, Apple Mail and Apple Calendar. That analysis does not upload the source
material to an inference service. Useful summaries then go to the **chosen frontier model** for
knowledge organization and proactive preparation. That model can be local or hosted.

On-device prompts and deterministic checks help exclude irrelevant material and common sensitive
identifiers. These are filters, not a guarantee that every personal detail has been removed. The
resulting knowledge is intentionally personal. Rejected items do not become knowledge summaries;
local progress checkpoints and counts still support reliable processing.

Double Tap writing examples are a separate one-time snapshot of selected sent messages. They retain
original wording and recipient/conversation context, are editable as `writingstyle.md`, and travel
with Double Tap requests and the knowledge folder if sharing is enabled.

## Your choice of inference

- **Sidekick and proactive intelligence:** use the selected ChatGPT/Claude account, compatible API
  provider, or supported local model. Requests can include knowledge, task context and screenshots.
  Hosted inference follows the chosen provider's processing settings.
- **Email and calendar:** Apple Mail and Apple Calendar are analyzed locally and work without a
  ChatGPT or Claude subscription. Hosted connectors use the supported AI account; direct MCP
  connections use the service the user authorizes, with credentials stored in Keychain.
- **Double Tap:** has an independent provider setting. For low latency, the covered default uses
  Sentient's OpenAI API route with Zero Data Retention. A screen image, knowledge including writing
  examples, and instructions pass through the relay to produce an unsent draft. Users can choose
  their own provider, including a compatible model running locally. `store: false` is not, by itself,
  evidence of a provider's contractual retention policy.
- **Voice:** uses Apple's on-device speech recognition where supported. If unavailable, Apple's
  speech service may process audio. The transcript becomes a request to the chosen task model.

These distinct paths are why a product-wide claim that all files, messages or screenshots can never
leave the Mac would be inaccurate. Local source analysis, cloud drafting, user-requested actions and
optional sharing each have their own boundary.

## Permissions and actions

Full Disk Access supports local readers, including Apple Mail, Notes and conversations. Source
selection controls what regular analysis reads; writing-style setup has its separate sample scope.
Apple Calendar requests EventKit Full Access because macOS offers no read-only calendar grant, while
Sentient's source reader only reads selected calendars.

Sentient's Screen Recording permission supplies screen context. All current computer-use backends
use OpenAI's signed native helper, with its own Accessibility and Screen Recording grants and
Sentient's Automation permission. Double Tap additionally uses Sentient's Accessibility permission
to paste a draft. Setup uses macOS consent surfaces; it does not modify TCC databases. Permissions can
be revoked in System Settings → Privacy & Security.

Overnight analysis prepares knowledge and suggested work. Proactive research uses read-only
invocations and connector tool restrictions; it does not start computer use or execute the proposed
action. A user starts execution by choosing a card or making a Sidekick request. The live notch shows
progress and provides STOP for the shared task.

Computer-use tasks have broad ability to act in the user's apps. Their prompts scope the work to the
request, treat retrieved content as data, and require verification before reporting success.
Connector actions have their own tool policies and validation. These are layered safeguards, not a
claim that model instructions are a security sandbox or that prompt injection is impossible.

## Optional knowledge sharing

The hosted MCP mirror is off until enabled. Sentient encrypts the knowledge folder with AES-256-GCM
on the Mac before upload. The relay stores encrypted knowledge **without persisting the decryption
key**. The private link supplies the secret for authorized requests; the relay decrypts in memory
when serving them. The app and relay implementations are open source.

This protects the stored copy without claiming that the running relay cannot access plaintext during
an authorized request. The full link is a bearer credential and must be kept private. The mirror's
secret is separate from diagnostics, contact-write authentication and invitation identities.
Sharing includes the one-time writing snapshot and files the user adds to the knowledge folder.

Access metadata records times, tool names, client information and hashed note references. Request
paths must not be logged because they contain the secret. Turning sharing off stops sync and requests
deletion; network failures can delay that request. Periodic cleanup removes copies and access history
after 30 days without sync. The local knowledge folder remains the user's primary copy.

## Feedback contacts and service records

The founder-feedback list stores **email addresses only**, separately from private knowledge and
product analytics. Done in supported Gmail/Outlook connection flows discloses this collection.
`feedback_contact_emails` has one column, `email`; it contains no installation ID, connector metadata
or contact timestamps. Anonymous Supabase Auth authorizes a bounded append-only RPC but is not linked
to a contact row. App clients cannot directly read the list or delete it. The compatibility RPC drops
metadata sent by older clients. Administrative database access remains privileged.

Reset and uninstall preserve the feedback list and invitation/lifetime-access records. Uninstall
clears local contact credentials. Requests for removal or help can go to **feedback@sentient-os.ai**;
any founder feedback outreach will include an opt-out. Covered inference uses its own random
installation credential and usage limits.

See [connected email storage](Sentient%20OS%20macOS/Cloud/Mail%20Accounts/Documentation%20-%20Connected%20Email%20Accounts.md)
for the schema, migration and synthetic-data tests.

## Diagnostics

Release builds enable crash reports and extended analytics by default, with separate controls in
Settings → System. Sentry receives technical crash/error reports and a random installation identifier;
content scrubbing and disabled URL-capture defaults help exclude private material. TelemetryDeck
receives usage counts and optional extended timings, setup and health signals. Turning extended
analytics off leaves basic usage, launch/session and install/uninstall counts enabled.

Knowledge, task content, conversations and screenshots are excluded from product analytics by
design. Generated identifiers allow repeat events to be recognized without asking for a name or
email. The implementation and its limits are documented in the diagnostics guide; do not describe
the controls as disabling every network request or make blanket anonymity guarantees.

## Implementation references

- [Feature and architecture map](Sentient%20OS%20macOS/Documentation%20-%20General%20-%20README.md)
- [On-device triage](Sentient%20OS%20macOS/Engine/Documentation%20-%20On-Device%20Engine%20%26%20Triage.md)
- [Native computer use](Sentient%20OS%20macOS/Driver/Documentation%20-%20Native%20Computer%20Use.md)
- [MCP encryption and sync](Sentient%20OS%20macOS/Cloud/Documentation%20-%20Cloud%20-%20MCP%20Mirror.md)
- [Diagnostics](Sentient%20OS%20macOS/Diagnostics/Documentation%20-%20Diagnostics%20(Sentry%20%26%20TelemetryDeck).md)
- [Overnight scheduling and the wake helper](Sentient%20OS%20macOS/Scheduling/Documentation%20-%20Overnight%20Scheduler%20%26%20Wake%20Helper.md)

## Supported versions

Sentient is under active development. Security fixes land in the latest release only; please check
whether an issue reproduces against the newest version.

## Coordinated disclosure

Please give us reasonable time to fix an issue before public disclosure. 90 days is a good default;
hosted issues will typically be fixed sooner. We can credit you when the fix ships or keep you
anonymous. We do not currently run a paid bounty program.
