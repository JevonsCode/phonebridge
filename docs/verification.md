# Verification record

This document records evidence, not planned capabilities. Update it when tests finish. No private phone data, screenshots, tokens or serial numbers belong here.

## v0.2.3 service recovery (2026-10-11)

- TypeScript production build passed; 29 Node tests: 28 passed, one POSIX permissions case skipped on Windows. Real sockets cover management start, concurrent requests, HTTP/WebSocket forwarding, worker crash recovery without RPC replay, forced-parent cleanup, socket reuse and failed worker launches.
- Flutter analysis passed, 27 widget tests passed. Native JVM suite: 39 tests, zero failures/errors, including actual HTTP recovery requests and response validation.
- ARM64 debug APK installed as an update on the existing Android 16 phone (versionName 0.2.3, split versionCode 2007). Saved pairing and action consent survived; no new scan. App screenshot confirmed connected home and enabled actions.
- Real phone button test: desktop management endpoint remained running while Hub was deliberately stopped. Owner tapped "启动电脑服务"; the Hub started and the phone connected using its existing identity. App screenshot succeeded afterward.
- Windows current-user limited logon task installed and running. Deliberately killing the Hub recovered automatically. Killing the Supervisor recovered through the same running launcher, produced a new Supervisor/Hub process, and the real phone reconnected; pairing file hash remained unchanged. Full Windows reboot/login and long-duration background operation are not claimed.
- Website entry in App points directly to the canonical GitHub Pages website.
- Windows launcher containment checks passed under Windows PowerShell 5.1 and PowerShell 7. Real scheduled-task stop left zero Supervisor/Hub processes; starting the task restored the phone connection.
- SHA256 of the installed phone APK was read back and matched the release APK: `C46292BDE7FE6979570DEED0961C1570E7AEC4785986AB94F5C4A4E793BBD4CF`.

## Automated evidence

| Layer | Check | Result |
|---|---|---|
| Desktop | TypeScript production build | Passed |
| Desktop | 22 node:test cases, including actual MCP stdio on loopback/LAN, saved credential reuse from a fresh process, corruption refusal and private QR display | 21 passed; POSIX permissions case skipped on Windows |
| Flutter | Static analysis | Passed with no issues |
| Flutter | Pairing parser, scanner consent, saved trust/resume/forget, stop, token cleanup, test-only playground, retained action consent, pairing stop-button bottom inset, project link dispatch and pressed-surface clipping | 21 passed. The pressed pixel test fails on the original ClipRRect implementation and passes with a clipped local Material. |
| Native | Endpoint, session, read-only, notification, observation, geometry, pairing crypto and reconnect JVM tests | 34 passed, confirmed from Gradle JUnit XML (0 failures/errors) |
| Android | Normal debug APK compilation | v0.2.2 ARM64 split-per-ABI build passed; test entrypoint and playground excluded |
| Android 11 emulator | Real accessibility service integration | Passed: UI tree, real JPEG screenshot, actual counter click, focused Unicode input, read-only/allowlist/stale-ID/stop refusal |
| Physical Android 16 device | Install and owner-authorized test | v0.2.2 ARM64 installed. Home without playground and About with project links checked through App screenshots/taps. Existing pairing and action consent survived the update without scanning. Tapping GitHub reached the OEM external-app launch confirmation; browser navigation beyond that prompt is not claimed. Desktop Hub restart recovery was verified in v0.2.0. |
| Flutter layout | Narrow screen and enlarged text | Local render harness passed at 320 × 740 with 1.3× text on home/settings; pairing/manual form checked at 360 × 800. These are simulated layouts, not additional physical devices. |
| Public website | Browser and deployment | Sites public deployment succeeded. Live page loaded; local desktop 1440px and mobile 390px widths checked without horizontal overflow. Copy command and FAQ expansion verified in browser. |
| WeChat | Real visible-UI reading/navigation | Android 16: launched WeChat, visually identified the owner-requested recipient, tapped chat/input, inserted Chinese using accessibility InputMethod, tapped Send, verified outgoing bubble and empty input via App screenshot. No ADB UI input used; no claim of recipient reading. Node tree remains empty on this device; screenshot fallback verified. |

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
