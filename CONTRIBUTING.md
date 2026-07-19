# Contributing to Sentient OS

Hi. Thanks for wanting to make Sentient better! We're a two-person team and the repo moves quickly, so this guide is short on purpose. It's worth the three minutes :)

## Before you build anything big

Open an issue first. Not out of bureaucracy, but because we rewrite fast and it would genuinely pain us to watch you spend a weekend on something we deleted on Tuesday. Small fixes and polish PRs can skip straight to the pull request.

## Getting it running

You'll need an Apple Silicon Mac on macOS 15 or later, and Xcode 26.

1. Clone the repo and open `Sentient OS macOS.xcodeproj`.
2. Signing: create a `Signing.local.xcconfig` file next to `Signing.xcconfig` with one line, `DEVELOPMENT_TEAM = <your team id>`. It's gitignored, and it's the only place your team should ever appear. Please don't pick a team in Xcode's Signing & Capabilities dropdown: that silently writes it into the project file, and we'll have to bounce the PR for it.
3. Press Run. The on-device model (Gemma 4 E4B, ~3.7 GB) downloads during onboarding.

A note on project structure: the Xcode project uses synchronized file groups, so files you add or move on disk join the target automatically. No project-file surgery ever.

## House style

- **One file = one job.** A stranger should guess a file's purpose from its name and be right. Every new Swift file opens with a short comment saying what it does.
- **No dead weight.** Unused code gets deleted, not commented out. Repeated logic gets extracted. No abstraction until there's a second real use for it.
- **`Log()` over `print()`.** It's the codebase-wide logger (`Diagnostics/Log.swift`); a bare `print()` is a code smell here.
- **UI has a high bar.** And we intend to keep it that way. So expect picky review on anything a human sees. Screenshots or a screen recording in the PR help a lot!

## Pull requests

Branch from `main` as `yourname/what-it-is`, keep PRs small and focused, and say what you changed and why in plain words. Small and same-day beats big and stale; this codebase moves too fast for week-old branches to survive merging.

## The CLA

Your first PR will ask you to sign our [CLA](CLA.md). The reason: Sentient is AGPL for everyone, and the eventual business is selling companies a commercial exception to that license, which is only possible if contributions grant us the right to offer one. Consumers are never the business model. The full story is in [LICENSING.md](LICENSING.md).

## Security

Found a vulnerability? Please don't open a public issue. See [SECURITY.md](SECURITY.md) for how to reach us privately.
