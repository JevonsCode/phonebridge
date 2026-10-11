# Flutter desktop and brand implementation plan

> For agentic workers: Use subagent-driven-development; implement scoped tasks and review each result.

**Goal:** Attractive Flutter desktop matching phone, unified generated logo, upgrade-stable MCP.
**Architecture:** Flutter UI consumes retained private loopback Node dashboard; managed services independent. One source brand image, generated platform assets. Stable MCP launcher reads active installed configuration.
**Tech Stack:** Flutter/Dart, Node, existing PowerShell/C# installer and macOS packaging.

### Task 1: Flutter desktop application
- [ ] Scaffold desktop_app Windows/macOS with Flutter 3.41.9.
- [ ] Implement testable session/process client and three-view bilingual shell matching mobile/lib/design.dart; assets/fonts copied from mobile, logo shared canonical source copied for bundle.
- [ ] Preserve diagnostics/headless forwarding in native platform runners; Windows binary name PhoneBridge.exe; macOS product PhoneBridge.
- [ ] Add protocol and widget regression tests; run flutter analyze and flutter test; build Windows release.

### Task 2: Upgrade-stable MCP
- [ ] Implement stable platform bootstrap, ownership validation and inherited stdio.
- [ ] Wire installation and generated config; ensure existing old version configs get explicit one-time migration guidance.
- [ ] Test upgrade A -> B using fake package/config, changed host/port, missing config, no stdout noise or embedded secrets.

### Task 3: Shared brand assets and distribution
- [ ] Derive Android launcher, Flutter image, Windows ICO, macOS iconset, website PNG/favicon from assets/brand/phonebridge.png with a reproducible script; record imagegen prompt.
- [ ] Update app logo widgets and website marks without changing unrelated UI.
- [ ] Replace native frontend packaging with Flutter release bundle; preserve Node resource locations/installer and Mac lifecycle. CI setup Flutter and test UI plus retained backend/packaged tests.
- [ ] Run mobile analyze/tests, website tests, Windows package validation and visible real-device status.

### Task 4: Review and delivery
- [ ] Independent spec/code review and fixes.
- [ ] Commit/push existing codex/macos-client PR #1 with updated scope and honest test boundaries.
- [ ] Verify Windows/Mac matrix checks, give owner Mac test package. Keep PR open and public release assets unchanged pending Mac acceptance.
- [ ] Verify packaged stable launcher MCP initialize/tools/list across A to B active config switch, failed publish rollback and existing session survival.
- [ ] Capture wide/narrow zh/en Flutter screens and check brand artwork at launcher/favicon sizes against mobile style.
