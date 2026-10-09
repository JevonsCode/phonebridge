# Verification record

This document records evidence, not planned capabilities. Update it when tests finish. No private phone data, screenshots, tokens or serial numbers belong here.

## Automated evidence

| Layer | Check | Result |
|---|---|---|
| Desktop | TypeScript production build | Passed |
| Desktop | 14 node:test cases, including actual MCP stdio + hub + simulated phone | Passed |
| Flutter | Static analysis | Passed with no issues |
| Flutter | Consent, stop, token cleanup, playground widget tests | 4 passed |
| Native | Endpoint, session, read-only, notification, observation and geometry JVM tests | 18 passed, confirmed from Gradle JUnit XML (0 failures/errors) |
| Android | Normal debug APK compilation | Passed after runtime fixes; test entrypoint excluded |
| Android 11 emulator | Real accessibility service integration | Passed: UI tree, real JPEG screenshot, actual counter click, focused Unicode input, read-only/allowlist/stale-ID/stop refusal |
| Physical Android 16 device | Install and owner-authorized test | Installed and accessibility enabled by owner; pairing in progress |
| WeChat | Real visible-UI reading/navigation | Not yet tested |

Simulated phone tests validate the desktop protocol, not Android behavior. Widget tests mock the platform channel and do not validate AccessibilityService. JVM tests cover pure policies, not window/gesture behavior. A successful build alone does not establish runtime compatibility.

## Repeatable Android test

Use an isolated emulator with Android 11 or newer. Build and install PhoneBridge, enable its AccessibilityService through settings, then connect an authenticated local hub via `adb reverse tcp:8765 tcp:8765`. `flutter test` may reinstall the package and clear its permission, so re-enable the service after test installation while the test waits. Supply `--dart-define=PHONEBRIDGE_TEST_TOKEN=<private temporary token>` to:

```text
flutter test integration_test/native_bridge_test.dart -d <emulator-id> --dart-define=PHONEBRIDGE_TEST_TOKEN=...
```

The integration test uses local platform-channel calls to configure a test session, sends commands through the real hub/socket/service, and verifies read-only refusal, visible nodes, a decodable screenshot, actual counter tap, Unicode text, stale IDs, blocked launch, and stopped access. It never adds test entry points to production native code. Rebuild the normal APK before release: integration APKs contain test code and must not be distributed.

Windows helper: `./scripts/test-emulator.ps1 -Serial emulator-5580`. It accepts emulator serials only, starts an isolated localhost hub on port 8766 with an in-memory random token, restores the emulator's test service after Flutter reinstall, and cleans up the hub/port mapping. Flutter integration tests explicitly allow real device pointer events, otherwise their test binding intercepts Android gestures. The app never contains this test setup logic.

## Device matrix to expand

- Android 11 screenshot callback and Android 14+ window screenshot behavior.
- Target device ROM/Android version, with service enabled manually by its owner.
- Rotation, keyboard overlap, split-screen and floating windows: refuse rather than operate on foreign windows.
- Lock device during capture/action, turn off action consent, revoke accessibility, disable the session notification channel, stop via notification.
- Disconnect during gesture: no new commands accepted; Android may finish an already-dispatched gesture (bounded to two seconds).
- WeChat installed version: identify visible messages only, scroll/search and verify the resulting screen. Do not send messages during a read-only smoke test.
- Sleep/background pressure: record disconnections; do not claim indefinite unattended operation.
