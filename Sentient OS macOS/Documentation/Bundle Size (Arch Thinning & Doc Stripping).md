# Bundle Size — Arch Thinning & Doc Stripping

**What:** a single build-phase script — **"Trim app bundle (thin LiteRT-LM, drop docs)"** — that
shrinks the shipped `.app` from ~140 MB to ~73 MB (model not included). Lives in the app target's
build phases (last phase, runs before the final code-sign).

## Why the app was 130 MB+

Measured on a Debug build: **`Contents/Frameworks/libCLiteRTLM_mac.dylib` was 127 MB — ~91% of the
whole app.** Everything else is rounding error (your code ~9 MB, `Assets.car`/icon ~3 MB, no stray
media). The dylib was a **fat universal binary**: ~70 MB x86_64 (Intel) + ~64 MB arm64.

The catch: our project already builds **`ARCHS = arm64`**, but that only governs code Xcode
*compiles*. `CLiteRTLM_mac` is a **prebuilt, checksum-pinned, remote SwiftPM binary target** (see
`Vendor/LiteRTLM/Package.swift` — downloaded from Google's GitHub releases into
`DerivedData/SourcePackages/artifacts/`). Xcode copies that fat binary into the bundle **wholesale**;
nothing re-thins it. So flipping a build setting can't fix it — and we can't edit the artifact at the
source (it's checksum-locked and wiped on clean). The fix has to run at build time on the *product*.

## What the script does

1. **Thin the dylib** to the app's `$ARCHS` (drops the x86_64 slice → ~61 MB). Idempotent: it only
   `lipo -remove`s an arch that's present *and* not wanted, so an already-thin slice is a no-op on
   incremental builds.
2. **Re-sign the dylib** (modifying a Mach-O invalidates its signature). It mirrors Xcode's options
   so distribution stays valid: `--options runtime` when Hardened Runtime is on, and `--timestamp`
   for `Developer ID` (distribution) signing only — Apple Development / adhoc dev builds skip the
   timestamp (no network round-trip). The final app code-sign (which runs *after* this phase) re-seals
   the bundle over the thinned dylib, so the whole-app signature is valid.
3. **Drop internal docs:** globs `*.md` out of `Contents/Resources`. The synchronized file group
   sweeps everything under `Documentation/` into the bundle as resources (~150 KB of markdown).
   They're public in the repo and never read at runtime, so they're dead weight. Globbed, so new docs
   are dropped automatically — no per-file maintenance.

## Gotchas / receipts

- **`ENABLE_USER_SCRIPT_SANDBOXING` is set to `NO`** for the target. Xcode 16's default (`YES`)
  sandboxes run-script phases to declared input/output files only, which made `lipo` fail with
  `Operation not permitted` and would also block `codesign`'s keychain access on Developer ID builds.
  This is trusted, auditable build tooling, so sandboxing is off.
- **The phase must stay last** (after Sources/Frameworks/Resources) so it runs after the dylib is
  embedded and after resources are copied, but before the final app code-sign.
- **Verify quickly:** `lipo -archs <app>/Contents/Frameworks/libCLiteRTLM_mac.dylib` → `arm64`;
  `codesign -d --verbose=2 <dylib>` → `flags=0x10000(runtime)`;
  `codesign --verify --deep --strict <app>` → silent/exit 0; `find <app> -name '*.md'` → empty.
- **Dropping x86_64 drops Intel Mac support** — a deliberate decision (the on-device Gemma inference
  needs Apple-Silicon Metal anyway). If an Intel build is ever wanted, ship it separately.

## Not done (future size wins)

- **Strip symbols** from the arm64 slice (`strip -x -S`) → another ~14 MB (→ ~47 MB dylib). Deferred:
  it's a prebuilt dynamic lib, so test a full inference batch (incl. an Engine reload) before trusting
  it, and it must run before signing.
