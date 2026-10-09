# PhoneBridge v0.1 design

## Approved direction
Build a personal-use Android phone controller, with Flutter UI and Kotlin AccessibilityService, controlled by an existing desktop AI through MCP. The user authorized an open-source GitHub publication after implementation. This is a developer preview, not a promise of unrestricted Android control or Play Store acceptance.

## First vertical slice
An Android 11+ phone connects to a desktop hub. The AI can inspect visible UI nodes and screenshots, launch an installed app, tap, long press, swipe, enter Unicode text into an editable node, and press Back/Home/Recents. Each action returns a real execution result, and the agent must observe again to establish outcome. A manual test screen supplies an editable field and counter for smoke tests before using WeChat. WeChat access is limited to its displayed UI, never its private database.

## Components
- `mobile/`: Flutter authorization/connect/session screen and a local playground. Kotlin owns the socket and AccessibilityService so controls survive Flutter going into the background.
- `bridge/`: Node.js TypeScript hub and MCP stdio client. Hub accepts one authenticated phone WebSocket and authenticated local HTTP command requests. MCP exposes explicit bounded tools, no shell or arbitrary code execution.
- `docs/`: setup, protocol, verification matrix, privacy/security limits, contribution guide. MIT license, CI builds and tests, GitHub source and APK preview release.

## Pairing and transport
Hub generates a cryptographically random per-run token unless provided through an environment variable. Never write it to source or logs. Phone receives endpoint and token from the owner. Default hub binds loopback; USB `adb reverse` is an optional secure local development route. LAN binding is explicitly requested; phone cleartext WS is restricted to literal private/loopback/CGNAT IPs and requires an explicit acknowledgement. WSS uses normal certificate validation; hub supports operator-supplied TLS certificate/key. No public relay, accounts, analytics, or cloud storage. Token remains in phone process memory and is cleared on disconnect; no automatic restart or reconnect after user stop.

## Session boundaries
Owner explicitly opens Accessibility settings and enables the service. A session starts read-only; owner separately enables actions. UI offers stop/disconnect, and service provides a visible ongoing notification with a stop action while connected. All remote commands fail when locked or session stopped. Screenshot and UI tree are bounded, password text is redacted; image capture cannot promise all other apps' sensitive content is redacted. Read/control are scoped to packages in the owner's editable allowlist, initially this app and WeChat. System navigation is allowed only during action-enabled sessions on an allowed active package. Launch can only target allowlisted packages. Home/Back may leave the allowlist; observations then fail until an allowlisted app is opened. No bypass of biometric authentication, secure screenshots, permission prompts, or app sandboxing.

## Protocol and failure handling
Window isolation: before observations or coordinate actions, inspect interactive windows. Reject ambiguous multi-application/split-screen layouts and foreign accessibility overlays or focused system panels. Screenshots are cropped to the allowed application's visible window, with crop offsets returned for mapping to physical coordinates. Reject screenshots if any foreign window overlaps that crop (including keyboard/system overlays). Gestures must be inside the allowed window and outside overlapping foreign windows; recheck immediately before dispatch. This fails closed, so the owner may need to dismiss a keyboard or popup. Test mixed-window refusals and screenshot crop/coordinate mapping on Android when a usable device is available.

Version 1 JSON request `{id, method, params}` and response `{id, result}` or `{id, error:{code,message}}`. Only known commands; request size limit, response size limit, screenshot resolution cap, UI node/depth cap, one in-flight command, per-command timeout. Correlate replies; discard late replies, refuse another phone while one is connected, reject unauthenticated requests before command dispatch. Disconnect rejects pending work. No automatic retries of mutating commands because outcome could be unknown. Events/logs contain operation names/status, never screen contents or input text. User-provided screen text is untrusted data, not agent instructions.

## Explicit non-goals
No model API key in the mobile app, autonomous planner, generic task scheduling, persistent unattended access, root, chat database extraction, payment automation, or store submission. AI-specific action confirmation is the client's responsibility; read-only mode and local stop are enforced on-device. The developer preview must not claim robust business-transaction confirmation.

## Acceptance and publication
Run hub/auth/timeout/disconnect/protocol tests and MCP integration with a simulated phone. Run Flutter analyze/widget tests and build an APK. If a usable authorized phone/emulator exists, exercise the real service through its playground. Record separately what was built, tested with a simulator, and verified on Android/WeChat. Inspect tracked files for credentials and personal data before creating a public GitHub repository and preview release; only project files go into the new repository. Publish a reproducible preview APK, clearly identify its signing mode, and do not commit signing keys. No claims of WeChat end-to-end success without actual device evidence.
