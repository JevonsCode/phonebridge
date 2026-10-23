# Install PhoneBridge with an AI assistant

PhoneBridge provides a Windows installer with its own Node.js runtime. The owner does not need Node.js, npm, a terminal, or a manual IP lookup. One phone can remember several paired computers, with separate action consent and allowed Apps for each. The current source supports concurrent computer connections and phone-side control arbitration; use the published release instructions matching the package actually installed.

## Windows

1. Open the [v0.6.0 release](https://github.com/JevonsCode/phonebridge/releases/tag/v0.6.0). Download `phonebridge-0.6.0-windows-setup.exe` and its `.sha256` sidecar. An Agent should read the release asset digest and compare SHA256 with the downloaded file before running it. If the release is not yet published, do not claim these downloads are available.
2. Run the installer as the current user. It extracts under `%USERPROFILE%\.phonebridge\app\versions\0.6.0\bundle-<package-hash-prefix>`, creates a Start menu shortcut, and registers or migrates the owned current-user `PhoneBridge Desktop` logon task. Distinct builds use distinct payload folders, preserving a running older build; reinstalling the identical installer reuses its payload. It requires Windows 10/11 x64 and .NET Framework 4.8. No administrator elevation or firewall-rule creation is performed. If an AI desktop app redirects AppData writes, installation creates a physically visible Desktop shortcut immediately; the unpackaged managed startup task repairs the Start menu shortcut. User-profile runtime storage remains accessible to Task Scheduler in either environment.
3. Open **PhoneBridge** from the Start menu. The local browser panel shows a private pairing QR and phone connection status. The client selects an active private Ethernet/Wi-Fi address. If several networks are available, use the panel's network selector.

An existing `%USERPROFILE%\.phonebridge\desktop.json` and DPAPI-protected pairing identity are reused. Installer migration changes installation paths while preserving the configured address, port and pairing identity. It saves configuration backups and the previous managed task XML before changing paths. A running service continues; new startup paths apply at its next start. Foreign configurations or tasks are rejected.

If Windows prompts about a network connection, the owner decides whether to allow the private network. Keep both devices on a mutually reachable private network; guest Wi-Fi isolation can block them. PhoneBridge does not automatically add public-network firewall rules.

The optional `phonebridge-0.6.0-windows-x64.zip` portable package contains `PhoneBridge.exe`. Extract the whole ZIP, then open that executable. Portable use does not register startup itself. Existing owned service configuration takes precedence over the extracted package, so unpacking a new version alone does not migrate an installed service.

## macOS and visible desktop preview

The current branch adds a visible native Windows window and self-contained macOS Apps for Apple Silicon and Intel, requiring macOS 13+. These are PR test packages; the public 0.6.0 Windows download above still uses its browser panel. Do not infer that the preview has been formally released.

Follow [macOS test-package instructions](macos-testing.md) to download the matching CI artifact, verify its SHA256 and copy PhoneBridge.app to Applications before opening. The native window selects the network and shows status, a pairing QR and a Copy MCP button. No system Node.js installation is needed. The App registers only its owned current-user LaunchAgent, keeps pairing/history, and leaves the background service running when its window closes. The owner completes macOS approval and Android permission prompts.

On a Mac, use the native App's `--diagnose`, `--self-test` and `--diagnose --report-path <absolute-path>` commands for sanitized checks. `--uninstall-service` removes only the exact owned login service and preserves identity and logs. Never remove quarantine, disable Gatekeeper or delete the pairing file as an installation workaround.

## Diagnostics for an Agent

These installer commands validate the embedded package and path containment, then exit before installation, extraction, configuration writes or task registration:

```powershell
& .\phonebridge-0.6.0-windows-setup.exe --diagnose
& .\phonebridge-0.6.0-windows-setup.exe --self-test
```

The portable launcher also supports `--diagnose` and `--self-test`. Diagnostics report runtime availability, configuration ownership and the number of private network candidates. They never print pairing keys, QR data or the private dashboard URL. Check process exit codes: the executable uses the Windows GUI subsystem, so terminal text may not be shown by every shell.

For reliable CI output, add `--diagnose --report-path <absolute-json-path>` to either executable. This writes only the requested diagnostic artifact, containing `product: PhoneBridge`, `version: 0.6.0`, `platform: windows-x64`, and `dryRun: true`. The setup report also includes `embeddedPackageValid` and `pathContainmentPassed`; it validates the embedded manifest identity against the installer version. The report parent directory must already exist.

```powershell
$p = Start-Process .\PhoneBridge.exe -ArgumentList '--diagnose' -WindowStyle Hidden -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'PhoneBridge diagnostics failed' }
```

For an authorized unattended installation, the installer accepts `--silent --no-launch`. `--silent` suppresses completion/error dialogs; it does not bypass Windows or Android security dialogs. Without `--no-launch`, installation opens the local dashboard.

Development validation:

The packaged lifecycle check uses loopback by default. A real LAN network-switch test opens a random port and can trigger a Windows firewall prompt for each new package path. Run that check only deliberately with `PHONEBRIDGE_TEST_LAN=1`; the Windows preview CI job sets it explicitly. Local test output states when this case is skipped. The normal PhoneBridge LAN rule covers its configured TCP port on Private/LocalSubnet networks and survives package-path changes; do not disable firewall notifications for testing.

```powershell
./scripts/test-desktop-client.ps1
./scripts/package-desktop.ps1 -Version 0.6.0 -OutputDirectory ./artifacts/windows-release
./scripts/test-desktop-client.ps1 -PackageDirectory ./artifacts/windows-release/stage-0.6.0
```

Packaging fetches the pinned official Node 22.23.3 x64 ZIP and verifies it against that version's official `SHASUMS256.txt`. It builds the bridge and installs only production bridge dependencies into the payload. Build tools need network access; installed users do not need Node on PATH.

## Android

Download the ARM64 APK from the same verified release on the phone. The owner permits installation from the chosen source and confirms Android's installer. Open PhoneBridge, scan the computer's QR, and confirm pairing. The QR is a credential: do not attach it to reports, screenshots or issue trackers.

The owner enables PhoneBridge in Android's Accessibility settings and chooses allowed Apps. Action control stays off until the owner enables it. An Agent must not claim it can bypass Android permission screens.

With explicit owner authorization for USB debugging and APK installation, an Agent can verify `adb devices`, compare the APK hash, run `adb install -r <verified-apk>`, and launch the app. The owner must approve the device's USB debugging prompt and any installation/security prompts. Do not use an unapproved device or silently grant accessibility.

To remember another computer, scan that computer once. Current source keeps saved enabled computers connected independently. An AI can request the phone itself; the owner does not need to switch computers for each task. Tapping a computer in the phone list remains an explicit local handoff and leaves other transports connected. Global Stop pauses all connections; per-computer pause/forget affects its target. Keep action consent and allowed Apps scoped to each computer. Older released packages can have different connection behavior; do not claim a feature from the current branch was installed merely because pairing succeeded.

## Connect an AI client

If the local service is ready but the phone times out, expand **Phone cannot connect? / 手机无法连接？** in the dashboard and click **Allow LAN connection / 允许局域网连接**. The Windows owner must approve the UAC prompt. Installation and ordinary startup never request elevation automatically. This creates one named, owner-marked TCP port rule for **Private** networks and **LocalSubnet** only; Windows Firewall stays enabled. The port rule survives runtime version-folder changes, so ordinary upgrades keep this permission.

The helper removes only local, inbound Windows-generated `TCP Query User{...}` block rules whose application path exactly matches the current owned package's `runtime/node.exe`. It leaves UDP blocks, other applications, previous installations and custom or policy blocks untouched. A foreign or modified rule using the same managed name causes a refusal. If Windows uses another administrator account for elevation, the owner mismatch also causes refusal; the Windows owner can review the narrow rule manually. If rule creation fails, application blocks remain. A later deletion failure reports an unsuccessful request and leaves any remaining blocks intact; retry or inspect the owner-managed rule before reporting connectivity success.

Use a trusted **Private** home/work network. This button does not change the network category or enable Public-network access. Retry the phone connection and verify its connected state after approval; local `/status` success alone does not prove LAN reachability. It does not change Android permissions or pairing identity. Agents may run `desktop/allow-lan.ps1 -ConfigurationPath <owned-config> -ValidateOnly` for a read-only rule plan. `-RequestElevation` is an explicit owner action; never invoke `-Apply` silently on the owner's behalf.

In the desktop client, open **Connect AI / 连接 AI** and click **Copy MCP configuration / 复制 MCP 配置**. Add the generated stdio server to an AI client that accepts `mcpServers` JSON. The new desktop preview installs a fixed current-user MCP entry. Each new MCP process reads the owned desktop configuration to find the current installed runtime, service address, port and saved credential file. The AI configuration contains no pairing key and no version directory.

For an installed Windows preview, the generated shape is below. Use the client's copied absolute path for your account:

```json
{
  "mcpServers": {
    "phonebridge": {
      "command": "C:/Users/Owner/.phonebridge/bin/PhoneBridgeMcp.exe",
      "args": []
    }
  }
}
```

On an installed Mac preview, the server entry uses `"command": "/bin/sh"` and `"args": ["/Users/Owner/.phonebridge/bin/phonebridge-mcp"]`. The shell entry reads `desktop-macos.json`; Windows reads `desktop.json`. Both resolve `pairing.json` beside that configuration (or its explicit `credentialFile` override), forward stdin/stdout/stderr, and return the MCP exit code. Windows credentials remain protected with DPAPI. The desktop defaults to port `8767`; the launcher always supplies the actual configured endpoint rather than using the standalone adapter's default port `8765`.

**One-time migration from 0.6.0 or an older copied configuration:** after installing the new preview, copy its MCP configuration and replace only the existing `phonebridge` server entry in your AI client. Remove that entry's old version-specific arguments and `PHONEBRIDGE_URL`/credential environment settings. Then disconnect/reconnect that MCP server or restart the AI client. Subsequent desktop upgrades do not require another AI configuration edit. A running MCP process keeps its current target until reconnect; it does not hot-swap. Windows installation retains the immutable fixed executable even while it is running and publishes active configuration changes atomically. The new launcher is installed before the active target changes; a failed publication preserves the old configuration and existing sessions.

Portable or development use without an installed fixed entry still copies an explicit Node path, MCP script and environment. That fallback is version-specific and must be copied again when its paths or endpoint change. Merely unpacking a portable update does not migrate the owned installation. The public 0.6.0 release retains its previous behavior; these fixed entries are part of the current preview.

Keep the desktop service running and confirm the phone is connected before requesting an observation. The phone's allowlist and action consent remain enforced for every operation.

For the current multi-device/control tools, teach the AI this convention:

1. Call `phone_list_devices` and choose a paired online phone. With several online phones, specify its `deviceId`; never guess or silently switch after disconnect.
2. Call `phone_acquire_control`. Retain the returned opaque `taskHandle` whether state is active or queued. If queued, call `phone_wait_for_control` (at most 25s per call); only an active grant permits observations, actions and files.
3. Pass that handle to every observation/action/file call. Observe, do one action, then observe again. `phone_wait_for` checks a screen condition for at most 10s; it is different from waiting for control.
4. Release with `phone_release_control` in `finally`, including cancellation or failure. Release also cancels queued tickets. Do not reuse expired handles, reacquire silently or replay uncertain actions after reconnect.

Waiting is FIFO, at most 64 tasks. Live waiting checks renew only that ticket's 120s lifetime. An active task expires after 60s without valid observations/actions; status reads and heartbeats do not keep it active. An open waiting tool call receives a grant through push notification, rather than repeated screenshots. PhoneBridge does not relaunch a closed AI client, contain a model, or schedule the business steps of the task. Phone and desktop show the current owner and waiting count. See the [protocol](protocol.md) for exact compatibility and errors.

These capabilities require the matching phone and Hub; unsupported methods return `UNSUPPORTED`. Preserve the installed fixed MCP entry and reconnect the AI client after upgrading; the entry is version-independent. The physical single-phone/two-computer queue test is pending and must be reported separately from simulated socket/widget checks. Do not replace public download URLs with an unpublished source version or claim that all current-source features are in the older download above.

For an Agent, use the copied command/arguments/environment as the local MCP connection specification. Verify a real connection and an owner-authorized read-only observation before reporting AI integration successful. Different AI clients store stdio server settings in different formats; convert this server entry to the client's supported format without transferring the pairing key or changing other servers.

## Recovery and rollback

Reopen PhoneBridge if the browser panel closes; double launch reuses the local client. A saved network that no longer exists is shown as unavailable; select the current private network. Disconnect the phone before changing networks. If an existing managed service is running, stop that owned service before changing its configured network.

Installer backups are beside `desktop.json` as `desktop.json.backup-<timestamp>` and `<backup>.task.xml`. To roll back after stopping the owned task, restore the desired JSON backup and register its matching XML using Task Scheduler or `Register-ScheduledTask`. The previous installation folder is retained. Never delete `pairing.json` during ordinary upgrades or rollback: doing so creates a new identity and requires re-pairing.
