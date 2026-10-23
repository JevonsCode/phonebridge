# Device Control Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Give computer AI reliable access to multiple phones/computers and optional persistent screen awake.

**Architecture:** Keep the current Flutter/Kotlin executor and Node Hub. Route by stable phone ID; arbitrate computer/task ownership on the phone; expose additive MCP capabilities and keep one-phone legacy compatibility.

**Tech Stack:** Flutter/Dart, Android Kotlin, Node TypeScript, WebSocket, MCP.

---

## 1. Native connection manager and awake policy

Files: `mobile/android/app/src/main/kotlin/dev/phonebridge/phonebridge/{BridgeSession,TrustedComputers,MainActivity}.kt`; new isolated transport/control/wake classes and corresponding JVM tests; AndroidManifest.

- [x] Add pure lease arbitration tests (two computers/tasks, idle expiry, in-flight barrier, disconnect/handoff).
- [x] Implement per-computer transport and retry state; preserve saved trust, owner stop and recovery APIs.
- [x] Negotiate hello by upgrade header, persist phone UUID; route callbacks by connection generation.
- [x] Implement off/controlling/always wake policy with bounded display hold and teardown; expose native method channel.
- [x] Run native tests and build; verify no logs contain trust secrets.

## 2. Hub routing and MCP interface

Files: `bridge/src/{hub,protocol,mcp,operation-journal,supervisor,send-file}.ts`; new tests `bridge/test/multi-device.test.ts`, task handle/wait tests.

- [x] Write failing two-socket, per-target timeout, ambiguous routing and attributed history tests.
- [x] Replace singleton Hub state with per-device sessions, hello negotiation and stable routing; add `/devices`, per-device file slots and proxy support.
- [x] Add routing fields outside strict command params, control methods and node_action schema; preserve one-phone calls.
- [x] Add MCP device list, acquire/release handles, per-tool targeting, condition waits/asserts and bounded response reader; never auto-retry mutations.
- [x] Run TypeScript build + full bridge suite; test real stdio multi-device transport.

## 3. Native state and element operations

Files: `PhoneAccessibilityService.kt`, `ObservationPolicy.kt`, supporting node policy tests and accessibility XML if needed. Do not edit BridgeSession concurrently.

- [x] Extend observation metadata while preserving old response fields.
- [x] Add validated node_action with same-window/current-node guards, action permissions and invalidation.
- [x] Unit-test pure validation and run full native suite after integration.

## 4. Flutter device views

Files: `mobile/lib/{main,app_language}.dart`, new screen-awake setting widget, `desktop_app/lib/{app,backend}.dart`, desktop server proxy if necessary, widget tests.

- [x] Implement screen-awake choice and bilingual states/errors.
- [x] Show actual concurrent computer connection/control ownership and desktop phone list.
- [x] Test empty/one/multiple/occupied/offline states; check rounded interaction surfaces.
- [x] Run analyze/test on mobile and desktop; build Windows client.

## 5. Integration, review and delivery

- [x] Run all affected suites once code is integrated; fix regressions.
- [x] Independent spec compliance then code-quality review, resolving important findings.
- [x] Build signed Android APK, install preserving data, open through ADB, exercise awake modes and connection through PhoneBridge. Simulate second phone/computer when no second physical device is available; label evidence.
- [x] Update protocol/operation log/agent docs and README with generic computer-AI positioning and compatibility.
- [x] Commit and open a reviewable GitHub PR, attach it to this task. Release only after meaningful validation and no unresolved routing/ownership risks; do not claim simulated tests are multi-hardware acceptance.

## Verification evidence (2026-10-23)

- Source implementation: f47b601e0be2aa1ef5e69c64d1968b07fde91bee; bridge 91 passed / 2 platform skips, Android release JVM 140 passed, mobile 95 passed, desktop 38 passed, distribution/desktop Node 72 passed / 13 platform skips.
- Physical Android 16 upgraded to 0.7.0 (4022) with saved pairing and accessibility retained. Three screen-awake modes verified against actual Android display locks, including foreground app change and task release.
- Two independent AI clients on the same Hub queued on one physical phone; queued actions were rejected, and release notified/granted the next waiter in 104 ms in the installed desktop-service run. This is not two-physical-computer acceptance.
- Windows CI package installed; persistent scheduled task runs the installed 0.7.0 runtime, and the original saved phone automatically reconnected without pairing. Temporary worktree supervisor stopped.
- Specification, bridge and native reviews approved; final geometry delta received a focused follow-up approval.
- Local desktop window capture returned black pixels, so it does not establish a visual pass. CI Flutter screenshots and widget tests are the visual evidence. Second physical phone and macOS hardware acceptance remain separate.
- Publication and live distribution checks are tracked in PR #8 and the release workflow; package/build success alone is not a release claim.
