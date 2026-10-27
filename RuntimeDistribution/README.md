# Pinned runtime distribution

The app embeds `Sentient OS macOS/Cloud/BundledCodexRelease.json`. It downloads only those
exact CLI and helper archives, verifies their hashes and file inventories, and installs
them into its private runtime. Updating this service does not change an installed app's pin.
Login, configuration, sessions, and connector caches remain in the same private Codex home.

## Prepare a release locally

1. Resolve the stable CLI version and archive digest from
   `https://releases.openai.com/codex/channels/latest`. Download the complete
   `codex-package-aarch64-apple-darwin.tar.gz` asset, including its support binaries and resources.
2. Download OpenAI's official desktop installer, mount it read-only, and locate the complete
   `Codex Computer Use.app`. Use the installer payload, never a user's live Codex home.
3. Run `python3 RuntimeDistribution/scripts/prepare_release.py --help` from the repository root.
   Supply the archive, its official SHA-256, the helper bundle, and a new local output directory.
   The script verifies signatures, packages the helper without local metadata, verifies an
   extraction round trip, and writes both archives and a candidate manifest. It performs no
   uploads or installation and does not change the repository's manifest.
4. Before adopting the candidate manifest, append the outgoing CLI/helper metadata (excluding
   `files`) to `previous-artifacts.json`. Preserve every previously published filename, size,
   and SHA-256. Then copy the candidate manifest to the app's manifest path.
5. Run the distribution tests and the installer regression scripts. Exercise
   `Scripts/test_bundled_runtime.py --archives <directory>` with the real artifacts; add
   `--previous-manifest <file> --previous-archives <directory>` for old-to-new verification.
   This runs real installation, signature checks, private login recognition with synthetic
   credentials, and native tool discovery. It performs no native actions or model turns.
6. Build signed Debug and Release configurations and run the signed app's acceptance fixtures.
   Separately verify native capture/actions and permission continuity on an isolated test Mac
   or VM. Never displace a helper serving somebody else's active task to run a release test.

The fixture scripts need Xcode's Swift toolchain. If Command Line Tools are selected, set
`DEVELOPER_DIR` for the test command to the installed Xcode's `Contents/Developer` directory.
Use isolated DerivedData for CLI builds and `SENTIENT_SKIP_DSYM_UPLOAD=1` for local Release checks.

## Team-controlled publication

From `RuntimeDistribution/`, first verify the candidate archives without uploading:

```sh
npm test
npm run publish:archives -- /absolute/path/to/artifacts --dry-run
```

Once the team is ready to publish, the required order is:

1. Upload the verified archives with `npm run publish:archives -- /absolute/path/to/artifacts`.
2. Deploy the worker with `npm run deploy`. Its allowlist includes the new pins and all retained
   artifacts. Unknown paths remain inaccessible; `/releases/manifest.json` describes the new pins.
3. Verify both old and new URLs: full download hashes, HEAD, byte ranges, resumed downloads,
   and cache validation. Confirm unknown paths and write methods are still rejected.
4. Release the signed Sentient app through the normal app-release process with a new build number.
   Publishing dependency archives alone does not upgrade existing users.

Never overwrite a published archive with different bytes, remove retained artifacts, or deploy
the app before its dependency URLs are available. An offline or failed setup preserves existing
files, but the new app requires its exact pins and can defer computer use until setup succeeds.
Runtime locks prevent replacement during a task. An idle private helper is asked to quit
gracefully before replacement; a refusal or relaunch defers replacement without force-quitting.

Retaining old archives supports older builds and repairs. It does not establish that an older
CLI can read state migrated by a newer CLI; test that separately before an app downgrade.
