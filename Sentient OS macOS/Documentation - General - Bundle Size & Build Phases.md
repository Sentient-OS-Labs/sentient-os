# Bundle Size & Build Phases

The app target has three custom build phases plus one Copy Files phase. All are in the Xcode project;
this note says what each does and why.

## "Validate CUA contract and Debug logs"

Every configuration runs `Scripts/check_cua_contract.py`. The pinned driver, inlined manual, and
captured MCP catalog must name the same version; the checksum must be present, and the tool lists
must preserve four native MCP vision tools with CLI actions. The script can also compare a captured
release `list-tools` output when upgrading the driver. It performs no download during a build.
Debug additionally runs `Scripts/lint_log_words.sh` to enforce the diagnostics vocabulary.

## "Trim app bundle (thin LiteRT-LM, drop docs)" (last phase, before the final code-sign)

Two jobs, both shrinking the shipped `.app` from ~140 MB to ~73 MB (model not included):

1. **Thin the LiteRT-LM dylib to the app's architectures.** `Contents/Frameworks/libCLiteRTLM_mac.dylib` is a prebuilt, checksum-pinned, remote SwiftPM binary that Google ships fat (arm64 + x86_64, ~127 MB); Xcode copies it wholesale, and `ARCHS = arm64` only governs code Xcode compiles. The script `lipo -remove`s any arch not in `$ARCHS` (idempotent) and re-signs the dylib with the same options Xcode used (`--options runtime` under the Hardened Runtime, `--timestamp` for Developer ID only), so a notarized Release stays valid; the final app code-sign then re-seals the bundle. Dropping x86_64 drops Intel Macs on purpose (the on-device inference needs Apple Silicon anyway).
2. **Drop the internal docs.** The synchronized file group sweeps every `Documentation - *.md` (the per-feature docs and the `Documentation - General - *` set) into `Contents/Resources`; the script deletes `*.md` there. They are public in the repo and never read at runtime.

`ENABLE_USER_SCRIPT_SANDBOXING` is `NO` for the target: Xcode's sandboxed script phases block `lipo`
and `codesign`'s Keychain access. Verify quickly: `lipo -archs <dylib>` → `arm64`; `codesign --verify
--deep --strict <app>` → silent; `find <app> -name '*.md'` → empty. A future win: `strip -x -S` on the
arm64 slice (~14 MB more; test a full inference batch first).

## "Upload dSYMs to Sentry" (Release only)

Uploads the build's dSYMs via `sentry-cli`, reading auth and org/project from the gitignored
`.sentryclirc` at the repo root. Every guard exits 0 (a missing token or tool never breaks a build),
which means it fails silently: keep `.sentryclirc` current on both dev Macs, and rely on `release.sh`'s
hard gate. See the Diagnostics and Updates docs.

## "Copy wake-helper daemon plist"

Copies `jesai.Sentient-OS-macOS.WakeHelper.plist` into `Contents/Library/LaunchDaemons/` so the dev
cockpit's `SMAppService.daemon` path can register it. The production install path writes its own
verified-launch plist into `/Library/LaunchDaemons` (see the Scheduling doc).

## Signing

The team lives ONLY in `Signing.xcconfig` (the committed default is the paid shipping team; a
per-dev override goes in the gitignored `Signing.local.xcconfig`). Never pick a team in Xcode's Signing
& Capabilities dropdown; that writes `DEVELOPMENT_TEAM` into the project file. Release builds are
`dwarf-with-dsym`, Debug is `dwarf`. Deployment target macOS 15.0; Hardened Runtime on; App Sandbox
off (Full Disk Access requires it); the one entitlement is `com.apple.security.device.audio-input`
(the mic prompt does not appear without it under the Hardened Runtime).
