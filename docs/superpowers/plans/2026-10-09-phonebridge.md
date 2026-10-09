# PhoneBridge implementation plan

> For agentic workers: execute inline using executing-plans; review the spec and plan before implementation.

**Goal:** Deliver an open-source personal Android control bridge and reproducible APK.

**Architecture:** Flutter hosts owner controls. Kotlin AccessibilityService handles bounded native operations over an authenticated WebSocket. A Node hub connects one phone to an MCP stdio adapter.

**Tech Stack:** Flutter/Dart, Kotlin/Android API 30+, OkHttp, Node 22+, TypeScript, ws, MCP TypeScript SDK, node:test.

## Tasks
1. [x] Initialize an isolated Git repository; scaffold `mobile/` for Android only. Keep generated signing/build/user settings ignored.
2. [x] Implement `bridge/src/protocol.ts`, `hub.ts`, `cli.ts`, `mcp.ts`, plus `bridge/test/bridge.test.ts`. Test unauthorized connections, read-only capability forwarding, single-flight behavior, timeout without replay, disconnect, payload limits, and actual MCP tool calls through a simulated phone. Run `npm test` and `npm run build`.
3. [x] Implement Kotlin session, accessibility, connection and activity components. Configure manifest/service XML/network declarations and dependencies. Enforce consent, package scope, lock checks, bounds, session epoch, and stop behavior on phone rather than trusting MCP.
4. [x] Implement Flutter `main.dart`, owner consent/connect controls and playground; widget test consent defaults and local stop. Run `flutter analyze`, `flutter test`, `flutter build apk --debug`.
5. [x] Verify the real Android service on an isolated Android 11 emulator: screenshot, UI tree, tap, Unicode text, read-only/allowlist/stale-ID/stop. Physical installation and accessibility were subsequently authorized by the owner. Physical WeChat checks remain pending; see verification record.
6. [x] Add bilingual-facing README (Chinese first), MIT LICENSE, SECURITY, CONTRIBUTING, protocol and verification docs, sample MCP configuration without credentials, and CI. Review implementation for security and correctness, repair findings, re-run affected checks.
7. [ ] Scan tracked files for secrets, commit source, create public GitHub repo under authenticated owner, push and publish a v0.1.0 preview release with debug APK and SHA256 checksum. Verify remote URLs, assets, and CI status. State exact testing limits in release notes and final delivery.

## Onboarding adjustment after physical installation

The owner requests all ongoing controls through the App, without ADB input injection. Add QR form filling and document direct LAN connectivity. Use `phonebridge://pair` with version, device endpoint and session token; scanning never enables consent, actions or connection. The computer's QR page is local, temporary and uncached. Camera permission is requested only when the owner opens the scanner. Ship as v0.1.1 after automated checks and update the physical evidence only after observed results.

## Test commands
`cd bridge; npm ci; npm test; npm run build`

`cd mobile; flutter pub get; flutter analyze; flutter test; flutter build apk --debug`

`adb devices -l` establishes device availability only; `unauthorized` is not an executed device test.
