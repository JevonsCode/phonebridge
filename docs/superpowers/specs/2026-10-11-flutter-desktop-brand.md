# Flutter desktop and shared PhoneBridge identity

User requests Flutter desktop matching the existing phone design, one model-generated logo across website/desktop/Android, and version-independent MCP setup. Standing authorization permits implementation, review and PR updates without repeated design confirmation.

## Design
Use a separate desktop_app Flutter application, keeping the proven Node dashboard API and managed Windows task/macOS LaunchAgent. Reuse phone colors (#1967D2, #F6F8FC, #202124), Noto Sans SC typography, 24px clipped white surfaces, pill buttons and zero elevation. Desktop navigation: Connection, Connect AI, Settings/About. Main view gives calm large status, device illustration, pairing QR only when needed, and clear recover/start action. Include Chinese/English, responsive narrow window layout, scrollability and visible error states. No demo controls or duplicate web panel by default.

All brand outputs derive from assets/brand/phonebridge.png, generated with image_gen. Preserve original and alpha. Generate platform sizes without altering artwork. Website header/favicon, app about/header, Windows executable and macOS App, Android launchers use the same mark. Platform icon tile backgrounds may differ only where required by platform shape masks.

## Process and protocol
Desktop launches bundled Node server --native-window, reads bounded stdout ready JSON, validates loopback-only private session URL, consumes status/start/network/allow-lan with exact Origin and CSRF. Never log private session URLs. Poll with no overlap, bound network waits, serialize mutations, display errors. Closing frontend stops only its owned dashboard process, not managed background services. Reused child exits must not break existing dashboard. Preserve headless diagnose/self-test and report-path through executable platform runner. MCP config JSON stays a JSON object internally and copied as valid JSON.

## Upgrade-stable MCP
Windows user bin PhoneBridgeMcp.exe and Mac stable user script read current owned desktop config at each start, invoke its installed bundled runtime and bridge MCP over inherited stdio with current network/credential paths. No token in AI config. Installer publishes stable launcher safely and config exposes only stable entry; no version-bearing copied config. Existing users need one migration of old version-pinned AI config. Never claim running MCP hot-swaps: reconnect client after upgrade. Do not break current pairings or service.

## Verification and delivery
Meaningful Flutter widget/protocol tests: startup/error/reuse, settings/navigation zh/en, narrow width, clipboard config, origin/CSRF/redirect handling and dispose. Windows release build and actual visible window with connected phone, preserve pairing hash. Mac arm64/x64 CI build/package and lifecycle tests; physical Mac test remains owner's pending PR acceptance. Update existing PR #1, no merge or formal release until verification. Branding changes prepared across all surfaces in the same PR; report deployment separately from prepared changes. Never overwrite v0.6.0 release bytes.

## Review additions
Acceptance also requires wide/narrow Chinese/English Flutter screenshots, comparison with current phone style, website header and small-size native icons. Stable MCP acceptance uses packaged launcher inherited stdio initialize/tools/list before and after active config switch A to B, failed publication rollback, and verifies existing MCP process remains usable until reconnect. Never replace a running Windows stable executable in place; bootstrap publication must be safe and idempotent.
