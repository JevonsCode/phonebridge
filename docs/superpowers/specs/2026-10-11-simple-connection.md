# Simple connection for 0.6.0

The user asked for a lightweight desktop client, AI-friendly installation, multiple remembered computers, implementation, testing and a 0.6.0 release. The user explicitly authorized routine completion and publication without another design confirmation.

## Desktop

Windows first: a self-contained per-user installer and portable package, bundling a pinned official Node.js runtime and compiled bridge. No terminal, npm or IP lookup for end users. A small launcher opens a local dashboard in the default browser. The dashboard starts the supervisor, displays the existing pairing QR and connection status, and offers computer network selection only when needed. Use the current pairing identity and service configuration when present, never overwrite the owner's existing trust.

Automatically choose an active private LAN address, favour the default-route physical interface over VPN/virtual adapters, and expose a concise network selector for ambiguity. Bind the dashboard to loopback; keep the existing explicit LAN scope of the phone service. Do not silently add public-network firewall rules or delete existing configuration. Current-user startup uses the existing managed task with a backup when migrated; preserve pairing and allow rollback.

Download the APK from the public release; include straightforward phone installation instructions. The Android installation confirmation and accessibility enablement remain owner actions. AI installation documentation uses the same verified installer and CLI diagnostics; with owner-authorized USB, an Agent may install the APK and launch the App. Do not claim bypass of Android permission screens.

## Phone

Remember several paired computers, select one active connection at a time. Show name/address/current state; connect or switch with one tap. Each computer retains its own pairing identity, allowed Apps, action consent and resume preference. Switching closes the old session, clears observations/trails, and never replays an in-flight operation. A new computer is paired once; switching remembered entries requires no re-scan.

Migrate the existing encrypted single record without data loss. Keep encrypted storage and no-secret platform status. Forget only the selected computer; stop/pause remains durable. A friendly editable name is useful; endpoint hostname is the initial fallback. Keep the wire control protocol unchanged unless optional backward-compatible pairing metadata is necessary.

## Verify and release

Test installation on Windows without requiring Node from PATH, automatic address selection, existing-config reuse, startup backup/rollback, duplicate-launch behavior and actual phone reconnect. Test two local computer endpoint identities (clearly simulated second computer) switching on the real phone, retained per-computer action choices, migration and forgetting. Do not call this two physical computers or simultaneous control.

Complete operation-trail fast screenshot regression, default/off persistence and phone update. Integrate website download channels and release-distribution workflow, run source checks and real published workflow, then publish v0.6.0 with direct ARM64 APK and Windows installer. Keep prior previews available.
