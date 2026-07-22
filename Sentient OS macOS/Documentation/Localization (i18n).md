# Localization (i18n) — English + Russian

Engineering reference for in-app localization and model response language. Closes the user-facing
gap in [#267](https://github.com/Sentient-OS-Labs/sentient-os/issues/267) (app language ≠ macOS
language) and delivers the first locale for [#264](https://github.com/Sentient-OS-Labs/sentient-os/issues/264).

**Shipped in this change:** String Catalog (**en** development + **ru**), Settings → System →
**Language** (App language, Response language, optional Speak replies), STT locale tied to App
language on macOS 15/26, and live prompt injection so Sidekick / proactive / gift-letter prose can
follow Russian without storing language instructions in user-editable fields.

> **PR hygiene:** include screenshots or a short screen recording of Settings → System on **English**
> and **Russian** (CONTRIBUTING). Menu bar extra strings were **not** wired in this branch — see
> [Out of scope](#out-of-scope--follow-ups).

---

## Why this exists

Many users run macOS in English but want Sentient's UI, voice input, and AI-written cards in
Russian (or the inverse). macOS `preferredLanguages` alone does not match product intent when
App language should diverge from the system. Response language is intentionally **separate** from
UI language so power users can keep English chrome while forcing Russian model output (or follow App
language by default).

---

## What changed (product surface)

| Layer | User-visible behavior |
|---|---|
| **UI copy** | Menus, Settings (all five panes + privacy/uninstall sheets), onboarding, home chrome, notch labels, connect/permission gates, Knowledge viewer chrome, update notices — via `Localizable.xcstrings`. |
| **App language** | Settings → System → **App language**: System / English / Russian. System follows the Mac; English and Russian force SwiftUI `locale` on root scenes (`.appLanguage()`). |
| **Response language** | Settings → System → **Response language**: Same as app / English / Russian. Injected into prompts on **every** AI call (not stored in Proactive instructions). |
| **Speech-to-text** | Hold-to-talk uses locales derived from App language (`preferredSpeechLocale`, candidate list). Russian avoids silent fallback to en-US (phonetic Latin). macOS 26: `SpeechAnalyzerEngine`; may fall back to `SFSpeechRecognizer` when the on-device SpeechTranscriber asset is unavailable but Dictation Russian is. |
| **Text-to-speech** | Opt-in **Speak replies** (`tts.speakReplies`): reads Sidekick outcome lines via `AVSpeechSynthesizer`, voice locale from resolved Response language. Off by default. |

**String Catalog scale (this branch):** ~665 keys in `Localizable.xcstrings`; Russian translations
present for the bulk of shipped UI strings (keys without `ru` are typically verbatim brands, runtime
status, or Dev-only surfaces left in English).

---

## Architecture

### String Catalog — `Localizable.xcstrings`

- Single source for UI strings: English keys in Swift, translations in the catalog.
- Project: `knownRegions` includes `ru`; `developmentRegion` stays `en`.
- SwiftUI: prefer catalog-backed keys (`Text("…")`, `LocalizedStringKey`).
- Strings **outside** the SwiftUI environment (banners, dynamic status, uninstall steps) use
  `String(localized:locale: AppLanguage.resolvedLocale)`.
- **No Cyrillic in `.swift`** for UI copy — only in the catalog (prompt-layer Russian in
  `ResponseLanguage` is intentional, model-facing only).
- Verbatim runtime text: `Text(verbatim:)`, `MonoCaps(verbatim:)`, `SettingsProse(verbatim:)`.

### `AppLanguage` — `System/AppLanguage.swift`

- Key: `app.language` → `system` \| `en` \| `ru`.
- `localeOverride` → `.environment(\.locale)` via `View.appLanguage()`.
- `AppLanguage.resolvedLocale` for non-SwiftUI resolution.
- STT helpers: `preferredSpeechLocale`, `wantsRussianSpeech`, `speechLocaleCandidates`,
  `allowsEnglishSpeechFallback` (false when Russian STT is requested).
- **System** uses the Mac's **primary** language only for Russian detection — not a secondary `ru`
  in `preferredLanguages` while UI is English.
- Notification: `.appLanguageDidChange` → `AppState` prewarms Russian on-device speech assets.

Root scenes applying `.appLanguage()` live in `Sentient_OS_macOSApp.swift` (main windows + computer-use gate). Notch host uses the same modifier where applicable (`ComputerUseGate`).

### `ResponseLanguage` — `System/ResponseLanguage.swift`

- Key: `response.language` → `same` \| `en` \| `ru`.
- `resolved` maps Same as app → `AppLanguage` (System → primary Mac language).
- `promptBlock` / `promptLine` prepend a **CRITICAL** language section to prompts.
- **Never persisted** in `proactive.instructions` or other user-editable stores — computed live per
  request. `main.swift` strips misplaced language lines from stored proactive instructions on
  launch; `CustomInstructions` documents the behavior in Settings copy.
- Machine contract stays English: `STATUS: DONE` / `STATUS: COULD_NOT`, JSON keys, tool names.

**Wiring (grep `ResponseLanguage` when extending):**

- Sidekick: `CommandRunModel.commandPrompt`
- Proactive judge / research / executor: `Proactive.swift`, `ProactiveResearch.swift`, `ProactiveExecutor.swift`
- Gift letter: `GiftLetter.swift`

### `SpeechOutput` — `System/SpeechOutput.swift`

- Key: `tts.speakReplies` (default off).
- `CommandRunModel` calls `SpeechOutput.speak` on outcome lines (skips demo runs); `stop()` on new runs.

### STT pipeline — `Notch Magic/`

```
VoiceCapture → (macOS 26+) SpeechAnalyzerEngine
            → fallback SFSpeechRecognizerEngine (macOS 15, or RU asset unavailable + Dictation ru)
```

Locale selection and install/prewarm logic: `SpeechAnalyzerEngine.swift`, `SFSpeechRecognizerEngine.swift`, `VoiceCapture.swift`, `CommandCoordinator.swift`, `AppState.swift`. Russian model download can be triggered when App language becomes Russian (`VoiceCapture.prewarmRussianSpeechIfNeeded()`); System pane shows a quiet downloading whisper while `VoiceCapture.isModelDownloading`.

---

## Settings UI

`SystemPane.swift` — new **Language** group at the top of System:

1. App language picker + prose.
2. Optional whisper while Russian on-device speech model downloads.
3. Response language picker + prose (explains live injection, not editable prompts).
4. **Speak replies** toggle.

Other panes use catalog keys and, where needed, `AppLanguage.resolvedLocale` for formatted strings
(`ComputerUseSpeed`, uninstall copy, etc.). See `Settings.md` for pane layout; language prefs are
documented here.

---

## How to test

1. Open `Sentient OS macOS.xcodeproj`, set signing via `Signing.local.xcconfig` (see CONTRIBUTING).
2. **App language**
   - System + macOS English → UI English on covered screens.
   - App language **Russian** → Settings / onboarding / home chrome / Knowledge headers in Russian.
   - Quit and relaunch → preference persists.
3. **Response language**
   - Russian + English UI → morning cards / Sidekick user-facing phrases should trend Russian
     (model-dependent); verify prompt injection by changing only Response language without editing
     Proactive instructions.
   - Remove any manual "write in Russian" from Proactive instructions → language should still follow
     Response language after relaunch (strip + live injection).
4. **STT** (hardware / macOS version dependent)
   - App language Russian, hold Sidekick key → transcript in Cyrillic or a clear model-unavailable
     error — not phonetic English.
   - First Russian use may download Apple's on-device asset; watch System pane whisper + logs.
5. **TTS**
   - Enable Speak replies, fire a short Sidekick command → Mac speaks outcome in Response language locale.
6. Build Debug/Release; fix any missing catalog key warnings before merge.

---

## Editing translations

1. Edit `Sentient OS macOS/Localizable.xcstrings` in Xcode (or merge-friendly JSON).
2. Add English source string in Swift if new UI; add **ru** column for user-visible copy.
3. For a third language later: add region to `knownRegions`, duplicate localization entries, extend
   `AppLanguage` / `ResponseLanguage` enums and Settings pickers — no new architecture required.

---

## Out of scope / follow-ups

| Area | Notes |
|---|---|
| `Views/Dev/*` | Dev Tools remain English. |
| `Views/MenuBarView.swift` | Not modified — menu extra may stay English until wired. |
| Brands / model names | Verbatim (`GPT-5.6 Sol`, product names). |
| Runtime Codex / harness status | Live strings, not catalog. |
| `Cloud/AgentStatus.swift`, `STATUS:*` sentinels | Parser contract — English. |
| `Vault/*`, `Engine/Triage.swift` | Deferred per #264 discussion. |
| `Vendor/*` | Third-party code untouched. |
| AI body text (cards, letters) | Language via Response language prompts, not `.xcstrings`. |
| Full legal Privacy Policy translation | Policy view uses catalog where wired; long legal body may remain EN. |
| `DEVELOPMENT_TEAM` in pbxproj | Must not appear — use `Signing.local.xcconfig` only. |

---

## Files to know (by job)

| Job | Path |
|---|---|
| Catalog | `Localizable.xcstrings` |
| UI locale | `System/AppLanguage.swift` |
| Model locale | `System/ResponseLanguage.swift` |
| TTS | `System/SpeechOutput.swift` |
| Proactive strip on launch | `App/main.swift` |
| STT prewarm | `App/AppState.swift` |
| Settings controls | `Views/Settings/SystemPane.swift` |
| Shared settings widgets | `Views/Settings/SettingsComponents.swift` (`MonoCaps`, prose helpers) |
| STT | `Notch Magic/VoiceCapture.swift`, `SpeechAnalyzerEngine.swift`, `SFSpeechRecognizerEngine.swift` |

---

## Maintainer checklist (merge)

- [ ] Screenshots: Settings → System EN + RU (and one home or notch shot if easy).
- [ ] No `_design/` or signing team IDs in the diff.
- [ ] CLA green for contributor.
- [ ] Issues #264 / #267 linked in PR description.
- [ ] Spot-check: Russian STT on a Russian-preference Mac (26+ preferred) if reviewer has hardware.
