# App authorization repair implementation plan

**Goal:** Preserve application grants when re-pairing the same computer and let the phone owner inspect/edit the active computer's grants without re-pairing.

**Architecture:** Keep Android as the authority. Resolve implicit pairing defaults against the exact saved endpoint/token identity; explicit owner edits replace, never union, the grants. Expose local-only grant snapshots and a launchable-app picker through the existing MethodChannel. A policy change closes only the selected computer's transport and invalidates its old operation snapshot before saving/reconnecting; other peers stay online. The editor revision is separate from the AI operation generation, so normal control handoffs cannot retarget or stale the editor. No new remote authorization tool or expanded Android permission.

**Authorization:** User requested the repair and then explicitly requested a PR, authorizing the necessary commit and branch push. Create a PR against main; merging or publishing a release is outside this step. Preserve existing pairing data and signing identity. Use DingDong when device/user participation is needed.

**Files:** Kotlin TrustedComputers/BridgeSession/MainActivity plus local AppAccess catalog; Flutter app_access.dart, main.dart and app_language.dart; Kotlin policy tests and Flutter owner-flow tests.

- [x] Add failing regressions for same-identity re-pair, explicit revocation, distinct computer isolation, visible owner entry, save read-back, cancellation and failed/stale save.
- [x] Implement identity-aware connection grant resolution and native local snapshots/catalog/update. Validate 1–64 package names, compare original computer and grant snapshot, preserve disconnected/paused state, and invalidate old session before changing active policy.
- [x] Add a searchable app-name checkbox page with a Save action and explicit local errors. Show it from home, settings and pairing; preserve uninstalled saved packages in the picker. Keep pair defaults implicit unless owner edits them.
- [x] Update Chinese/English messages. Test narrow layouts and high text scale using Flutter widget tests.
- [x] Run focused red/green tests, full mobile tests, analyze, native unit tests and signed ARM64 release build. Verify signer matches existing public release.
- [x] Preserve-data update verified on USB phone: remembered computer/actions and Chrome grants survived upgrade; Chrome launch/state passed. Same-computer re-pair remains unit-tested only; no destructive real-device identity change was performed.

## Invariants and acceptance

- Same endpoint/token plus untouched picker uses the saved list; changing either identity component never borrows another computer's grants.
- Explicit removal stays removed; no merging with old grants. General action consent remains separate.
- The edit page uses native saved/runtime snapshots, not the pairing text controller. Stale identity/list submissions fail visibly.
- Empty/invalid lists fail before mutation. Cancel does not call the mutation method. Save only succeeds after native read-back confirms the result.
- Local tests may use synthetic app names/identities and fake MethodChannel responses; they are test fixtures, not claims about the user's phone.

## Follow-up: select all (owner request)

Add one `全选` action beside the selected count, then allow ordinary individual deselection. No invert/clear-all action. With a search query, label it `全选搜索结果` and affect only matching installed, non-protected apps. Existing uninstalled/protected grants are preserved for individual removal. The button only edits the local draft; native access changes after Save. Keep the native 1–64 limit, never silently truncate bulk selections, and show an immediate over-limit message with a recovery action in the wording. Use the existing theme and wrapping layout for narrow/large-text screens.

- [x] Add failing widget coverage for select-all then individual removal, search scope, protected/uninstalled exclusions, cancellation, and over-limit handling.
- [x] Implement the one button and Chinese/English labels in app_access.dart / app_language.dart.
- [x] Focused 10 / full 99 Flutter tests and analyze passed; built and installed original-signer 0.6.4-jvs-a.2 (4023). Chrome launch/state passed after upgrade; real screen shows 全选 beside 已选择 3 / 64. Bulk selection interactions are widget-tested; no real phone grants were expanded for testing.

Chrome owner-save verification succeeded before this follow-up: launch_app completed and state returned com.android.chrome with 102 nodes (device-chrome-after-save.json). Re-pair on the real phone remains covered only by unit regression tests, not claimed as a device test.

## Integration with current main

Rebased onto bdc6ebb (multi-device AI control). Native edits now read the selected computer's persisted record (or its temporary transport), use a dedicated local editor revision, and update/reconnect only that computer. The existing control lease, operation completion fence and multi-transport lifecycle remain intact. Remote operations are rejected before dispatch while the editor is open and rechecked in the accessibility service.

- Full Flutter suite: 105 passing; analyze: no issues.
- Android unit suite: 145 passing across 20 suites, including queue/lease and gesture settlement regressions.
- Earlier signed-build device results (Chrome permission save, upgrade persistence and visual all-select check) were taken before this integration. The integrated multi-computer policy path has automated/build evidence; it has not been re-tested with two physical computers.
