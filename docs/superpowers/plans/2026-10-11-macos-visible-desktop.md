# macOS and visible desktop implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Provide visible self-contained Windows/macOS clients and PR Mac test packages without replacing the existing release.

**Architecture:** Native windows consume the existing loopback dashboard protocol. A macOS-specific owned LaunchAgent runs the existing supervisor; platform configuration is private and separate. Package each Mac architecture in CI and retain the Android App unchanged.

**Tech Stack:** AppKit/Swift, WinForms/.NET Framework, Node.js 22, LaunchAgent, GitHub Actions.

## Task 1: shared native dashboard handshake and macOS service

Files: desktop/server.mjs, desktop/macos/{server,service,lifecycle}.mjs, desktop/test/macos.test.mjs.

- [ ] Test native-only first-ready JSON includes a validated session URL, for fresh, reused and concurrent launches, whereas ordinary output and diagnostics never expose it. Reused child exit is expected; never terminate the existing dashboard on window close.
- [ ] Add --native-window handling to existing Windows server, retaining --no-open and legacy browser behavior.
- [ ] Implement private UID-owned Mac config, LaunchAgent exact ownership/rollback, saved identity reuse and local network selection.
- [ ] Implement Mac dashboard entry and isolated self-test (no production jobs or live service mutation).
- [ ] Run node --test desktop/test/macos.test.mjs and bridge build/tests; inspect logs for secret exclusion.

## Task 2: visible Windows client

Files: desktop/Launcher.cs, desktop/DesktopWindow.cs, scripts/package-desktop.ps1 and focused window test helper.

- [ ] Start a visible WinForms window immediately; communicate with Node using --native-window and private first-ready JSON.
- [ ] Add asynchronous state/QR/network/start/MCP-copy widgets and Chinese/English. Enforce exact loopback session and existing CSRF contract, no redirects. Preserve the Windows Allow LAN action and browser troubleshooting entry.
- [ ] Retain diagnostic/self-test/report-path/no-open CLI behavior, bound waits and drain pipes. Closing dashboard does not stop an existing managed service.
- [ ] Update compiler references/source inclusion. Compile a test bundle; test normal startup and error rendering, package regressions and managed identity preservation.

## Task 3: macOS native window, packages and CI

Files: desktop/macos/PhoneBridge.swift, desktop/macos/Info.plist, scripts/package-macos.sh, .github/workflows/macos-client.yml.

- [ ] Implement an immediately visible AppKit window and --diagnose/--self-test CLI forwarding to bundled Node.
- [ ] Add native state/QR/network/start/copy/language widgets, safe native requests, child cleanup and visible errors.
- [ ] Package arm64/x64 with checked official Node bytes, native compiled launcher targeting macOS 13+, resource manifest, license/icon, DMG Applications shortcut and SHA sidecars. Ad-hoc sign only; no quarantine bypass.
- [ ] Matrix build on macos-15 / macos-15-intel; run native binary self-test, diagnostics and read-only DMG layout checks before artifact upload.

## Task 4: review, documentation and PR

Files: docs/macos-testing.md, docs/agent-install.md and README.md.

- [ ] Review spec/plan before implementation and implementation for spec then code quality; fix material findings.
- [ ] Document exact PR-artifact download, architecture choice, copy to Applications, OS preview approval boundary and physical checklist.
- [ ] Push codex/macos-client and open a PR against main, attach it to this chat, wait for both native CI jobs and fix actual failures.
- [ ] Deliver the PR, available test-package links and honest unverified physical Mac checks. Do not merge or publish a release.
