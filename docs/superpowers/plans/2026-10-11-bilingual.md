# PhoneBridge bilingual implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a coherent Chinese/English website and App, preserve existing trust and upgrade the current phone.

**Architecture:** Two static website pages share language navigation, clipboard feedback and styles. Flutter uses a small inherited localization layer and supported localization delegates; Android preferences persist the manual locale without touching pairing. Android resources localize native visible strings.

**Tech Stack:** Static HTML/CSS/JavaScript, Flutter/Dart, Kotlin, Android resources, GitHub Pages/Releases.

### Task 1: App localization

Files: `mobile/lib/app_language.dart` (new); `main.dart`, `pairing.dart`, `pairing_scanner.dart`, `app_updates.dart`, `design.dart` as needed; `mobile/pubspec.yaml`; Android `MainActivity.kt` and visible-text resources; `mobile/test/app_language_test.dart` (new), existing tests if language setup requires it.

- [ ] Define getLanguagePreference/setLanguagePreference on the existing control MethodChannel with `system`, `zh`, `en` values and persist in a separate app-language preference. Missing-plugin tests remain usable and do not trigger disconnects.
- [ ] Implement a Flutter locale owner above existing ConnectionPage, keep its state and timers intact across language changes, support system-locale changes, and use Flutter localization delegates.
- [ ] Translate all shipped visible copy using a small centralized translation class/dictionary; localize known protocol/error messages without displaying raw English/Chinese fallbacks in the wrong language. Map system native dialogs to Android resources; leave machine logs/protocol identifiers intact.
- [ ] Add the three-option settings selection and meaningful tests for default resolution, remembered selection, settings changes retaining connection/actions, updater errors, and English narrow-screen layouts.
- [ ] Run `C:\src\flutter\bin\flutter.bat analyze` and `... test --reporter compact` in `mobile`; compile/test native code with the existing working process-specific NDK. Expected: no analysis issues, all tests pass. Keep version bump/build/publication to parent.

### Task 2: Website localization and illustration

Files: `website/dist/index.html`, `en/index.html` (new), `language.js` (new), `main.js`, `style.css`; source checks/scripts if needed under `website`.

- [ ] Translate all text, labels and metadata into a complete static English page. Add alternate/canonical URLs and working relative assets, header links and active language semantics on both pages.
- [ ] Implement early root-page selection using stored manual choice, otherwise `navigator.languages[0]`/`navigator.language`; Chinese for zh variants, English otherwise. English URL remains explicit; preserve hashes, catch storage errors, and persist actual manual link clicks. Scripts must not redirect in loops or render a blank page on failure.
- [ ] Localize clipboard feedback using document language and preserve native links/FAQ behavior without JavaScript. Update phone illustration to current App style plus a compact About update-card illustration; synchronize Chinese/English captions.
- [ ] Check local pages with browser automation: fresh zh/en, switch both ways, remembered preference/reload, inaccessible storage, direct English entry, copy/FAQ, mobile 390 and 320, desktop 1440. No horizontal overflow or clipped language controls. Direct APK links target v0.2.5 after final build.

### Task 3: Review and real-device validation

Files: `mobile/pubspec.yaml`, ignored final/bootstrap APK artifacts and fixture scripts; no private material committed.

- [ ] Request spec-compliance then quality reviews for the complete diff, repair material findings, rerun only affected checks.
- [ ] Bump to 0.2.5+9, build official-source ARM64 APK with existing signing key; validate aapt version/source and signer. A private newer-code bootstrap may be used to test update flow before publishing.
- [ ] Install on the current phone without resetting data. Use App RPC for UI taps/screenshots, ADB for authorized installation/read-back diagnostics only. Verify Chinese, English and system choice, About layout and language persistence, live connection and retained action consent, installed APK hash and unchanged pairing identity. Ask owner only for actual OS prompts or foreground opening.

### Task 4: Publish

Files: `README.md`, `docs/verification.md`, `website/dist/update.json`.

- [ ] Remove requested tagline, update direct APK links and verification evidence, construct manifest from exact final APK hash/size/version. Do not publish test bootstrap.
- [ ] Commit reviewed changes, fast-forward primary checkout, push to main and create v0.2.5 developer-preview release with the raw ARM64 APK.
- [ ] Verify asset digest/size/HTTP availability, GitHub Pages deployment, both public language URLs and official About version detection. Stop private fixture and preserve desktop service.
