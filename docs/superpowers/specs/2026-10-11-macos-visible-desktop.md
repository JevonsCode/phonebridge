# macOS client and visible desktop windows

## Approved intent

The owner asked to implement macOS support, submit a PR, and leave physical Mac testing to them. The preceding design was a self-contained Apple Silicon/Intel App with automatic LAN selection, a remembered identity, a pairing code and Copy MCP. The owner then reported that opening the Windows client presents no application window. Their standing instruction authorizes routine development and PR submission without repeated approval. This spec records that accepted scope; no released APK or installed desktop configuration is replaced during development.

## Approach

Use native AppKit on macOS and WinForms on Windows with the existing Node service and a local dashboard HTTP API. This produces an immediately visible window without another browser runtime. Alternatives were Electron (larger dependency/runtime) and a shell script (does not meet the simple installation requirement). Native widgets show loading and actionable startup errors; they do not disappear after launching a browser.

Windows also retains the existing Allow LAN connection action with its owner-approved firewall flow. The browser troubleshooting button remains available. New, existing and concurrent native launches receive a validated ready URL; a reused dashboard child exiting is expected, and closing that window never terminates the existing dashboard or service.

Both windows display phone/service state, QR pairing, selected network, Start service, a selectable MCP configuration and Copy MCP. Chinese/English follow the computer locale and can be switched. Existing browser dashboard access remains available for troubleshooting. The private dashboard URL is passed only through a child-process pipe, never normal logs, diagnostics or public artifacts. Native HTTP requests only use the validated loopback session, refuse redirects and supply the existing mutation Origin/CSRF headers.

## macOS lifecycle

A Swift AppKit executable inside PhoneBridge.app starts bundled Node and desktop/macos/server.mjs. Native launch always displays a window first. Closing/quitting the window terminates its dashboard child only; the registered user service remains available to the phone. Reopening foregrounds the window. Data is in ~/.phonebridge; desktop-macos.json is separate from Windows desktop.json. POSIX files are owned by the current UID with private permissions. Existing pairing.json and operations.jsonl are reused without rotating credentials or deleting logs.

The current-user LaunchAgent dev.phonebridge.desktop runs bundled Node and desktop/macos/service.mjs, uses KeepAlive/RunAtLoad, and invokes the existing DesktopSupervisor. No administrator privileges, public firewall opening, shell-interpolated commands, or edits to unrelated jobs. Existing foreign/modified jobs and occupied foreign endpoints cause a visible error. Configuration and job changes use rollback/backups and do not silently replace an authenticated running service. Network choices come from active private IPv4 interfaces; unavailable networks are explained in the window. Changing network may be refused while the phone or another managed service is active; do not rotate the pairing key.

The App must be copied from the DMG to Applications (or the user's Applications folder) before persistent startup registration. Use stable executable paths, validate bundle identity and refuse symlinks/foreign state before writing. An upgrade preserves identity and logs and can refresh only the owned job. Startup errors must not leave a misleading connected status.

## Packaging and PR testing

Produce architecture-specific DMGs and ZIPs for arm64 and x64, with bundled official pinned Node archives checked against Node's SHA256 file, compiled bridge and production dependencies. Require macOS 13 or later. Compile AppKit with the native SDK, provide Info.plist/icon/license and ad-hoc signatures; do not claim Developer ID signing or notarization. Never remove quarantine or disable Gatekeeper. A Mac user may need Apple's normal approval flow for a preview, which remains their action.

GitHub Actions uses macos-15 and macos-15-intel runners to build and test the respective architecture. Upload PR test packages and SHA sidecars as artifacts; do not modify a public release, website, update manifest or published APK. Validate binaries, self-test/diagnostics, bundle layout and DMG attachment read-only. Native CI checks are separate from actual Wi-Fi phone pairing and physical Mac GUI testing.

Windows packaging must compile the new window and preserve --diagnose, --self-test, --no-open and --report-path semantics. CLI checks must stay headless. Normal opening always displays a window with bounded startup waits and draining child pipes; closing it leaves the existing managed desktop service available. A local test bundle may be opened against the existing service without replacing its installed files.

## Verification

Test first launch, existing credential reuse, private file modes, duplicate/foreign LaunchAgent refusal, unavailable network, occupied service, safe session URL/redirect handling, native POST headers, copy configuration and startup failure visibility. Exercise real isolated HTTP/supervisor lifecycle and cleanup. Run bridge and Windows regression checks. Build and run arm64/x64 Mac diagnostics/self-tests in CI. PR includes download instructions and a physical checklist: installation, visible GUI, repeat opening, QR pairing once, reconnect after reopening/login, native copying, screenshot/tap/history through the phone, update identity retention and uninstall only the owned LaunchAgent.
