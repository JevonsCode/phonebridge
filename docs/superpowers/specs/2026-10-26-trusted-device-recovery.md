# Trusted device recovery and unattended file receipt

User direction: computer AI should complete phone workflows after the owner's initial setup. Replace repeated per-file confirmation with a persistent automatic-receive switch, and fix every unresolved/uncertain item in JevonsCode/rec#3. Reuse saved trust; do not introduce new pairing steps.

## File receipt

Add a bilingual “Automatically receive computer files” setting, enabled by default for already paired transports. Persist it locally. Enabled offers download sequentially into Download/PhoneBridge without a separate Accept tap; disabled offers remain available for manual receipt. Turning off does not interrupt a download already running. Queue and status must report real pending/receiving/received outcomes, retain source generation, and keep downloaded files/history. Remove the arbitrary 100-file count ceiling. Existing byte and integrity checks remain.

## Same computer after an address change

Desktop services recover an unavailable saved private address by selecting an active private network, binding a candidate, atomically updating their owned configuration and switching only after success. Cover Windows managed startup, desktop UI and macOS service paths, including runtime network changes. Keep the credential, port and phone grants.

The phone tries its saved endpoint normally, then discovers that same paired identity over IPv4 UDP 8766 where supported. Windows uses the same-subnet HTTP challenge on its existing TCP service port without opening an additional UDP listener. The challenge contains only a derived identity and fresh nonce. Replies contain the actual listening endpoint and an HMAC using the existing paired token; no new token is broadcast. Preserve computer ID/name/selection/permissions when persisting the new endpoint. Stale discovery results, pause/forget and replaced transports cannot reconnect a stopped identity. Reconnect never replays a screen mutation.

Adding or scanning another computer keeps current connections running. Canceling a scan preserves pairing and drafts; changing the target resets its unsubmitted application draft. An existing computer becoming connected cannot complete a different pending pairing form. The home screen reports the selected computer's connection and actions, while the global pause remains available if any computer is connected, connecting or retrying.

Wire format: identity = HMAC-SHA256(token, `PhoneBridge discovery identity v1`) lowercase hex; request `{type:phonebridge_discover, version:1, identity, nonce}`; reply `{type:phonebridge_found, version:1, identity, nonce, endpoint, proof}`. Nonce is 16 random bytes in hex. Proof input is `PhoneBridge discovery v1\n<identity>\n<nonce>\n<endpoint>`.

## MCP and diagnostics

Make fixed-launcher help/version useful, retain old-launcher protocol compatibility and upgrade idle launchers atomically. Server version comes from the installed app manifest (development uses repository version). Publish self-contained coordinate schemas without $ref. Add verified Claude Code registration/removal instructions and register the current user's installation without changing unrelated MCPs. Existing MCP processes follow owned endpoint updates before dispatch; never retry uncertain mutations.

NO_DEVICE results and device listing include the current computer endpoint, known-phone online/offline/read-only status, last-seen information when actually known, and concrete next actions. Do not invent a phone's settings or claim an online read-only phone is disconnected.

## Echo feedback additions

Provide clipboard get/set and native paste/copy/cut/select-all without per-operation confirmation. A persistent owner switch controls clipboard access; Android's foreground requirement uses a short focused activity that restores the previous app. Return truncation metadata within the existing wire budget instead of adding an arbitrary text-size rejection.

Resolve text/description/resource/class selectors against the current tree, require explicit index for ambiguity, and support screenshotId plus image coordinates using the original crop. Preserve Android stateDescription and selection ranges. Add foreground package/window/occlusion diagnostics without recording screen or clipboard contents in operation history. Explicit task renewal extends only the current active task and cannot revive an expired or queued task.

Default received images/videos into the media gallery, retaining the option to use Downloads. Expose actual transfer expiry and saved location. Mark precise PhoneBridge connection/authorization controls with semantics IDs. Connection-control protection is optional and defaults off; only an explicitly enabled saved switch prevents accidental remote changes. Clipboard, automatic receipt, and gallery remain enabled by default.

Provide one owner “Allow all” action for the selected computer: all eligible applications, actions, resume, clipboard, automatic file receipt and gallery, with connection-control protection disabled so the AI can also change its own settings. Preserve existing computer identities and other computers' grants. The currently connected test phone should have these capabilities enabled. Install both desktop and phone, then have the existing Grok Bot Echo publish one FULI item using the updated tools and report the resulting link and observed issues.

## Validation and delivery

Retain the already verified FIFO lease/queue contract; re-run competing AI clients and gesture/task handoff checks. Add deterministic cross-language discovery vectors and real UDP/HTTP challenge fixtures, network migration/rollback tests, offline diagnostics and real stdio schema/help/version checks. Verify auto receipt using a real harmless file when a phone is available. Preserve installed pairing and user data during upgrades. Keep PR #11's app-selector correction included for combined testing; keep that PR reviewable separately. Submit a reviewable follow-up PR and close rec#3 only after its issues have actual supporting verification and integration.
