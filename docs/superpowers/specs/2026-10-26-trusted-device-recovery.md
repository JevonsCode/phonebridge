# Trusted device recovery and unattended file receipt

User direction: computer AI should complete phone workflows after the owner's initial setup. Replace repeated per-file confirmation with a persistent automatic-receive switch, and fix every unresolved/uncertain item in JevonsCode/rec#3. Reuse saved trust; do not introduce new pairing steps.

## File receipt

Add a bilingual “Automatically receive computer files” setting, enabled by default for already paired transports. Persist it locally. Enabled offers download sequentially into Download/PhoneBridge without a separate Accept tap; disabled offers remain available for manual receipt. Turning off does not interrupt a download already running. Queue and status must report real pending/receiving/received outcomes, retain source generation, and keep downloaded files/history. Remove the arbitrary 100-file count ceiling. Existing byte and integrity checks remain.

## Same computer after an address change

Desktop services recover an unavailable saved private address by selecting an active private network, binding a candidate, atomically updating their owned configuration and switching only after success. Cover Windows managed startup, desktop UI and macOS service paths, including runtime network changes. Keep the credential, port and phone grants.

The phone tries its saved endpoint normally, then discovers that same paired identity over IPv4 UDP 8766. The challenge contains only a derived identity and fresh nonce. Replies contain the actual listening endpoint and an HMAC using the existing paired token; no new token is broadcast. A same-subnet HTTP challenge fallback uses the already permitted TCP service port when UDP is filtered. Preserve computer ID/name/selection/permissions when persisting the new endpoint. Stale discovery results, pause/forget and replaced transports cannot reconnect a stopped identity. Reconnect never replays a screen mutation.

Wire format: identity = HMAC-SHA256(token, `PhoneBridge discovery identity v1`) lowercase hex; request `{type:phonebridge_discover, version:1, identity, nonce}`; reply `{type:phonebridge_found, version:1, identity, nonce, endpoint, proof}`. Nonce is 16 random bytes in hex. Proof input is `PhoneBridge discovery v1\n<identity>\n<nonce>\n<endpoint>`.

## MCP and diagnostics

Make fixed-launcher help/version useful, retain old-launcher protocol compatibility and upgrade idle launchers atomically. Server version comes from the installed app manifest (development uses repository version). Publish self-contained coordinate schemas without $ref. Add verified Claude Code registration/removal instructions and register the current user's installation without changing unrelated MCPs. Existing MCP processes follow owned endpoint updates before dispatch; never retry uncertain mutations.

NO_DEVICE results and device listing include the current computer endpoint, known-phone online/offline/read-only status, last-seen information when actually known, and concrete next actions. Do not invent a phone's settings or claim an online read-only phone is disconnected.

## Validation and delivery

Retain the already verified FIFO lease/queue contract; re-run competing AI clients and gesture/task handoff checks. Add deterministic cross-language discovery vectors and real UDP/HTTP challenge fixtures, network migration/rollback tests, offline diagnostics and real stdio schema/help/version checks. Verify auto receipt using a real harmless file when a phone is available. Preserve installed pairing and user data during upgrades. Keep PR #11's app-selector correction included for combined testing; keep that PR reviewable separately. Submit a reviewable follow-up PR and close rec#3 only after its issues have actual supporting verification and integration.
