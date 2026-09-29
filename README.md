<div align="center">

<a href="https://sentient-os.ai"><img src=".github/readme/hero.jpg" alt="Your Mac, sentient. An on-device LLM understands your entire life, then proactively offers to get your work done through computer use. Visit sentient-os.ai." width="820" /></a>

<samp>open source · free · optimized for Apple silicon</samp>

</div>

<br/>

Every AI you use today has two problems: it knows nothing about you (nobody can paste their entire life into a chat box), and it only helps when summoned. Fixing both means reading your entire life, every day. In the cloud, that much inference is a fortune and a privacy nightmare. On your own chip, it's free, and nobody else's business.

So every night, Sentient's on-device LLM reads what's new (your files, screenshots, WhatsApp, iMessage, Notes, email) and distills it into a clean markdown knowledge base: the deepest memory of you any AI has ever had. Knowledge-base generation, proactive work, and Sidekick use your own ChatGPT or Claude subscription, or a model endpoint you choose. Double Tap has a separate route, covered by Sentient by default, with your own API provider available in Settings.

By morning, Sentient offers your grunt work done in one click: that reply you forgot, drafted from your own rich personal context. The subscription you meant to cancel, caught the night before it renews.

And anywhere on your Mac, click the notch and tell Sidekick: "Finish this for me". It uses your apps like you would, even in the background while you carry on.

No signup is required. Local source processing happens on your Mac; cloud features and the context they send are described below and in [SECURITY.md](SECURITY.md).

<br/>

## While you sleep, it reads your entire life.

<sub><samp>3:00 AM · LOCAL SOURCE PROCESSING</samp></sub>

At 3 AM every night, Sentient quietly wakes your Mac (lid closed is fine; it falls back asleep after) and reads what's new: files and screenshots, WhatsApp, iMessage, and Apple Notes, decoded straight out of the databases already sitting on your disk. Gmail and Google Calendar ride in through your own OpenAI connectors.

Every single item passes an on-device bouncer. Gemma 4 E4B, running locally, reads it and rules: keep, junk, or sensitive. Junk gets dropped. Sensitive gets dropped harder: no summary, no log, no tombstone, zero trace it ever existed. Only clean, PII-stripped summaries of the keepers survive.

Then the finale: your own codex's frontier model takes those thousands of PII-stripped summaries and distills them into the best possible knowledge base: an Obsidian-style folder of plain markdown, on your Mac, yours to read, edit, and delete note by note. It's not a black box; it's a folder.

<div align="center"><img src=".github/readme/constellation.gif" alt="The Knowledge window's Constellation View: your life, from above. Notes as stars, wikilinks as threads." width="780" /></div>

<br/>

## So you wake up to your work finished in one click.

<sub><samp>9:00 AM · PROACTIVE INTELLIGENCE</samp></sub>

<div align="center"><img src=".github/readme/morning.jpg" alt="The morning cards: replies drafted, plans researched, one tap from done" width="780" /></div>

Overnight, a frontier model reads the night's findings against everything it knows about your life and prepares the few things really worth doing. The reply you forgot, drafted from your own rich personal context. The subscription you meant to cancel, caught the night before it renews.

You get a small handful of cards drafted in the morning, which you can read, edit it if you like, and click once to fire. That click is the only thing that ever fires an action.

<br/>

## One more thing. Meet Sidekick.

<sub><samp>HOLD RIGHT ⌘ · ANYWHERE</samp></sub>

<div align="center"><img src=".github/readme/sidekick.gif" alt="Sidekick: the notch drops open and does the task in your own apps" width="780" /></div>

Anywhere on your Mac, click your notch (or use right ⌘: hold to speak, tap to type) and say: "finish this for me", "reply with the update from Sarah", "put these ingredients in my cart". The notch drops open glowing, transcribes you on-device, and computer use takes it from there, in your own apps and your own logged-in browser, with progress streaming live in the notch.

Because every task is grounded in your knowledge base, Sidekick knows who the people in your life are, what "the usual" means, and what you promised whom. That's the difference between an agent, and a proactive agent that knows you.

<br/>

## Give your AIs your knowledge base.

<sub><samp>CLOUD MCP · OPTIONAL, OFF BY DEFAULT</samp></sub>

Somewhere along the way we realized the knowledge base is too useful to keep to ourselves. So, if you choose, you can offer it to the AIs you already use, ChatGPT and Claude, phone apps included, over a cloud MCP server with zero-access encryption.

Connect it, then ask your ChatGPT: *"what do you know about me?"* Et voila.

Your Mac seals the knowledge base with AES-256-GCM before anything leaves. This is zero-access encryption: the key lives only on your Mac and in your private link, never on our servers, which hold nothing but ciphertext and no key to unlock it. Hack our relay and all you'd find is scrambled bytes; unlike a normal cloud backup, where the company keeps your keys and can be compelled to decrypt, we have nothing to hand over. There is no account: turn sharing off and the cloud copy is deleted on the spot, and if your Mac simply stops syncing, the copy self-destructs after 30 days. The relay is open source too: [sentient-os-mcp](https://github.com/Sentient-OS-Labs/sentient-os-mcp).

<div align="center"><img src=".github/readme/mcp.png" alt="The cloud MCP: sealed on your Mac, ciphertext on the relay, no accounts" width="680" /></div>

<br/>

## Make your Mac sentient.

<sub><samp>FREE · MACOS 15+ · APPLE SILICON · 8 GB IS ENOUGH</samp></sub>

Download the DMG from [the latest release](https://github.com/Sentient-OS-Labs/sentient-os/releases/latest), or use Homebrew:

```sh
brew install --cask sentient-os-labs/tap/sentient-os
```

You'll need an Apple Silicon Mac (M1 or newer) on macOS 15 or later. 8 GB of RAM is enough; we tuned the on-device model until it fit. Keep about 10 GB of disk free before you start: the on-device model is a 3.7 GB download, and it needs room to land.

Building from source is straightforward: clone, open `Sentient OS macOS.xcodeproj` in Xcode 26, press Run. The on-device model downloads itself during onboarding.

<br/>

## Under the hood.

<sub><samp>YOUR MAC · YOUR CHATGPT PLAN · OUR SERVERS</samp></sub>

Your Mac processes local sources, and your chosen frontier model builds the knowledge base and powers proactive work and Sidekick. Double Tap can use Sentient's inference relay or your own API provider. The optional encrypted MCP mirror and invitation service have separate server paths.

<div align="center"><img src=".github/readme/under-the-hood.png" alt="Illustration of local source processing and the frontier-model pipeline" width="880" /></div>

The illustration shows the local-source and frontier-model pipeline. Double Tap, invitations, and the optional mirror use the additional server paths described below. The local processing includes:

- **The inference engine.** <samp>a custom LiteRT-LM fork, running Gemma 4 E4B</samp>
- **Inference optimization.** <samp>kv cache reuse · flash attention · speculative decoding · self-healing gpu runs · 8 gb macs, welcome</samp>
- **Reading your real life.** <samp>typedstream decoding · protobuf walks · wal-safe copy-reads · date-added, not mtime · never spotlight</samp>
- **Privacy engineering.** <samp>zero-trace triage · fail-closed parsing · a pii regex backstop · aes-256-gcm before anything leaves · a 30-day dead-man lease</samp>
- **The 3 AM machine.** <samp>a codesign-verified root helper · a deadman timer · ac + thermal gates · crash-safe resume</samp>
- **The cloud brain.** <samp>your own frontier CLI as the brain, native computer-use tools as the hands · frontier compute on your subscription · marginal cost ~$0</samp>

And about that cloud brain. Sentient uses your own Codex CLI, Claude Code, or chosen model endpoint. ChatGPT tasks use OpenAI's signed computer-use helper; Claude and custom endpoints use the open-source [CUA driver](https://github.com/trycua/cua) (MIT). Both act in your own apps and browser, with visible progress and STOP. Dependencies download directly from their publishers and are verified before use. These CLI-based tasks use your selected provider directly. Double Tap's separate relay route is described below.

## The privacy flex.

Local source processing and user-triggered cloud features have different data paths:

1. **Local ingestion stays on your Mac.** Files and local message databases are read on-device. The summary pipeline sends PII-stripped summaries to your chosen frontier model, with a deterministic PII backstop after model triage.
2. **Junk and sensitive items leave zero trace downstream.** The local triage pipeline drops them instead of adding them to your knowledge base.
3. **Your Mac's knowledge base is canonical.** You can read and edit its Markdown files. Frontier tasks can receive this context, connected-service results, and screen context when needed for the task you started.
4. **The MCP mirror is optional and off by default.** Your Mac encrypts it with AES-256-GCM before upload. Stored data is ciphertext; your private connector link carries the key used to serve requests. One click deletes the mirror, and an unrefreshed copy expires after 30 days. See [SECURITY.md](SECURITY.md) for the threat model.
5. **Double Tap sends reply context to the selected provider.** By default, a screenshot, knowledge-base context, and your instructions pass through Sentient's relay to OpenAI. Settings → Double Tap also supports your own OpenAI or OpenRouter API credentials. Double Tap drafts into the focused field; you decide whether to send.
6. **Invitations use an anonymous installation identity.** Supabase stores invite codes, redemption dates, and lifetime-access grants. Sentient administrators can access these records. They contain no files, messages, or model credentials; the installation credential stays in Keychain, and Reset preserves lifetime access.

Crash reports (Sentry) and usage analytics (TelemetryDeck) carry structural diagnostics rather than your content. Each has an off switch in Settings. Crash reports turn off completely; disabling analytics retains only the limited usage counts disclosed beside the toggle.

Features using your own Codex CLI, Claude Code, or API provider follow that provider's privacy and retention policies. The app's Privacy Policy explains these paths alongside the optional mirror, Double Tap, and invitations.

<br/>

## Questions, answered.

<details>
<summary><b>How is Sentient free? What's the catch?</b></summary>
<br/>

Local processing runs on your Mac, and frontier tasks use your own subscription or chosen endpoint. Sentient covers Double Tap's default relay route; you can also choose your own API provider in Settings.

As for how we ever make money: enterprise, later. The same engine, with the consumer connectors swapped for work ones like Slack, Granola, Linear, and Notion, becomes a personal intelligence layer for every employee, and companies pay for a license. But nobody has built AI like this before; it's a genuinely new frontier, so we're perfecting it with consumers first. Your data is never the product.

AI that proactively helps you should be accessible to everyone. Sentient is open source under the AGPL so anyone can inspect, build, and improve it.

</details>

<details>
<summary><b>Do I need a ChatGPT subscription? Or can it run fully locally?</b></summary>
<br/>

No. The on-device model does about 90% of the compute, going through your entire life locally; frontier intelligence handles the final 10% (the final stage of knowledge base creation, proactive intelligence, and running Sidekick).

That 10% isn't tied to any one provider and you have many choices:

- **Your ChatGPT subscription**
- **A local model through LM Studio**
- **Any model on OpenRouter**
- **Your Claude subscription**
- **Any other frontier model you want to connect**: anything that speaks the OpenAI Responses API works, including fully self-hosted

If you go the ChatGPT route:

- A free ChatGPT account comes with a small amount of codex compute, enough to build your knowledge base, but not enough to power proactive intelligence or Sidekick (and ChatGPT Go doesn't unlock them either).
- The full engine needs ChatGPT Plus, about $20 a month, paid to OpenAI, not to us.

We still recommend Plus as the nicest path: right now, Sentient connects to your Gmail and Google Calendar through OpenAI's own connectors, which require Plus.

</details>

<details>
<summary><b>What actually leaves my Mac?</b></summary>
<br/>

The local ingestion pipeline sends PII-stripped summaries to your chosen frontier model. Proactive tasks and Sidekick can also use your knowledge base, connected-service context, and screenshots for the task you started. Double Tap sends a screenshot, knowledge-base context, and instructions through Sentient's relay to OpenAI by default, or to your own configured API provider.

The optional MCP mirror uploads an encrypted knowledge base. Invitations store codes and access grants under an anonymous installation identity. Diagnostics send the structural information described above. [SECURITY.md](SECURITY.md) explains the data paths and permission boundaries.

</details>

<details>
<summary><b>When does Sentient do daily processing?</b></summary>
<br/>

Every night at 3 AM, as long as Sentient's open in your menu bar and your Mac's plugged in. Overnight it reads what's new in your life, updates your knowledge base, and prepares your morning cards, so everything's waiting when you wake up.

This works even if your laptop's sleeping with its lid closed: Sentient wakes it quietly for the run and lets it fall back asleep after.

</details>

<details>
<summary><b>Why does it need Full Disk Access?</b></summary>
<br/>

That's how it reads your real life: WhatsApp, iMessage, and Apple Notes live in databases on your Mac that only Full Disk Access can open. Everything's read locally, and the permission never sends anything anywhere. That's the whole trade Sentient makes: deep access on your machine, so nothing needs access in the cloud.

</details>

<details>
<summary><b>Can I see what it knows about me?</b></summary>
<br/>

All of it. The knowledge base is a folder of plain markdown on your Mac, and the built-in Knowledge window lets you read, edit, and delete any of it. If Sentient knows something you'd rather it didn't, delete the note and it's gone everywhere.

Settings lets you delete the cloud mirror and reset the app. An unrefreshed mirror expires after 30 days. Reset preserves your invitation identity and lifetime-access grant.

</details>

<details>
<summary><b>What Macs does it run on?</b></summary>
<br/>

Apple Silicon (M1 or newer) on macOS 15 or later. 8 GB of RAM is enough; the on-device model has inference optimizations to work in it. You'll also want about 10 GB of free disk space when you first set it up, since the on-device model is a 3.7 GB download.

</details>

<br/>

## The docs go deeper.

Every serious subsystem in this repo has a detailed engineering doc sitting right next to its code (each feature folder under `Sentient OS macOS/` carries a `Documentation - <Feature>.md`; [the map lives here](Sentient%20OS%20macOS/Documentation%20-%20General%20-%20README.md)): how iMessage's typedstream actually decodes, why we never touch Spotlight, how a root helper wakes a lid-shut Mac at 3 AM without ever sending you into System Settings, and what it took to make the notch a button. Filled with fun engineering battles from the trenches :)

House rules live here: [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [LICENSING.md](LICENSING.md) · [CLA.md](CLA.md)

<br/>

## Contributing.

This repo moves fast. Issues and PRs are welcome, small PRs are beloved, and for anything ambitious please open an issue first so you don't spend a weekend building something we're mid-rewrite on. Setup and house style are in [CONTRIBUTING.md](CONTRIBUTING.md). Outside contributions sign a CLA on the first PR.

<br/>


---

<div align="center">
<sub><samp>AGPL-3.0 · COMMERCIAL LICENSING IN <a href="LICENSING.md">LICENSING.MD</a> · <a href="https://sentient-os.ai">SENTIENT-OS.AI</a></samp></sub>
</div>
