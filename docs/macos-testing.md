# macOS client preview

This PR adds a native PhoneBridge window for macOS 13 or later and an independent window for Windows. Mac test packages are CI artifacts, not a formal release. The public 0.6.0 downloads and Android APK remain unchanged.

## Download and open

1. Open the PR's **Checks → macOS client preview → Details**. On the run summary, download `phonebridge-macos-arm64-preview` for Apple Silicon (M1 or later), or `phonebridge-macos-x64-preview` for an Intel Mac. GitHub may require sign-in to download artifacts; they expire after 14 days.
2. Extract the artifact ZIP. It contains a DMG, an alternative App ZIP, and SHA256 sidecars. In that folder, run `shasum -a 256 -c phonebridge-0.6.1-macos-arm64.dmg.sha256` (replace `arm64` with `x64` on Intel). Open the matching DMG and drag **PhoneBridge.app** into **Applications**. `~/Applications` also works. Do not run the persistent service directly from the mounted DMG or Downloads.
3. Open **PhoneBridge**. The window shows connection status, the selected network, a pairing QR and **Copy MCP configuration**. Keep the Android phone on the same reachable private Wi-Fi, scan once in PhoneBridge, and enable the Android permissions on the phone. Later openings retain this pairing.

The preview is ad-hoc signed, without Apple Developer ID signing or notarization. If macOS asks you to approve the App, use the system's normal approval flow. The package does not remove quarantine or disable Gatekeeper. Approve local-network access if macOS asks. Guest-network isolation or a Mac firewall policy can prevent phone access.

The App bundles Node.js; no Homebrew, npm, terminal setup or manual IP lookup is needed for ordinary use. Chinese/English follows the Mac's language, with a switch in the window. The browser panel remains available for troubleshooting.

## What persists

The current-user LaunchAgent `dev.phonebridge.desktop` starts the service at login and restarts it after exit. Closing the App window closes its local dashboard only. The phone and AI can continue using the background service.

Data lives in `~/.phonebridge`. `desktop-macos.json` is separate from Windows's `desktop.json`; pairing remains in `pairing.json`, and operation history remains in `operations.jsonl`. Existing identity and logs are preserved. The generated MCP configuration reads that private credential file rather than embedding the pairing key. Changing an active network requires disconnecting the phone first.

To remove **only the owned login service**, quit the window and run:

```bash
/Applications/PhoneBridge.app/Contents/MacOS/PhoneBridge --uninstall-service
```

The command verifies the owned plist and the loaded executable/arguments before stopping anything. It keeps pairing, logs and configuration. Reopening PhoneBridge registers its service again. Move the App to Trash afterward if you want to keep it uninstalled; do not delete pairing data during ordinary upgrades.

## Physical Mac checklist

CI compiles and executes the matching native launcher, isolated lifecycle tests, bundled diagnostics/self-test, code-signature checks and read-only DMG checks. These checks do not prove real phone pairing, the system's approval prompts or the physical GUI experience.

- Copy the App to Applications; opening presents a visible window with loading or an actionable error.
- Select the expected Wi-Fi/Ethernet interface; QR pairs the phone once. Reopen and confirm the original phone pairing remains.
- Close the window, then verify the phone and AI remain connected. Reopen the App and confirm status.
- Copy the MCP configuration into the AI client; confirm a screenshot, one authorized tap, and `phone_operation_history` through the Android App.
- Log out/in or restart the Mac; confirm the user service and saved phone reconnect.
- Switch English/中文; check QR, network selection, status and copy feedback.
- With the phone disconnected, change network; an unavailable/occupied new endpoint should produce a visible error and preserve the old configuration.
- Replace the App with a later preview in the same location; verify pairing and operation history are retained.
- Remove the login service with the command above; confirm it stops without changing unrelated jobs, pairing or history.

When reporting issues, include Mac model/architecture, macOS version, stage, visible error and sanitized diagnostics. Never attach the QR, private dashboard URL, `pairing.json` or screenshots containing private phone content.

## Headless checks for agents

```bash
/Applications/PhoneBridge.app/Contents/MacOS/PhoneBridge --diagnose
/Applications/PhoneBridge.app/Contents/MacOS/PhoneBridge --self-test
/Applications/PhoneBridge.app/Contents/MacOS/PhoneBridge --diagnose --report-path /absolute/path/diagnostics.json
```

Diagnostics are read-only. Self-test uses temporary fixtures, mock launchctl calls and isolated local HTTP services; it does not register a production LaunchAgent or change the owner's pairing. The commands report exit codes and sanitized results.

Build packages on their corresponding native Mac architecture:

```bash
bash scripts/package-macos.sh --arch arm64 --output /absolute/output/folder
# Intel: --arch x64
```

The script checks the pinned official Node 22.23.3 archive against the official SHA256 list before copying the runtime, builds locked production dependencies, compiles AppKit for macOS 13, and signs the App locally with an ad-hoc signature.
