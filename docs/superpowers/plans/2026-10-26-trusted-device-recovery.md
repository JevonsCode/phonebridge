# Trusted device recovery implementation plan

**Goal:** Unattended trusted file receipt and complete remediation of rec#3 without repeated setup.

**Architecture:** Persist one phone receipt preference; preserve trusted IDs while native discovery and desktop address recovery follow the same paired computer. MCP uses installed metadata and current owned endpoint configuration. Queue ownership remains phone-global.

**Tech Stack:** Flutter/Dart, Android Kotlin, Node TypeScript, Windows PowerShell/C#, macOS service scripts.

- [x] Implement/review FileInbox FIFO auto-receive core and source lifetime tests.
- [x] Add bilingual persistent phone switch, native channel/status/result integration, and widget tests.
- [x] Add desktop UDP/HTTP identity challenge, start/runtime address migration and rollback tests on managed paths.
- [x] Add native discovery verification, broadcast/subnet lookup, stale callback cancellation and same-ID persistence tests.
- [x] Add actionable Hub/MCP offline diagnostics and preserve real known-device information.
- [x] Fix launcher help/version, installed server version, ref-free schemas, endpoint refresh and Claude setup/documentation; run real stdio regressions.
- [x] Run full affected suites/builds sequentially where Flutter/Gradle generated plugin registration is shared; independent review and repair.
- [x] Install/test available physical Android with pairing retained; verify automatic receipt and queued AI handoff; label simulated multi-host/network tests.
- [x] Create/update the reviewable follow-up PR #12.
- [ ] Finish exact-head CI, desktop visual inspection and Echo's publication workflow.
- [ ] Update the issue with actual evidence; close only once fully resolved/integrated.

## Current validation

- Phone and Windows client 0.7.1 installed with existing signing identity and desktop pairing bytes preserved. Final Android APK installed; temporary local setup component absent from the final manifest. Existing four computer identities remain, with 168 eligible applications and automation enabled on this test phone.
- Mobile analyze / 138 Flutter cases; Android 210 JVM cases; desktop analyze / 38 Flutter cases; bridge 132 passed + 2 platform skips; desktop and scripts 104 passed + 13 platform skips. Review regressions cover application drafts, selected-computer status, global retries, semantic clipboard actions under Xiaomi smart-text overlays, transient NO_WINDOW observations and temporary Windows marker-file occupancy.
- Installed stable MCP help/version and real stdio serverInfo all report 0.7.1; coordinate tool schemas have no references. Claude Code user registration connects via the stable launcher.
- Previous Windows, Mac arm64 and Mac x64 preview packages compiled successfully; refreshed exact-head CI is tracked in PR #12. The launcher replacement regression now waits for pending-update cleanup and worker completion. The final installed Windows package passed real wrapper diagnostics, ZIP handling, packaged lifecycle and launcher checks under PowerShell 5, with its owned service running and pairing preserved.
- The running supervisor recovered a terminated owned Hub worker. One existing MCP session followed an owned service change from 192.168.31.159 to 192.168.31.153 and back, with pairing bytes preserved. Both addresses remained local; this is service-restart/endpoint-following evidence, not a physical DHCP/discovery test.
- Physical clipboard read/write/paste/copy/cut/select-all, 168-application select/clear, selector and screenshot-coordinate actions, and the actual Allow all button passed. Text automatically arrived in Downloads; a generated PNG automatically arrived in Pictures/PhoneBridge with MediaStore is_pending=0. Existing received files remain.
- Two independent MCP clients on this Windows host queued, rejected queued reads/renewals, and handed over active control in about 107 ms. The phone also showed three remembered computers connected simultaneously; a two-physical-computer handoff was not exercised.
- A physical phone rediscovered the changed listener on an existing LAN alias in about 4.5 seconds, then rediscovered the restored listener in about 31.3 seconds, without scanning or permission changes. The same MCP session followed both endpoints and desktop pairing bytes remained unchanged. Network adapters/DHCP were not changed.
- Launching Xiaohongshu retained the connection and returned its real UI. After fixing read-only NO_WINDOW transition retries, launch plus wait_for completed against the final installed Windows package in about 180 ms on a warm app. Returning PhoneBridge to the foreground used the already authorized ADB launch; an intent dispatch alone is not foreground-success evidence. Operation history remained readable through MCP.
- Echo publication and desktop visual inspection remain pending because a Windows Security prompt blocks Grok Bot. No Echo message or external publication is claimed.
