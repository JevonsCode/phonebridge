# PhoneBridge Service Recovery Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task by task. The user has approved the complete design and implementation; execute inline and use focused review workers.

**Goal:** Recover the desktop Hub automatically after login/crashes, and let the paired phone start it with one button.

**Architecture:** An authenticated Supervisor keeps the original public HTTP/WebSocket port and proxies the unchanged protocol to a managed loopback Hub worker. Its own start endpoint remains available while the worker is down. Android uses the saved pairing to call that endpoint asynchronously.

**Tech Stack:** Node.js/TypeScript, child_process, HTTP/HTTPS/TCP proxy, Kotlin/OkHttp, Flutter, Windows Task Scheduler.

### Task 1: Desktop supervisor

Files: create `bridge/src/supervisor.ts`, `bridge/src/hub-worker.ts`, `bridge/src/supervisor-cli.ts`, and `bridge/test/supervisor.test.ts`; add npm `supervisor` script in `bridge/package.json`.

- [ ] Add integration cases for authentication/Origin/method/body rejection, concurrent idempotent start, status and real WebSocket proxying, child crash recovery and supervisor shutdown. Build worker with `npm run build` before running tests.
- [ ] Implement public listener with same host/port/TLS validation as Hub. POST `/service/start` accepts an empty body and an exact saved Bearer token, refuses Origin and arbitrary parameters; answer success only after child IPC ready.
- [ ] Launch only `hub-worker.js` using Node fork and IPC. Worker starts `PhoneHub` on 127.0.0.1:0 and reports ready; parent validates returned loopback URL, bounds startup to 10 seconds and coalesces concurrent starts.
- [ ] Proxy existing HTTP and `/device` WebSocket traffic; do not retry or replay RPC. Retain live TCP streams for cleanup. Crash restarts use bounded delay; stopping parent cancels startup/retry and kills/waits for its child.
- [ ] CLI loads original saved DPAPI credential and keeps existing pairing QR support; no secrets in normal output. Run `npm run build` and `npm test` (all old tests must pass).

### Task 2: Phone recovery

Files: create native `DesktopServiceRecovery.kt`, modify `BridgeSession.kt`, `MainActivity.kt`, `mobile/lib/main.dart`, and `mobile/test/widget_test.dart`; bump app to 0.2.3+7.

- [ ] Add widget cases for saved disconnected/connected/unpaired and native method invocation/error feedback.
- [ ] Native recovery validates saved endpoint and consent, converts ws/wss to http/https same authority, and calls POST `/service/start` with saved token on a worker thread. No redirects or automatic retries. Report unreachable/authentication/old desktop errors in Chinese. Require JSON `{serviceRunning:true}` before recovery success.
- [ ] Bind async `startDesktopService` channel method; capture saved credential without exposing it to Flutter. If Activity closes, do not reuse stale result or unexpectedly resume; deliver completion through main thread only while same pairing remains and request is active.
- [ ] After explicit successful button action, resume saved connection; keep operation consent and existing pause UI. Button appears on home only for a paired disconnected phone; show busy state and meaningful error.
- [ ] Run `flutter analyze`, `flutter test`, Android unit tests and `flutter build apk --debug`.

### Task 3: Windows installation and documentation

Files: add `scripts/windows/install-desktop.ps1`, `run-desktop.ps1`, `uninstall-desktop.ps1`; update `README.md` and `docs/verification.md`.

- [ ] Install per-user local configuration using fixed trusted IP/port and stable absolute node/project paths. Register current-user logon task with limited privileges, no password, retry-on-failure and background window. Task launches supervisor; explicitly pass `--allow-lan --remember-pairing`. Provide uninstall script; do not modify firewall or rotate credentials.
- [ ] Validate all script paths/ports and task identity; refuse to overwrite a different task. Detect an occupied endpoint and report actionable startup failure. Preserve prior config as timestamped backup on updates.
- [ ] Capture existing credential hash, stop only known test Hub processes, build/install Supervisor and run task. Verify saved credential hash unchanged and external original port stable. Kill managed Hub child and observe a fresh child plus successful `/status` response.
- [ ] Update installed phone with `adb install -r` only, then use PhoneBridge for operation/screenshots. If phone-side interaction is required, ask once for unlock/open App; no pairing reset. Verify reconnect and new button where reachable.
- [ ] Review code, fix identified defects and run relevant checks again. Commit and publish the tested change to GitHub under JVS/ branch; preserve honest limits for login/reboot and live phone verification.
