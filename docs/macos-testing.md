# macOS client preview

PhoneBridge provides a Flutter window for macOS 13 or later and Windows, using the same visual style and logo as Android. macOS packages are available with the GitHub developer preview releases for Apple Silicon and Intel.

## Download and open

1. Open [GitHub Releases](https://github.com/JevonsCode/phonebridge/releases). For 0.6.1, download `phonebridge-0.6.1-macos-arm64.dmg` for Apple Silicon (M1 or later), or `phonebridge-0.6.1-macos-x64.dmg` for an Intel Mac, together with its `.sha256` file. Each architecture also has an alternative App ZIP. Unreleased PR builds remain available from **Checks → Flutter desktop client preview → Details** as 14-day CI artifacts.
2. In the download folder, run `shasum -a 256 -c phonebridge-0.6.1-macos-arm64.dmg.sha256` (replace `arm64` with `x64` on Intel). Open the matching DMG and drag **PhoneBridge.app** into **Applications**. `~/Applications` also works. Do not run the persistent service directly from the mounted DMG or Downloads.
3. Open **PhoneBridge**. The window shows connection status, the selected network, a pairing QR and **Copy MCP configuration**. Keep the Android phone on the same reachable private Wi-Fi, scan once in PhoneBridge, and enable the Android permissions on the phone. Later openings retain this pairing.

The preview is ad-hoc signed, without Apple Developer ID signing or notarization. If macOS asks you to approve the App, use the system's normal approval flow. The package does not remove quarantine or disable Gatekeeper. Approve local-network access if macOS asks. Guest-network isolation or a Mac firewall policy can prevent phone access.

The App bundles Node.js; no Homebrew, npm, terminal setup or manual IP lookup is needed for ordinary use. Chinese/English follows the Mac's language, with a switch in the window. The browser panel remains available for troubleshooting.

## What persists

The current-user LaunchAgent `dev.phonebridge.desktop` starts the service at login and restarts it after exit. Closing the App window closes its local dashboard only. The phone and AI can continue using the background service.

Data lives in `~/.phonebridge`. `desktop-macos.json` is separate from Windows's `desktop.json`; pairing remains in `pairing.json`, and operation history remains in `operations.jsonl`. Existing identity and logs are preserved. The generated MCP configuration reads that private credential file rather than embedding the pairing key. Changing an active network requires disconnecting the phone first.

On reopening an upgraded App, a fingerprint of the bundled runtime inputs refreshes the owned service even when the installation path and version label are unchanged. Disconnect the phone before applying this refresh; if prompted, disconnect it and click **Start desktop service**. Reopening an unchanged bundle leaves the running service in place. A custom `credentialFile` in the saved Mac configuration is shared by the dashboard, background service and MCP; its operation history is stored alongside that credential unless `PHONEBRIDGE_LOG_FILE` explicitly overrides it.

Service replacement waits for launchd to remove the old job after `bootout`, including during rollback. A successful `bootout` alone does not mean the old process has finished closing its sockets; bootstrapping immediately can return status 5 on macOS.

In the updated Android source, **Scan / 扫一扫** is always visible at the top right of the connection home page, including for a remembered computer. It opens the built-in scanner directly. With an active connection, it first asks to pause; cancelling leaves the connection untouched, and pausing keeps remembered computers. Scanning fills pairing details only and still requires local consent. Older installed Android builds use **Connect computer**, or tap the remembered computer card → **Pair another computer** → **Scan computer pairing code**.

To remove **only the owned login service**, quit the window and run:

```bash
/Applications/PhoneBridge.app/Contents/MacOS/PhoneBridge --uninstall-service
```

The command verifies the owned plist and the loaded executable/arguments before stopping anything. It keeps pairing, logs and configuration. Reopening PhoneBridge registers its service again. Move the App to Trash afterward if you want to keep it uninstalled; do not delete pairing data during ordinary upgrades.

## Physical Mac checklist

CI compiles and executes the matching Flutter desktop application, isolated lifecycle tests, bundled diagnostics/self-test, code-signature checks and read-only DMG checks. These checks do not prove real phone pairing, the system's approval prompts or the physical GUI experience.

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

For an explicit source-level test of the real service using a custom credential on an active private interface, run `PHONEBRIDGE_TEST_LAN=1 node --test desktop/test/macos.test.mjs` after building `bridge`. It uses a temporary credential and random port, then stops its child service. The default suite skips this LAN listener. The source-only invalid-installation launch test is skipped inside packaged self-tests so it cannot open the installed dashboard or register a production job.

Build packages on their corresponding native Mac architecture:

```bash
bash scripts/package-macos.sh --arch arm64 --output /absolute/output/folder
# Intel: --arch x64
```

The script checks the pinned official Node 22.23.3 archive against the official SHA256 list before copying the runtime, builds locked production dependencies, builds Flutter for macOS 13, and signs the App locally with an ad-hoc signature.
