# Device Control Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give computer AI reliable access to multiple phones/computers and optional persistent screen awake.

**Architecture:** Keep the current Flutter/Kotlin executor and Node Hub. Route by stable phone ID; arbitrate computer/task ownership on the phone; expose additive MCP capabilities and keep one-phone legacy compatibility.

**Tech Stack:** Flutter/Dart, Android Kotlin, Node TypeScript, WebSocket, MCP.

---

## 1. Native connection manager and awake policy

Files: `mobile/android/app/src/main/kotlin/dev/phonebridge/phonebridge/{BridgeSession,TrustedComputers,MainActivity}.kt`; new isolated transport/control/wake classes and corresponding JVM tests; AndroidManifest.

- [ ] Add pure lease arbitration tests (two computers/tasks, idle expiry, in-flight barrier, disconnect/handoff).
- [ ] Implement per-computer transport and retry state; preserve saved trust, owner stop and recovery APIs.
- [ ] Negotiate hello by upgrade header, persist phone UUID; route callbacks by connection generation.
- [ ] Implement off/controlling/always wake policy with bounded display hold and teardown; expose native method channel.
- [ ] Run native tests and build; verify no logs contain trust secrets.

## 2. Hub routing and MCP interface

Files: `bridge/src/{hub,protocol,mcp,operation-journal,supervisor,send-file}.ts`; new tests `bridge/test/multi-device.test.ts`, task handle/wait tests.

- [ ] Write failing two-socket, per-target timeout, ambiguous routing and attributed history tests.
- [ ] Replace singleton Hub state with per-device sessions, hello negotiation and stable routing; add `/devices`, per-device file slots and proxy support.
- [ ] Add routing fields outside strict command params, control methods and node_action schema; preserve one-phone calls.
- [ ] Add MCP device list, acquire/release handles, per-tool targeting, condition waits/asserts and bounded response reader; never auto-retry mutations.
- [ ] Run TypeScript build + full bridge suite; test real stdio multi-device transport.

## 3. Native state and element operations

Files: `PhoneAccessibilityService.kt`, `ObservationPolicy.kt`, supporting node policy tests and accessibility XML if needed. Do not edit BridgeSession concurrently.

- [ ] Extend observation metadata while preserving old response fields.
- [ ] Add validated node_action with same-window/current-node guards, action permissions and invalidation.
- [ ] Unit-test pure validation and run full native suite after integration.

## 4. Flutter device views

Files: `mobile/lib/{main,app_language}.dart`, new screen-awake setting widget, `desktop_app/lib/{app,backend}.dart`, desktop server proxy if necessary, widget tests.

- [ ] Implement screen-awake choice and bilingual states/errors.
- [ ] Show actual concurrent computer connection/control ownership and desktop phone list.
- [ ] Test empty/one/multiple/occupied/offline states; check rounded interaction surfaces.
- [ ] Run analyze/test on mobile and desktop; build Windows client.

## 5. Integration, review and delivery

- [ ] Run all affected suites once code is integrated; fix regressions.
- [ ] Independent spec compliance then code-quality review, resolving important findings.
- [ ] Build signed Android APK, install preserving data, open through ADB, exercise awake modes and connection through PhoneBridge. Simulate second phone/computer when no second physical device is available; label evidence.
- [ ] Update protocol/operation log/agent docs and README with generic computer-AI positioning and compatibility.
- [ ] Commit and open a reviewable GitHub PR, attach it to this task. Release only after meaningful validation and no unresolved routing/ownership risks; do not claim simulated tests are multi-hardware acceptance.
