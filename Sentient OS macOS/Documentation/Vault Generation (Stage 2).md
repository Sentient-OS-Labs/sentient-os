# Vault Generation — Stage 2 (two routes, one call)

`VaultGenerator.generate(summaries:resume:onProgress:)` turns the on-device survivor
summaries into the markdown vault at `~/Sentient OS -- The Vault/`. It routes automatically:

| Route | When | How |
|---|---|---|
| **Agentic** (default) | `ClaudeCLI.validate()` says the user's Claude Code works | `claude -p` with `Write,Edit,Read,Glob,Grep`, cwd = a staging dir; the model writes the `.md` files itself |
| **Direct** (fallback) | No working Claude Code (until the Bedrock tier exists) | One streamed Opus API call emitting a `=== NOTE: path ===` stream we parse + materialize |

## Why agentic is the default (Arch §5/§6)

- **No 64k output cap** — the model writes files across turns instead of one giant response.
- **Resumable** — a usage-limit failure throws `VaultError.usageLimit(message:resume:)`; the
  `ResumeToken` carries the Claude `session_id` AND the staging path. Passing it back to
  `generate(resume:)` continues the same session over the same half-written staging dir.
- **Free at the margin** — the user's own subscription does the work.

## Safety: staging + atomic swap

The agentic run never touches the live vault. It writes into
`~/.sentientos-vault-staging-<uuid>` (same APFS volume as the vault → the final move is an
atomic rename). Only after the run succeeds **and** produced >0 notes does the old vault get
replaced. A mid-run death (limit, crash, kill) leaves the previous vault intact and the
staging dir resumable. *(The direct route still does the historical wipe-and-rebuild.)*

## Progress

Agentic progress is the filesystem itself: a 2s poll of the staging dir's `.md` count →
`Progress.writing(notes:)` → VaultView's "N notes written…". No CLI stream parsing.

## The prompt

One shared `vaultPromptCore` (the eval-validated wisdom: source-trust tiers, truth &
attribution, ruthless synthesis, README-first portrait, structure rules, 100–150-note
density) + a per-route output section (`agenticOutputInstructions` / `directOutputFormat`).
The old hardcoded Jesai-specific KNOWN FACTS / EXCLUDE blocks were **removed entirely** —
the prompt is user-agnostic now.

## Self-test

```sh
SENTIENT_SELFTEST=vault SENTIENT_SELFTEST_N=8 "<app>/Contents/MacOS/Sentient OS"   # auto route, tiny subset
SENTIENT_VAULT_ROUTE=direct …                                                       # force the API fallback
```

## Future

The iterative day's-end updater (skeleton tree + new summaries + scoped tools over the LIVE
vault) rides the same `ClaudeCLI` spine — it edits in place rather than regenerate. Welcome
briefing lands with initial gen (separate task).
