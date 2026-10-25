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
- [ ] Install/test available physical Android with pairing retained; verify automatic receipt and queued AI handoff; label simulated multi-host/network tests.
- [ ] Create/update PRs, verify CI, update issue with actual evidence; close only once fully resolved/integrated.

## Current validation

- Phone and Windows client 0.7.1 installed with existing signing identity and desktop pairing bytes preserved. The final optional-editor-guard APK still requires the last installation pass.
- Mobile analyze / 120 Flutter cases; Android 208 JVM cases; desktop analyze / 38 Flutter cases; bridge 119 passed + 2 platform skips; desktop and scripts 101 passed + 13 platform skips.
- Installed stable MCP help/version and real stdio serverInfo all report 0.7.1; coordinate tool schemas have no references. Claude Code user registration connects via the stable launcher.
- Windows, Mac arm64 and Mac x64 preview packaging passed at f688beb. Later installer separator normalization and owner-editor policy changes await refreshed CI.
- Physical clipboard/media/queue/address-migration and Echo publication validation remain pending; no external publication is claimed.
