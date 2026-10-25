# PhoneBridge 0.7.1

PhoneBridge 0.7.1 makes trusted phone workflows easier to complete and reconnects remembered computers when their local address changes. Existing pairing and settings are retained.

## Changes

- Read and write the clipboard; paste, copy, cut and select all. Text actions and explicit App launches now work while another App is in the foreground, including Xiaomi's smart-text overlays.
- Find controls using the current screen tree, map screenshot coordinates to the phone, inspect raw screen state and renew active tasks. Transient missing-window reads no longer stop page waits.
- Receive files from trusted computers automatically and save images and videos to the gallery. Persistent switches and one Allow all action let the phone owner choose the behavior.
- Select or clear all eligible Apps with a checkbox. Remove the 64-App selection limit.
- Preserve remembered computers while adding or switching peers. Rediscover paired computers after their address changes, and let an existing MCP session follow the new endpoint.
- Improve Windows startup, stable MCP launcher updates, network-name text and PowerShell 5 packaging.
- Update both website languages to show AI operating real phones for development, regression testing and bug reproduction.

Install the Android APK and update the desktop client to 0.7.1. Reconnect your AI client's MCP session to load the new tools. Android 11+ ARM64; Windows 10/11 x64; macOS 13+ Apple Silicon or Intel.

## Validation

- Application source `2ed7818`: mobile analysis and 138 Flutter tests; 227 Android JVM tests; desktop analysis and 38 Flutter tests; Bridge 135 passed / 2 platform skips; desktop/scripts 104 passed / 13 platform skips. [Android and Bridge CI](https://github.com/JevonsCode/phonebridge/actions/runs/40238560379) and [Windows / both Mac architectures](https://github.com/JevonsCode/phonebridge/actions/runs/40238560394) passed.
- Signed Android 0.7.1 and Windows 0.7.1 were installed locally with existing pairing retained. Real-device checks covered foreground clipboard access, switching Apps through one MCP workflow, selectors, screenshot-coordinate taps, 168-App select/clear, automatic Downloads/gallery receipt and readable operation history.
- Two independent MCP clients verified queued access and control handoff. The physical phone rediscovered a changed LAN listener and returned to its original address without scanning or changing pairing; the same MCP session followed both changes.
- The owner reported that Grok Bot testing found no remaining problems and approved publication. Website and release-note changes after the tested application commit do not alter the packaged application source.

Mac runtime and packaging checks ran in CI. Two physical computers controlling the same phone and long unattended sessions were not exercised in this run. Android retains the existing preview signing identity for compatible upgrades; Mac packages are ad-hoc signed and are not Apple Developer ID notarized.
