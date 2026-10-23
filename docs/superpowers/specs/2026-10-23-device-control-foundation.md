# Desktop AI phone control foundation

User-approved scope: PhoneBridge supplies observation and actions to AI running on a computer. No embedded model, business-specific workflows, or cloud account. This implementation supersedes the unimplemented 2026-10-11 network draft where noted below. Existing trust, permissions, text redaction and saved pairing remain intact.

## Delivery units

1. Android screen-awake preference and concurrent computer connections, with phone-side control arbitration.
2. Hub device routing, MCP task handles, operation attribution and capability negotiation.
3. Better observations and element actions, bounded waits/assertions for computer AI, and device lists in Flutter.

The user authorized implementation of all units. They will be tested together; simulation and physical tests must be clearly distinguished. A current physical phone is available; a second phone/computer may be simulated. No claim of Mac hardware verification.

## Screen awake

Persist `off`, `controlling`, `always`; default `controlling`. `controlling` holds the display only while a nonexpired control lease exists and the accessibility service is available. `always` holds it while that service is running even when disconnected. Explicit screen-off/lock must win: do not wake or unlock the phone. Release on service teardown, preference off or lease end. Android must keep other foreground apps visible, so a foreground-activity-only flag is insufficient. Use a bounded renewable display wake lock without ACQUIRE_CAUSES_WAKEUP; no system screen-timeout edits. Expose selected mode and actual held state for diagnostics. Bilingual setting explains that Always applies while PhoneBridge service runs.

## Transport and routing contract

- Hub accepts multiple authenticated sockets and replies to the upgrade with `X-PhoneBridge-Protocol: 2`. New Android checks this header; old Hubs receive the unchanged protocol-1 hello. Protocol-2 hello: `{type:'hello',protocol:2,deviceId,device,readOnly,capabilities:[...]}`. Persist phone UUID independent of IP and computer pairings. Duplicate live IDs cannot replace another socket. Legacy hello is supported in a single legacy slot and never treated as a stable named identity.
- Auth remains the existing owner-computer token. This release does not claim independently revocable per-phone credentials. Do not expose tokens in lists/logs. Saved trust is not rescanned/recreated.
- `/status` retains `connected`, `busy`, `protocol`, `transfer` for existing clients and adds `devices`. `/devices` returns the online device list including stable id, display name, protocol, capabilities, busy and read-only status. Disconnected known devices remain visible for the lifetime of the Hub with connected=false; do not silently route to a different phone.
- RPC envelope is `{method,params,deviceId?,controlId?}`. Exactly one online phone permits omitted deviceId for backwards compatibility; multiple online phones require an explicit deviceId. Unknown/offline target fails, never falls back. Per-device pending, journal attribution, file slots, heartbeat and timeout. Failure of one socket cannot close another.
- Native receives `{id,method,params,controlId?}`; `deviceId` is resolved at the Hub, not forwarded. Protocol-1 clients still receive legacy shapes. New methods return UNSUPPORTED when capability is absent, rather than sending unsupported actions.

## Phone control arbitration

- All saved enabled computers maintain independent retrying transports. Active computer selection chooses the local UI target and explicitly hands control to it; it does not disconnect other saved computers. Global Stop pauses all; forgetting stops only that computer.
- `acquire_control({controlId})`, `release_control({controlId})`: controlId UUID. Lease is bound to a transport computer and controlId. Monotonic idle expiry 60s, refreshed only by that task's valid command, not by network pings. A competing task gets CONTROL_BUSY with the owning computer's name. Missing controlId is a legacy implicit task, acquired only when free, never stealing an explicit task.
- One shared executor fence across all connections. A handoff, disconnect or lease expiry invalidates stale observations/completions, but does not admit another mutation until the dispatched operation settles (or its bounded cancellation/timeout completes). Do not replay any command after reconnect.
- State and screenshot also respect ownership, since interleaving observations corrupts cached node identities. Device listing is always available without control.
- Phone status adds control owner and per-computer connected/connecting/paused/controlling state. Current settings and selected-computer action consent remain backward compatible. Each computer retains its own allowlist/action consent. During execution, service checks use that operation's context; no global UI-selected target can change a running request's authority.

## MCP

Fixed installation entry stays unchanged. Add `phone_list_devices`, `phone_acquire_control(deviceId?)` returning an opaque taskHandle, `phone_release_control(taskHandle)`. The MCP process privately maps each handle to a fixed deviceId/controlId. Other tools accept optional taskHandle and deviceId; conflicting targeting is refused. New multi-device callers should always use handles. Legacy one-phone calls remain compatible. Expired/disconnected handles fail and are not transparently reacquired/replayed. Best-effort release on process shutdown.

Add `phone_wait_for` and `phone_assert` using bounded read-only state observations. Conditions are literal package/text/description/resourceId/absence, no scripts or regex execution. Wait checks never repeat mutations, target does not change mid-wait. Return match evidence and last state on timeout. A lease expires normally unless observations actively renew it. Maximum wait 10s per call.

## Observations and actions

State adds snapshot identity/time, resourceId, enabled, selected, checked/focused flags and supported action names without removing existing fields. Node ids remain short-lived and bound to the observing task. Add `node_action({nodeId,action})` for click, long_click, scroll_forward, scroll_backward, focus. Use the freshest cached accessible node, recheck window/package/bounds and enabled state, refuse stale/ambiguous/password nodes; invalidate after action. Existing coordinate actions stay available. The caller AI remains responsible for deciding the steps and observing their effect.

## Logs and outcomes

Keep existing append-before-dispatch journal and sanitized params. Add optional deviceId and controlId attribution and deviceId history filter; preserve old log readers/records. Preserve known outcomes: not_dispatched, device_reported_success, device_reported_error, unknown. Do not equate dispatch success with completion of the user's task. Timeouts and lost replies remain uncertain, never retried. Local phone control arbitration events are bounded and sanitized; no screen text, input content, credentials or file contents.

## Flutter and verification

Mobile computer sheet shows concurrent state and control owner; selection performs deliberate handoff. Desktop shows every phone with identity/name/state and busy indication, retaining existing onboarding. Screens use current styles, rounded clipping and complete Chinese/English labels. No new mandatory scan, confirmation or command line.

Tests: legacy protocol and old tools, two phone sockets in parallel, missing/wrong/offline target, duplicate ids, timeout isolation, attributed logs, task handle isolation, waits/assertions, two computer lease competition, expiry while executing, connection generation fences, per-computer consent/forget/stop, persisted wake modes/release and widget states. Build Android/desktop, install Android over existing signing identity, verify pairings/connection retained and screen-awake behavior on the attached phone. Keep public release claims limited to evidence; no public release with unresolved control-routing risks.
