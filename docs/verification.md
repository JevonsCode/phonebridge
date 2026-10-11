# Verification record

This document records evidence, not planned capabilities. Update it when tests finish. No private phone data, screenshots, tokens or serial numbers belong here.

## v0.6.0 (2026-10-11)

- Android 16: installed the ARM64 preview as an update. PackageManager reports 0.6.0 / 2011. Reading the installed APK back gives SHA256 `EFD253B35689CCADA1D4F3B142C7858D4AE54910C6BA76CC4BF152C8762A88C3`; the original first-install date, pairing and action consent were retained.
- Operation trails default to enabled with no stored preference. Switching off writes a separate display preference; an actual APK update retained the off selection. The setting was restored to on. A final-APK rapid run of 20 rounds × tap/tap/state/tap/screenshot completed 100 operations without errors. A prior build using the same trail/capture implementation was recorded for tap, hold, moving swipe dot/line and fade. Trails are excluded from App screenshots. Rotation and long-duration background pressure remain outside this physical test.
- Remembered computers: a test-only instrumentation APK seeded a secondary local endpoint inside the phone's encrypted store. The real App UI switched between two independently running endpoints without rescanning, renamed the primary computer, retained per-computer action consent after an actual APK update, and deleted only the selected secondary entry through the UI. The secondary read-only connection could observe but rejected taps. Original primary trust was restored, the test endpoint stopped, and the helper APK uninstalled. This used two services on one physical computer, not two physical computers or simultaneous control.
- Native JVM suite: 85 tests, zero failures/errors. Flutter analysis and 66 widget/unit tests passed before the final build. Website language suite: 9 passed; real browser first-English selection, manual Chinese/English switching, updated App illustration and 1280/390px layouts checked without horizontal overflow.
- Windows self-contained installer: the final setup upgraded the existing current-user installation successfully, retained the credential file digest and migrated the owned managed task. Startup repaired the physical Start menu shortcut to the final bundle. An MSIX-shadowed old shortcut was left untouched; a visible Desktop shortcut was created instead. Native Windows PowerShell 5.1 tests also cover an inherited PowerShell 7 environment. The final installed client panel showed the connected phone and generated configuration using its bundled runtime; the Copy MCP button showed success. Clipboard contents were not independently read back. Full Windows reboot/login is not claimed.
- LAN connection: the reviewed installed helper completed owner-approved elevation, created the TCP service-port rule for Private/LocalSubnet, and removed only the current runtime's Windows-generated TCP block. A second read-only plan required no changes. The phone reconnected without rescanning or renewed phone consent, and remained connected after another managed service restart.
- Persistent history: final packaged stdio MCP lists `phone_operation_history` with read-only annotation. Actual PhoneBridge tap and screenshot requests succeeded and were recorded as `completed/device_reported_success`; MCP retained their request IDs after managed service restart. Earlier refused commands while the phone was unreachable were correctly saved as `failed/not_dispatched`. History reports device/transport outcomes, not whether a third-party task achieved its purpose.
- Bridge suite after review fixes: 44 tests, 42 passed, 2 platform skips, no failures. Isolated tests cover persistence, rotation, text/image/token exclusion, unknown interrupted outcomes, malformed URL process survival and empty device error-code classification. Release-distribution suite: 45 passed. Windows source/package checks exercise PATHless runtime, identity reuse, duplicate launch, rollback and narrow LAN-rule planning without modifying test-host firewall policy.
- Published APK and Windows assets passed the actual [release-distribution workflow](https://github.com/JevonsCode/phonebridge/actions/runs/38097431823), including binary diagnostics, APK identity/hash/signature verification, update-manifest synchronization and Pages deployment. Source CI passed separately. Uptodown accepted the v0.6.0 submission with three real App screenshots; its console remains Pending revision, with no public listing claimed.
- During later store screenshot preparation, an operator accidentally selected Forget on the primary computer. This was a manual deletion after the successful upgrade/switch tests. The prior authorized identity was restored from the unchanged desktop credential using an ignored test-only diagnostic helper. Reinstalling the same official APK restored the ROM's accessibility binding without changing system consent. Fresh App clicks, screenshots and MCP history reads succeeded afterward; the phone was returned to Follow system with trails enabled. No recovery helper is included in the release.

The APK retains the preview debug signer. Market review, public availability, cross-network access and long unattended operation require separate evidence.

## v0.2.5 Chinese and English (2026-10-11)

- Flutter static analysis passed; all 56 Flutter tests passed, including language resolution, persisted selection, failed preference writes and retained connection state. Native Kotlin compilation and all 61 JVM tests passed.
- Website language tests: 9 passed. Real browser checks covered an English browser's initial redirect, manual selection retained after reload, command copying, FAQ expansion, and Chinese/English layouts at 1440, 390 and 320 pixels with no horizontal overflow. Storage-denied behavior is covered by the script tests, not a physical browser policy change.
- The final ARM64 APK was installed as an update on the existing Android 16 phone. PackageManager confirmed versionName 0.2.5 and versionCode 2009. Reading back the installed APK produced the exact final SHA256: `952EFEE54CAF20CF1BE96BE8BF887DCEE44135B29AD68A3A1F1A159D05AE27EA`. Original first-install time and saved desktop identity were retained.
- Through PhoneBridge's real accessibility actions, the phone switched from Follow system (Chinese) to English, back to Chinese, and back to Follow system. Home and Settings screenshots showed translated labels; actions stayed enabled and the connection remained active. Read-back preferences confirmed the saved selection. No new pairing or connection authorization was needed. Android OS language changes while the App is in the background have not been physically tested; the Activity and AccessibilityService callbacks are source-reviewed.
- Phone UI actions and screenshots used PhoneBridge over the local network. ADB was used to install the update and read diagnostic evidence; it was not used to tap the interface. The wireless transport is verified; food delivery, flight selection and cross-network remote operation remain suggested scenarios without end-to-end device evidence.
- The distributed APK uses the official HTTPS manifest and retains the existing debug signing identity. It remains a developer preview; no additional phone models or long-duration background behavior are claimed.
- A separate forced-stop/relaunch test confirmed the saved English language loaded on a fresh App process, but this ROM removed the enabled accessibility service when the package was force-stopped. The previously authorized service was restored, after which PhoneBridge reconnected and retained actions; the phone was returned to Follow system. Ordinary foreground launches must not use ADB's `-S` force-stop option. APK upgrade did not cause this permission loss.

## v0.2.4 in-app updates (2026-10-11)

- Flutter static analysis passed; 48 Flutter tests passed, including update state/event handling, About re-entry and a narrow screen with enlarged text. Native JVM suite: 61 tests, zero failures/errors, including 22 updater cases.
- Real HTTP sockets reproduce a stale pooled connection at response headers. The updater now reconnects for public GET requests; truncated APK bodies are rejected without replay, and incomplete files are removed.
- On the existing Android 16 phone, a private bootstrap App downloaded the exact final ARM64 APK from a temporary LAN fixture. The App verified it, opened Android's install-source settings and then the system installer. The owner approved the system prompts and opened the updated App. No ADB gestures or ADB installation were used for this upgrade.
- PackageManager confirmed versionName 0.2.4 and versionCode 2008. The installed APK was pulled back and its SHA256 matched the final APK: `7628AA943DCD4E9C7664EA67899AD1AA6426F1E35ABEF239A899919C443CBA08`. The original first-install timestamp was retained.
- The real App reconnected automatically with the existing identity. Its screenshot confirmed enabled actions; the saved desktop pairing file hash was unchanged. No new scan or connection authorization was needed.
- The distributed APK uses the official HTTPS update manifest. The LAN bootstrap is private test material and is not distributed. This device test proves the download, verification and installation flow using the LAN fixture; a full APK download from GitHub on the phone is not claimed.
- The APK remains debug-signed developer-preview software. Additional ROMs and long-duration background downloading are not claimed.

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
