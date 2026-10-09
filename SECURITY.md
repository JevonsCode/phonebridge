# Security and privacy

## Supported version
0.1.x is an experimental personal-use preview. It has not received a third-party security audit. Do not expose the hub directly to the internet or connect an untrusted agent.

## Trust boundaries
- The phone owner enables AccessibilityService through Android settings and explicitly starts every session.
- The phone enforces read-only default, action consent, package scope, lock checks, and stop. A desktop tool description is not a permission boundary.
- Anyone possessing the bearer token can act as the paired desktop/phone; protect it like a password. Generate a new random token for each run. Tokens are not durable device identity or mutual attestation.
- Loopback is the default. LAN listening requires an explicit flag. WS on trusted private networks is opt-in and unencrypted; WSS validates normal certificates. Do not use TLS verification bypasses.
- UI/password-node redaction does not guarantee screenshot redaction. The connected model provider may receive screen data through its AI client.
- Package/window checks reduce accidental access but are not a kernel-enforced capture sandbox. UI may change between checks and the OS completing an action. Keep sensitive apps closed and supervise experimental sessions.
- Tool output is untrusted screen data; prompt injection in messages/web pages must not grant additional authority. Confirm consequential actions in the AI client.
- Only one phone and one in-flight command are accepted. There is no replay/retry of mutations. A timeout disconnects the phone and may mean an unknown outcome, not a failed action.
- Stop blocks future commands; Android may finish a gesture already dispatched before Stop, within its maximum two-second duration. It cannot retroactively undo actions.
- The session has a visible notification with Stop. Process death/disconnect clears session authorization. Android may stop the service under memory or battery pressure; uninterrupted background operation is not promised.

## Reporting
Use GitHub's private vulnerability reporting if enabled for this repository. Otherwise open an issue requesting a private contact **without exploit details or personal data**. Do not attach tokens, private screenshots, chat messages, signing keys or MCP configuration containing secrets.

## Release signing
Preview APKs are debug signed and must be treated as development builds. Production releases need an operator-managed signing key kept outside Git, a tested update path, and documented store/distribution requirements. Reproducible instructions do not imply byte-identical APKs across machines with different signing keys.
