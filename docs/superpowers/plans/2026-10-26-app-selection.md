# App selection implementation plan

**Goal:** Make bulk app selection reversible and remove the arbitrary app-count ceiling.

**Architecture:** Keep the local Flutter draft/editor and native saved pairing contract; centralize native package validation without changing transport or queue limits.

**Tech Stack:** Flutter/Dart, Kotlin/JUnit.

- [ ] Extend widget regressions for checkbox state, clearing filtered/all selections, empty results, unavailable grants, and saving 65+ apps. Observe failures before fixing.
- [ ] Replace the text action with a tri-state CheckboxListTile and remove count-limit UI/errors.
- [ ] Centralize native package validation without count ceiling; verify large grant save/restore and invalid package rejection.
- [ ] Run mobile analyze/widget suite and native JVM tests/build; independent focused review.
- [ ] Commit/push JVS/app-selection-checkbox and submit an open PR with actual evidence.
