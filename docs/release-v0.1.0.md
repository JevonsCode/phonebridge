# PhoneBridge v0.1.0 — developer preview

首个自用优先的开源预览版：用 Flutter + Kotlin 手机端把 Android 无障碍能力交给支持 MCP 的 AI 客户端。

## Included
- Owner-controlled pairing, read-only default, per-session action consent, application allowlist and Stop notification.
- UI tree, cropped JPEG screenshot, tap/long press/swipe, focused Unicode text entry, Back/Home/Recents and allowlisted app launch.
- Authenticated Node hub and eight MCP tools; bounded single-flight commands and no automatic retry of uncertain actions.
- MIT license, setup/security documentation, CI and repeatable tests.

## Verified
- 14 desktop protocol/MCP/image-validation tests.
- 4 Flutter widget tests and clean static analysis.
- 18 native Gradle/JUnit policy and geometry tests.
- Android 11 emulator end-to-end: real accessibility screenshots, actual button click, focused Chinese text entry, read-only/allowlist/stale-node/stop rejection.
- Normal debug APK builds successfully. Physical Android 16 installation and manual accessibility enablement succeeded; pairing/WeChat runtime verification is tracked separately in `docs/verification.md`.

## Install
Download `phonebridge-v0.1.0-preview-debug.apk` and verify against `SHA256SUMS.txt`. Requires Android 11+. This is a **debug-signed development APK**, not a production/store release. Read the root README for desktop hub and MCP setup.

This app does not bypass lock screens, biometrics, secure screenshots, or other apps' private storage. Keyboard overlays/split-screen may be refused. Screen data goes to your paired computer and may then go to your AI provider. Supervise sessions and authorize consequential actions in the AI client. An already dispatched gesture can finish after Stop (at most two seconds).
