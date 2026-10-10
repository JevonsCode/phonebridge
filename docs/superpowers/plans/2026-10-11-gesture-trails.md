# Operation trails implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Make AI-issued tap/long-press/swipe actions visible on the phone, with a saved default-on toggle, without interfering with control or observations.

**Architecture:** A small service-owned non-touchable accessibility overlay draws one transient animation. Each subsequent RPC first removes only that overlay and waits for removal to settle, then executes existing validation. A native boolean preference and existing MethodChannel connect the Flutter Settings switch; no pairing, consent, permissions or protocol changes.

**Tech stack:** Kotlin Android AccessibilityService/WindowManager/Canvas animation; existing Handler/main executor; Flutter/Dart Settings.

## Task 1: Native visualization and Flutter preference (single implementer)

**Files:** Create `mobile/android/app/src/main/kotlin/dev/phonebridge/phonebridge/OperationTrail.kt` (view/controller) and a focused preference helper if needed. Modify `PhoneAccessibilityService.kt`, `BridgeSession.kt`, `MainActivity.kt`, `mobile/lib/main.dart`, `mobile/lib/app_language.dart`. Add focused JVM timing/cleanup tests only for extracted production logic; add `mobile/test/operation_trail_test.dart` or expand existing widget tests for preference behavior.

- [ ] Inspect actual method dispatch, click-node handling, lifecycle and screenshot window/epoch checks. Graph is indexed as phonebridge-service-recovery but line ranges may be stale; verify actual source.
- [ ] Define a small overlay controller: exact owned view identity; one current animation; default blue dot/ring, long-press hold, swipe path reveal plus moving dot. Coordinates physical-screen based; account overlay placement/insets. Use TYPE_ACCESSIBILITY_OVERLAY with NOT_TOUCHABLE, NOT_FOCUSABLE, excluded accessibility descendants. No new permission.
- [ ] Add independent saved boolean `showOperationTrails`, default true, get/set through dev.phonebridge/control. Turning false immediately removes animation; failed preference save retains previous value and localized feedback. Expose one Settings switch with Chinese/English label and concise explanation.
- [ ] Insert visualization only for accepted real gestures and successful accessible node clicks. Never replay or report an action failed because visualization failed. Cancellation clears trace. Keep actual action result semantics unchanged.
- [ ] Before all subsequent RPC window checks, remove exact owned trail and settle WindowManager/compositor asynchronously with bounded main-thread frame scheduling; do not block UI, add fixed multi-second sleeps, weaken unrelated overlay checks or pollute screen nodes. Address own overlay accessibility events/epoch so screenshot validation stays meaningful.
- [ ] Clear overlay on preference off, stop/disconnect, service interruption/unbind/destroy and display/config changes. Bounded lifetime, no background animation loop without an active trace; maintain no history/manual-touch capture.
- [ ] Run `C:\src\flutter\bin\flutter.bat analyze` and `flutter test --reporter compact` in mobile. For native tests use process-only PHONEBRIDGE_NDK_PATH from primary `artifacts/android-sdk/ndk/28.2.13676358`, then mobile/android/gradlew.bat :app:testDebugUnitTest. No competing Gradle jobs.
- [ ] Report source changes and exact tests; no APK builds, installs, version bump, commits, pushes or device changes by implementer. Parent handles release; leave implementation reviewable in worktree.

## Task 2: Review and real device proof (parent)

- [ ] Spec compliance review, then independent code quality review; implementer repairs confirmed findings and re-review until clear.
- [ ] Parent bumps version to 0.2.6+10, builds final ARM64 preview APK using official manifest and existing signer. Verify versionCode 2010, exact cert and manifest; save final artifact/hash.
- [ ] Install update using authorized ADB, then ordinary `adb shell am start -n dev.phonebridge.phonebridge/.MainActivity` without -S. Confirm retained pairing, enabled accessibility/actions and automatic reconnect.
- [ ] Record physical display with ADB screenrecord (read-only capture) while using PhoneBridge RPC for tap, node click and swipe. Extract representative video frames to verify dot and path alignment; test immediate consecutive actions, state/screenshot reads, toggle off and restored on. Verify settings in both languages and saved preference.
- [ ] Restore phone to owner’s normal Follow system and default-on traces. Read back installed APK hash. Document any limitations honestly; do not publish unverified claimed animations.

## Task 3: Distribution and release (parent)

- [ ] Prepare Obtainium official-source config (includePrereleases true because all current versions are previews), documented direct link, and truthful GitHub topics/description. Directory criteria are unmet (4 months and 35 stars), so no fake listing claim or unsuitable PR.
- [ ] Prepare F-Droid submission material, record required release-build/signing/update-consent adaptation and account prerequisites; submit only if actually eligible and authenticated. IzzyOnDroid AI-code policy rules this project out; Aptoide manual distribution is subscription-based, so do not pay or submit there.
- [ ] Update generated official update manifest, website direct APK URLs/mock version, README and verification record. Commit reviewed changes, fast-forward primary, push main, create preview GitHub Release with direct APK.
- [ ] Verify asset digest/size/download HTTP status, published manifest, bilingual website links and App check updates. Confirm code CI and Pages success. Keep screenshots/recordings/private keys/device identifiers in ignored artifacts; cleanup temporary capture/server processes.
