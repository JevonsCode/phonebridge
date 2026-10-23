# PhoneBridge 0.7.0 developer preview

This release combines [multi-device control and FIFO handoff (#8)](https://github.com/JevonsCode/phonebridge/pull/8) with [owner app-access editing and Select all (#9)](https://github.com/JevonsCode/phonebridge/pull/9).

## Changes

- Connect multiple phones to one computer and multiple paired computers to a phone. AI clients select a phone, request control, wait their turn, and release control when done. A task remains bound to its selected phone connection.
- Choose allowed Apps on the phone. Select all applies to eligible Apps in the current search results; individual Apps can be unchecked before Save. Per-computer grants survive reconnects and upgrades. The editor blocks remote observation and actions while authorization is being changed.
- Choose screen-awake behavior: Off, During control, or Always while the accessibility service runs. Manual screen-off and lock take priority.
- Send a local file from the desktop window or `phone_send_file`; receive it on the phone and choose a sharing App and recipient. Files are stored under Download/PhoneBridge. No contact is selected automatically.
- The bilingual website now includes Apple Silicon and Intel Mac downloads, updated setup instructions, authorization controls, file transfer and operation history. The update illustration no longer offers APK download when already current.

Upgrade both the desktop client and Android App, then reconnect your AI client's MCP session to load the new tools. Existing pairing and phone grants are retained. Android 11+ ARM64; Windows 10/11 x64; macOS 13+ Apple Silicon or Intel.

## Verification (2026-10-23)

- Integrated source: Bridge production build and 92 tests passed (one platform skip); desktop/distribution Node suites 78 passed (seven platform/explicit-LAN skips); desktop Flutter analysis and 38 tests passed. Integrated Android authorization source passed Flutter analysis, 105 Flutter tests and 145 native JVM tests across 20 suites. Website language suite: nine passed.
- Final signed Android APK: version 0.7.0, ARM64 versionCode 4024, 38,587,388 bytes. SHA-256: `346f9e7f7ad5c1812d14d83ce44441b8ad0c15e5166b8da6d5cc0a9270857b55`. The preview signer matches previous releases. This APK upgraded the existing Android 16 phone without uninstalling it; first-install time, original pairing, three allowed Apps and enabled actions remained intact.
- The Apple Silicon Mac installation upgraded from 0.6.2 to 0.7.0. Its pairing file was unchanged; the current-user service restarted and the real phone reconnected. The final packaged App passed its isolated self-test, read-only diagnostics and code-signature verification. These isolated tests use fixtures and do not substitute for the physical connection test.
- Two independent MCP processes on this Mac used one physical Android phone: first active, second queued, queued observation rejected with `CONTROL_QUEUED`, then release notification granted the second process control. The new owner read the phone successfully. Chrome launch/read still worked with the owner's existing grant; the phone returned to PhoneBridge afterward. Operation history included the actual calls.
- With the existing During control preference, Android reported the PhoneBridge display wake lock while control was active and no such wake lock after release.
- LAN file transfer used the repository's public brand PNG as test data, not private phone content. The 19,807-byte received file matched SHA-256 `28088c0bbd45666a20d16744083975ea9491cfeda39ba4306573f3a4c3e8ffd1`. The system share chooser opened with a WeChat entry; no recipient was selected or message sent. A separate Mac-window transfer displayed the phone's successful receive acknowledgement.
- One Mac-window transfer lost its phone connection after its offer. The desktop reported an uncertain result and the phone marked that transfer failed. After checking the failure and reconnecting, a new transfer completed. No crash was observed; the isolated disconnect's cause was not established and it was not reproduced in the subsequent transfer. Commands were not automatically replayed.
- Desktop binaries came from successful [cross-platform CI](https://github.com/JevonsCode/phonebridge/actions/runs/39971578022). Their desktop/Bridge/package inputs were compared with the integrated release source and were identical. All six desktop binary SHA-256 sidecars matched downloaded artifacts. Windows and Intel Mac runtime/packaging checks ran in CI, not on additional physical machines.
- Website inspected in the user's real Chrome, including Chinese and English at 390px with no horizontal overflow and desktop layout. Illustrations remain synthetic HTML/CSS/SVG. Download URLs and the APK QR are finalized by the release-distribution workflow after publication.

## Limits

One physical phone and one physical Mac were used; two physical computers, multiple real phones, full Mac reboot/login and long unattended operation remain unverified. App selection and its safety/error cases use automated fixture tests; this run did not expand the owner's real allowed-App list. Cross-network access, all third-party App workflows and WhatsApp delivery are not claimed. APKs retain the development preview signer; Mac packages are ad-hoc signed and are not Apple Developer ID notarized.
