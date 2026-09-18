# The Knowledge Base (Vault/)

How the survivor summaries become an Obsidian-style markdown knowledge base at
`~/Sentient OS - Knowledge Base/`, and how it stays current. The user-facing name is **Knowledge**;
"vault" survives only in code. The frontier model (through `CodexCLI`) WRITES the markdown itself with
its file tools inside a staging directory, and the live folder is only ever replaced by an atomic swap
on success. Never mutated mid-run.

## Files

| File | Job |
|---|---|
| `VaultGenerator.swift` | The first build: the locked prompt core, the agentic run over a staging dir, the shared staging + atomic-swap helpers, resume tokens, the source-trust tags (`locSrc`). |
| `VaultCloud.swift` | The two cycle calls: `create` (first build, via `VaultGenerator`) and `update` (a surgical merge over a staged COPY of the live vault). Persists resume tokens. Owns `pushIfDirty()` and the update prompt. |
| `CorpusSlicer.swift` | Splits a summary corpus into byte-budgeted parts so no single prompt can exceed codex's ~1 MiB per-turn input cap. Deterministic on purpose. |
| `VaultActivity.swift` | The vault-change / mirror-sync seam: `vaultDirty` (persisted), `editorBusy`, and the Knowledge editor's 30 s debounced push with its status line. |

## Build (`VaultGenerator.generate`)

- Runs `codex exec` with `gpt-5.6-sol` at high effort (xhigh was retired; it thinks far too long), a `workspace-write` sandbox, and `cwd` = a fresh, empty staging directory (`.sentientos-vault-staging-<uuid>`, a SIBLING of the vault so the swap stays on one volume). Orphaned staging dirs from earlier runs are swept first.
- The prompt = `vaultPromptCore` + `agenticOutputInstructions` + the corpus. The core is the product of a multi-cycle eval on real data: source-trust tiers (the user's own Obsidian / authored notes are the truth; screenshots and saved files are often about other people), the truth-and-attribution rule (a confident false claim is worse than an omission; when unsure, leave it out), ruthless synthesis and de-duplication, a root `README.md` portrait written for an AI reader FIRST, and hard shape caps: at most ~10 root folders, notes at depth ≥ 2, ~2 to 5 substantial notes per subfolder, **80 to 120 notes** total, `[[wikilinks]]` only to notes that exist, no frontmatter, no em dashes.
- Progress: a 2 s poll of the staging dir's `.md` count, plus an optional `onLine` that forwards codex's humanized play-by-play (the takeover's "THINKING" trail).
- Success = at least one note written → `swapStagingIntoVault` (`FileManager.replaceItemAt`, a true atomic replace; a plain move on the very first build). On any throw the existing vault is left intact and staging survives for a retry.

## Update (`VaultCloud.update`)

Every full cycle after the first merges the cycle's new summaries into the existing vault:

1. Skip the cycle if the Knowledge editor is mid-edit (`VaultActivity.editorBusy`); the notes stay in `CycleStore` for next time.
2. Seed a staging dir with a COPY of the live vault and capture the live vault's fingerprint (`vaultFingerprint`: SHA-256 over every note's `relpath|size|mtime`).
3. Run the update prompt (`updatePrompt`) in staging: "surgical edits, not a rebuild": be the second sieve (not every item deserves the vault; a run where nothing merges is fine), edit existing notes ~90% of the time and create a new file only ~5% of the time, never delete or rename notes wholesale, keep the shape caps, update the README only if today's items genuinely change who the user is.
4. **Freshness check** at swap time: if the live vault's fingerprint changed during the run (the user saved a note in the Knowledge editor), abort the swap and discard staging rather than clobber their edit; the notes retry next cycle (`KnowledgeBase.staleSwapAverted` analytics).
5. Atomic swap, then mark the vault dirty.

## Corpus batching (`CorpusSlicer`)

`codex exec` refuses a single turn over ~1 MiB. A data-rich first run (thousands of summaries) or a
heavy update backlog can exceed it, so the corpus is fed as a sequence of parts:

- `slice(_:budget:)` walks the notes in order and closes a part when the next entry's rendered cost would cross the budget (**700 KB** on ChatGPT; 280 KB remote / 130 KB local on a custom endpoint, where the context window is the constraint). Entries are never split; the rendering (`render`) is the SAME one the prompts use, so measured cost cannot drift from what is sent.
- Part one rides the build prompt; every later part merges into the same staging dir with the update prompt, one fresh codex session each. `VaultCloud.update` runs the same loop. The single atomic swap still happens once, at the end.
- A **staging snapshot** (`.sentient-corpus.json`, written only for multi-part runs, deleted before the swap) guarantees an identical re-slice across app restarts even though `CycleStore` returns notes newest-first (a fresh fetch after more ingestion would shift every boundary).
- Progress reports "part N of M" in the takeover's phase line.

`CodexCLI.promptByteCap` (950 KB) is the floor beneath this: a typed `inputTooLarge` error, never a
mystery failure.

## Resume (usage limits and restarts)

A usage-limit error throws `VaultError.usageLimit(message, resume: ResumeToken)`. The token carries the
codex thread id, the staging path, the seed fingerprint (update only), and the next unfed slice index.
`VaultCloud` persists it (`vault.create.resume` / `vault.update.resume`) and drops it if the staging dir
is gone or nothing is resumable. Resuming finishes the in-flight session first (`codex exec resume`,
whose workspace root is the process cwd), then continues the remaining parts. A resumed session that
left staging empty restarts fresh under the slicer instead.

## Sync seams (`VaultActivity`, `pushIfDirty`)

Build and update only MARK the vault dirty. `VaultCloud.pushIfDirty()` pushes to the mirror if it is
enabled and the vault is dirty, clearing the flag only on success. It runs after every full cycle
(`ProactiveCycle`), at app launch (a catch-up), and from the Knowledge editor's debounced
`markChanged()` (one push 30 s after the last save/create/delete, with the sidebar's synced / will sync
/ syncing status line). See the MCP Mirror doc.

## Source-trust tags (`VaultGenerator.locSrc`)

Each corpus entry renders as `#N · [source] location · date` then `Title — summary`. The `[source]`
tag is what the prompt keys its trust on: `Obsidian — USER'S OWN NOTE`, `<folder> — user-authored note`
(`.md` / `.txt`), `WhatsApp · <chat>`, `Gmail — the user's email correspondence`, `Calendar — the
user's schedule / events`, or the plain folder for screenshots, photos, and PDFs. Proactive's prompts
render the same lines.

## Rules

- Never edit the live vault in place from a cloud run; stage, then swap.
- Never delete the corpus snapshot before the swap; never let it ride into the vault or the mirror.
- The prompt cores are eval-validated; change them deliberately and re-verify on real data.
- `SENTIENT_VAULT_ROOT` (a scratch vault for self-tests) is DEBUG-only by design.

## Related docs

`Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md`, `Cloud/Documentation - Cloud - MCP Mirror.md`, `Proactive/Documentation - Proactive Intelligence.md` (`ProactiveCycle` sequences these), `Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md` (the editor that writes into the same folder).
