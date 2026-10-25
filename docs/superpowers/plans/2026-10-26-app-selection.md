# App selection implementation plan

**Goal:** Make bulk app selection reversible and remove the arbitrary app-count ceiling.

**Architecture:** Keep the local Flutter draft/editor and native saved pairing contract; centralize native package validation without changing transport or queue limits.

**Tech Stack:** Flutter/Dart, Kotlin/JUnit.

- [x] Extend widget regressions for checkbox state, clearing filtered/all selections, empty results, unavailable grants, and saving 65+ apps. Observe failures before fixing.
- [x] Replace the text action with a tri-state CheckboxListTile and remove count-limit UI/errors.
- [x] Centralize native package validation without count ceiling; verify large grant save/restore and invalid package rejection.
- [x] Run mobile analyze/widget suite and native JVM tests/build; independent focused review.
- [x] Commit/push JVS/app-selection-checkbox and submit an open PR with actual evidence.

Validation: mobile analyze clean, all 110 Flutter tests passed. The new 300-app restore test failed against the original decoder; after the fix the complete release JVM suite passed. ARM64 release APK build passed; this is a build check, not a published or installed upgrade. Independent design and final code reviews found no blocking/important issues. Flutter commands and native Gradle checks must run sequentially: Flutter test/pub get changes generated plugin registration for dev plugins; regenerate via a release build before direct release Gradle checks.
