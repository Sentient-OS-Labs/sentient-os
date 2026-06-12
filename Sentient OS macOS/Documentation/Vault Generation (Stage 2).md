# Vault Generation — Stage 2 (the agentic build)

`VaultGenerator.generate(summaries:resume:onProgress:)` turns the on-device survivor
summaries into the markdown vault at `~/Sentient OS -- The Vault/`, through ONE route:
`codex exec` via the `CodexCLI` spine — GPT-5.5 **high effort**, `workspace-write` sandbox,
cwd = a staging dir; the model writes the `.md` files itself with its file tools. Without a
working codex the run throws `CodexCLI`'s `.notAvailable` (no fallback — the free tier is
the eventual answer for no-codex users; the old direct-Anthropic-API route and its
`Secrets.swift` dev key were deleted June 11 and live in git history).

## Why agentic (Arch §5/§6)

- **No per-message output cap** — the model writes files across turns instead of one giant response.
- **Resumable** — a usage-limit failure throws `VaultError.usageLimit(message:resume:)`; the
  `ResumeToken` carries the Codex session (thread) id AND the staging path. Passing it back to
  `generate(resume:)` continues the same session over the same half-written staging dir.
  ⚠️ On resume the workspace root is the PROCESS cwd (CodexCLI sets it from `Invocation.cwd`).
- **Free at the margin** — the user's own ChatGPT subscription does the work.

## Safety: staging + atomic swap

The run never touches the live vault. It writes into `~/.sentientos-vault-staging-<uuid>`
(same APFS volume as the vault → the final move is an atomic rename). Only after the run
succeeds **and** produced >0 notes does the old vault get replaced. A mid-run death (limit,
crash, kill) leaves the previous vault intact and the staging dir resumable.

## Progress

Progress is the filesystem itself: a 2s poll of the staging dir's `.md` count →
`Progress.writing(notes:)` → VaultView's "N notes written…". No CLI stream parsing.

## The prompt

`vaultPromptCore` (the eval-validated wisdom: source-trust tiers, truth & attribution,
ruthless synthesis, README-first portrait, structure rules, 100–150-note density) +
`agenticOutputInstructions`. User-agnostic — no hardcoded per-user facts.
⚠️ Known small-corpus finding (June 11, 83-summary eval): the fixed density target pulls
toward one-note-per-summary when the corpus is smaller than the target; revisit after the
full-scale (1,704-summary) gate run.

## The welcome briefing

`writeWelcomeBriefing()` — initial gen's second act: a medium-effort pass over the fresh
vault (cwd = vault, Briefings dir via `--add-dir`) that writes "What I learned about you"
into `~/Library/Application Support/SentientOS/Briefings/`. Best-effort, fired alongside the
post-gen mirror push.

## Self-test

```sh
SENTIENT_SELFTEST=vault SENTIENT_SELFTEST_N=8 "<app>/Contents/MacOS/Sentient OS"   # tiny subset
SENTIENT_VAULT_ROOT=/tmp/scratch …                                                  # protect the real vault
```

## Siblings on the same spine

The iterative day's-end updater (see `Days-End Job (Living System).md`) rides the same
`CodexCLI` spine — it edits the live vault in place rather than regenerate.
