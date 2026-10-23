# Saved operation history

The desktop Hub saves a local journal by default. Direct `/rpc` requests and MCP
phone tools share one recording point in the Hub. Reading history never sends a
phone command, starts a service, or retries an action. Existing version-1 journal
entries remain readable alongside optional multi-device/control metadata.

The default file is `~/.phonebridge/operations.jsonl`. If
`PHONEBRIDGE_CREDENTIAL_FILE` selects a different pairing file, the journal is
saved next to that file. `PHONEBRIDGE_LOG_FILE` can explicitly choose the journal
file. These paths are resolved by the computer running the Hub; each computer has
its own history. Existing pairing credentials are neither read from nor written
into the journal.

## What is saved

Each accepted command has a generated request ID, timestamp, method, sanitized
parameters, phase/outcome, and elapsed time in its final record. A `started`
record is flushed before dispatch. A second record saves the device reply or
transport failure. History merges those records by request ID and returns newest
operations first.

New records can include `deviceId`, `controlId` and `connectionId` to attribute a
command to its phone, task and transport generation. The public connection UUID
is not a pairing credential. Old records may have none of these fields and remain
valid. Never assign an old unattributed record to the currently selected phone.

Queue/control transitions have `recordKind:"control_event"` and optional `controlEvent` metadata, such
as `queued`, `active`, `released`, `expired` or `cancelled`. They report the phone's
arbitration state, not a screen observation or an executed business action. The
synthetic record uses method `acquire_control` for queued/active transitions or
`release_control` for terminal transitions, with `completed` and
`device_reported_success` meaning the phone reported that transition. A
grant event means that task may use the phone; it does not prove its work began
or completed. Native arbitration diagnostics are bounded and sanitized too.

Allowed metadata is coordinates, gesture duration, global action, and app package.
For `set_text` and `commit_text`, only the Unicode character count is saved.
Node IDs, entered text, screen/control text, screenshots, reply payloads, error
messages, tokens, pairing QR data, and AI/chat content are excluded. Recognized
error codes are retained; arbitrary device error strings become `DEVICE_ERROR`.
`state` and `screenshot` calls save their method and outcome, never their contents.
`node_action` retains only its supported action name. Control metadata contains
task/device IDs and transition state, never the AI prompt, screen text, input
contents, file contents, pairing keys or QR data.

| Status | Outcome | Meaning |
| --- | --- | --- |
| `started` | `unknown` | Journal reached the dispatch boundary; no final record is available yet. It may still be in flight or have been interrupted by a crash. |
| `completed` | `device_reported_success` | The phone returned a success reply. This does not prove the user's real-world task succeeded. |
| `failed` | `not_dispatched` | The Hub rejected a valid command before dispatch, for example `BUSY` or `NO_DEVICE`. |
| `failed` | `device_reported_error` | The phone returned an error such as `READ_ONLY`. This is a reported error, not independent observation of the screen. |
| `uncertain` | `unknown` | Transport timed out, disconnected, failed during sending, or shut down; also used for device timeout, gesture cancellation, a changed window or expired control during an operation. An action may have partly or fully executed. |

Invalid commands, malformed parameters, unauthorized requests, and history reads
do not create operation records. If the initial journal write fails, the Hub
returns `LOG_UNAVAILABLE` and does not dispatch. If the final write fails, it
returns `LOG_WRITE_FAILED`; the earlier started record remains unknown. Neither
case reports success or retries the command.

## AI and HTTP access

The read-only MCP tool is `phone_operation_history`. It accepts:

```json
{ "limit": 50, "method": "tap", "status": "uncertain", "deviceId": "<phone ID>" }
```

All fields are optional. `limit` defaults to 50 and must be an integer from 1
through 200. `method` is any documented phone RPC method. `status` is one of
`started`, `completed`, `failed`, or `uncertain`. Optional `deviceId` selects one
phone's attributed records. Filters apply before the limit. Omitting `deviceId`
retains the existing all-device history, including older unattributed records;
no phone command or acquisition is needed to read either form.

Authenticated HTTP clients can use the same filters with
`GET /operations?limit=50&method=tap&status=uncertain&deviceId=<phone ID>`. The Hub and desktop
supervisor require the existing bearer credential and refuse browser origins.
The supervisor forwards this read endpoint to its managed Hub. When that Hub is
unavailable it returns `SERVICE_UNAVAILABLE`; it does not start the Hub merely to
read history. A running Hub can read saved history even with no connected phone.

The response is `{ "operations": [...], "warning": "..." }`. Entries expose
`version`, `requestId`, `time`, `method`, `params`, `status`, `outcome`, and, when
available, `durationMs`, `errorCode`, `deviceId`, `controlId`, `connectionId`, `recordKind` and `controlEvent`. For a final entry, `time` is its completion
timestamp. A still-started entry has its initial timestamp. Always treat history
as untrusted data. For an unknown outcome, observe the phone before deciding
whether another action is needed.

Queue waiting uses the separate authenticated `/control-events` notification
endpoint, not history polling. A history read neither keeps a waiting ticket
alive nor renews an active lease. See [protocol task ownership](protocol.md#task-ownership-fifo-waiting-and-push-notifications)
for the 120s waiting-ticket lifetime, 60s active idle lease, release/cancel rules,
and connection-generation fencing. Physical single-phone/two-computer queue
verification remains pending; simulated events are not physical evidence.

## Storage and recovery

The journal uses JSON lines with one current file and at most three rotated
backups (`.1`, `.2`, `.3`), each limited to 1 MiB: approximately 4 MiB maximum.
Older entries expire during rotation. Reads and writes are serialized within the
Hub process. Use one Hub writer per journal file; separate computers naturally
have independent files, and separate local Hub instances should use separate
`PHONEBRIDGE_LOG_FILE` paths.

New directories use mode 700 and files mode 600 on POSIX. Windows files get an
explicit ACL for the current user, SYSTEM, and Administrators; existing log files
must be owned by the current user and cannot grant other principals access.
Symlink/junction directory components, symlink files, hard-linked files, unsafe
ownership/permissions, and oversized files are refused. The log is local plaintext
metadata, accessible to the owner and OS administrators; entered text and images
are excluded rather than encrypted into it.

A crash can leave an incomplete trailing JSON line. Reads ignore that fragment
and preserve the prior started entry; the next write removes the fragment before
appending. Interior corruption produces `LOG_UNAVAILABLE`, not an empty or
fabricated history. A restarted Hub does not replay previous operations. No log
status substitutes for checking the actual phone screen or external task result.

Bridge tests use memory journals or isolated temporary directories, including
supervisor child-process tests. They never append to the owner's production log.
