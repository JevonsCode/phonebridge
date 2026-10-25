# Trusted device recovery implementation plan

**Goal:** Unattended trusted file receipt and complete remediation of rec#3 without repeated setup.

**Architecture:** Persist one phone receipt preference; preserve trusted IDs while native discovery and desktop address recovery follow the same paired computer. MCP uses installed metadata and current owned endpoint configuration. Queue ownership remains phone-global.

**Tech Stack:** Flutter/Dart, Android Kotlin, Node TypeScript, Windows PowerShell/C#, macOS service scripts.

- [ ] Implement/review FileInbox FIFO auto-receive core and source lifetime tests.
- [ ] Add bilingual persistent phone switch, native channel/status/result integration, and widget tests.
- [ ] Add desktop UDP/HTTP identity challenge, start/runtime address migration and rollback tests on managed paths.
- [ ] Add native discovery verification, broadcast/subnet lookup, stale callback cancellation and same-ID persistence tests.
- [ ] Add actionable Hub/MCP offline diagnostics and preserve real known-device information.
- [ ] Fix launcher help/version, installed server version, ref-free schemas, endpoint refresh and Claude setup/documentation; run real stdio regressions.
- [ ] Run full affected suites/builds sequentially where Flutter/Gradle generated plugin registration is shared; independent review and repair.
- [ ] Install/test available physical Android with pairing retained; verify automatic receipt and queued AI handoff; label simulated multi-host/network tests.
- [ ] Create/update PRs, verify CI, update issue with actual evidence; close only once fully resolved/integrated.
