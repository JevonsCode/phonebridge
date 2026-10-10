# Install PhoneBridge with an AI assistant

PhoneBridge 0.6.0 provides a Windows installer with its own Node.js runtime. The owner does not need Node.js, npm, a terminal, or a manual IP lookup. One phone can remember several paired computers; it connects to one selected computer at a time.

## Windows

1. Open the [v0.6.0 release](https://github.com/JevonsCode/phonebridge/releases/tag/v0.6.0). Download `phonebridge-0.6.0-windows-setup.exe` and its `.sha256` sidecar. An Agent should read the release asset digest and compare SHA256 with the downloaded file before running it. If the release is not yet published, do not claim these downloads are available.
2. Run the installer as the current user. It extracts under `%USERPROFILE%\.phonebridge\app\versions\0.6.0\bundle-<package-hash-prefix>`, creates a Start menu shortcut, and registers or migrates the owned current-user `PhoneBridge Desktop` logon task. Distinct builds use distinct payload folders, preserving a running older build; reinstalling the identical installer reuses its payload. It requires Windows 10/11 x64 and .NET Framework 4.8. No administrator elevation or firewall-rule creation is performed. If an AI desktop app redirects AppData writes, installation creates a physically visible Desktop shortcut immediately; the unpackaged managed startup task repairs the Start menu shortcut. User-profile runtime storage remains accessible to Task Scheduler in either environment.
3. Open **PhoneBridge** from the Start menu. The local browser panel shows a private pairing QR and phone connection status. The client selects an active private Ethernet/Wi-Fi address. If several networks are available, use the panel's network selector.

An existing `%USERPROFILE%\.phonebridge\desktop.json` and DPAPI-protected pairing identity are reused. Installer migration changes installation paths while preserving the configured address, port and pairing identity. It saves configuration backups and the previous managed task XML before changing paths. A running service continues; new startup paths apply at its next start. Foreign configurations or tasks are rejected.

If Windows prompts about a network connection, the owner decides whether to allow the private network. Keep both devices on a mutually reachable private network; guest Wi-Fi isolation can block them. PhoneBridge does not automatically add public-network firewall rules.

The optional `phonebridge-0.6.0-windows-x64.zip` portable package contains `PhoneBridge.exe`. Extract the whole ZIP, then open that executable. Portable use does not register startup itself. Existing owned service configuration takes precedence over the extracted package, so unpacking a new version alone does not migrate an installed service.

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

To remember another computer, scan that computer once. Later, select it from the phone's remembered computer list. Switching closes the previous connection; only one computer remains active. Keep action consent and allowed Apps scoped to each computer.

## Connect an AI client

If the local service is ready but the phone times out, expand **Phone cannot connect? / 手机无法连接？** in the dashboard and click **Allow LAN connection / 允许局域网连接**. The Windows owner must approve the UAC prompt. Installation and ordinary startup never request elevation automatically. This creates one named, owner-marked TCP port rule for **Private** networks and **LocalSubnet** only; Windows Firewall stays enabled. The port rule survives runtime version-folder changes, so ordinary upgrades keep this permission.

The helper removes only local, inbound Windows-generated `TCP Query User{...}` block rules whose application path exactly matches the current owned package's `runtime/node.exe`. It leaves UDP blocks, other applications, previous installations and custom or policy blocks untouched. A foreign or modified rule using the same managed name causes a refusal. If Windows uses another administrator account for elevation, the owner mismatch also causes refusal; the Windows owner can review the narrow rule manually. If rule creation fails, application blocks remain. A later deletion failure reports an unsuccessful request and leaves any remaining blocks intact; retry or inspect the owner-managed rule before reporting connectivity success.

Use a trusted **Private** home/work network. This button does not change the network category or enable Public-network access. Retry the phone connection and verify its connected state after approval; local `/status` success alone does not prove LAN reachability. It does not change Android permissions or pairing identity. Agents may run `desktop/allow-lan.ps1 -ConfigurationPath <owned-config> -ValidateOnly` for a read-only rule plan. `-RequestElevation` is an explicit owner action; never invoke `-Apply` silently on the owner's behalf.

In the local dashboard, expand **Connect AI / 连接 AI** and click **Copy MCP configuration / 复制 MCP 配置**. Add the generated stdio server to an AI client that accepts `mcpServers` JSON. The dashboard fills the actual installed Node path, compiled MCP entry, current service address and port, and saved credential file. It does not put the pairing key in the configuration.

This is the generated shape; the example paths and LAN address below are illustrative. Use the dashboard's copied values for your computer:

```json
{
  "mcpServers": {
    "phonebridge": {
      "command": "C:/Users/Owner/.phonebridge/app/versions/0.6.0/bundle-example/runtime/node.exe",
      "args": ["C:/Users/Owner/.phonebridge/app/versions/0.6.0/bundle-example/bridge/dist/mcp.js"],
      "env": {
        "PHONEBRIDGE_URL": "http://192.168.1.20:8767",
        "PHONEBRIDGE_CREDENTIAL_FILE": "C:/Users/Owner/.phonebridge/pairing.json"
      }
    }
  }
}
```

The desktop defaults to port `8767`; setting `PHONEBRIDGE_URL` explicitly avoids the standalone MCP adapter's default port `8765`. The MCP process reads the current user's saved DPAPI credential. Keep the desktop service running and confirm the phone is connected before requesting an observation. The phone's allowlist and action consent remain enforced for every operation.

For an Agent, use the copied command/arguments/environment as the local MCP connection specification. Verify a real connection and an owner-authorized read-only observation before reporting AI integration successful. Different AI clients store stdio server settings in different formats; convert this server entry to the client's supported format without transferring the pairing key or changing other servers.

## Recovery and rollback

Reopen PhoneBridge if the browser panel closes; double launch reuses the local client. A saved network that no longer exists is shown as unavailable; select the current private network. Disconnect the phone before changing networks. If an existing managed service is running, stop that owned service before changing its configured network.

Installer backups are beside `desktop.json` as `desktop.json.backup-<timestamp>` and `<backup>.task.xml`. To roll back after stopping the owned task, restore the desired JSON backup and register its matching XML using Task Scheduler or `Register-ScheduledTask`. The previous installation folder is retained. Never delete `pairing.json` during ordinary upgrades or rollback: doing so creates a new identity and requires re-pairing.
