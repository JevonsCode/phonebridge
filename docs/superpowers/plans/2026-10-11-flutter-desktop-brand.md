# Flutter desktop and brand implementation plan

> For agentic workers: Use subagent-driven-development; implement scoped tasks and review each result.

**Goal:** Attractive Flutter desktop matching phone, unified generated logo, upgrade-stable MCP.
**Architecture:** Flutter UI consumes retained private loopback Node dashboard; managed services independent. One source brand image, generated platform assets. Stable MCP launcher reads active installed configuration.
**Tech Stack:** Flutter/Dart, Node, existing PowerShell/C# installer and macOS packaging.

### Task 1: Flutter desktop application
- [x] Scaffold desktop_app Windows/macOS with Flutter 3.41.9.
- [x] Implement testable session/process client and three-view bilingual shell matching mobile/lib/design.dart; assets/fonts copied from mobile, logo shared canonical source copied for bundle.
- [x] Preserve diagnostics/headless forwarding in native platform runners; Windows binary name PhoneBridge.exe; macOS product PhoneBridge.
- [x] Add protocol and widget regression tests; run flutter analyze and flutter test; build Windows release.

### Task 2: Upgrade-stable MCP
- [x] Implement stable platform bootstrap, ownership validation and inherited stdio.
- [x] Wire installation and generated config; ensure existing old version configs get explicit one-time migration guidance.
- [x] Test upgrade A -> B using fake package/config, changed host/port, missing config, no stdout noise or embedded secrets.

### Task 3: Shared brand assets and distribution
- [x] Derive Android launcher, Flutter image, Windows ICO, macOS iconset, website PNG/favicon from assets/brand/phonebridge.png with a reproducible script; record imagegen prompt.
- [x] Update app logo widgets and website marks without changing unrelated UI.
- [x] Replace native frontend packaging with Flutter release bundle; preserve Node resource locations/installer and Mac lifecycle. CI setup Flutter and test UI plus retained backend/packaged tests.
- [ ] Run mobile analyze/tests, website tests, Windows package validation and visible real-device status.

### Task 4: Review and delivery
- [x] Independent spec/code review and fixes.
- [ ] Commit/push existing codex/macos-client PR #1 with updated scope and honest test boundaries.
- [ ] Verify Windows/Mac matrix checks, give owner Mac test package. Keep PR open and public release assets unchanged pending Mac acceptance.
- [x] Verify packaged stable launcher MCP initialize/tools/list across A to B active config switch, failed publish rollback and existing session survival.
- [x] Capture wide/narrow zh/en Flutter screens and check brand artwork at launcher/favicon sizes against mobile style.

## Verified evidence and remaining acceptance (2026-10-11)

- Desktop analyzer clean, 17 tests; Android analyzer clean, 66 tests; website language tests 9. Four wide/narrow zh/en fixture screenshots inspected. Windows Release built using the installed MSVC/CMake toolchain.
- Website mark published on main and live bytes matched. Android 0.6.1 preview installed with unchanged pairing and live App screenshot/control check; later phone went offline, so current connected-desktop acceptance remains pending.
- Windows preview installed and visible Flutter window observed via native process/window handle. Real install exposed a PowerShell 5.1 null backup-path failure; fixed with tested atomic backup publication and actual successful reinstall.
- Fixed stable installed MCP entry completed initialize, tools/list (10), and read-only operation history. Dashboard upgrade reuse and real PowerShell localized adapter encoding each have regression coverage.
- PR CI at ee4af86: Android/bridge passed; desktop stable MCP tests failed. Windows default-owner and macOS path-alias causes addressed with local regression; rerun required. Physical Mac acceptance remains with owner.
- New multi-device/bidirectional recovery design is separate from implemented 0.6.1 behavior: see ../specs/2026-10-11-device-network-design.md.
