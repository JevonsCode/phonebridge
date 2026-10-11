# PhoneBridge desktop

Flutter desktop companion for the retained private Node dashboard protocol.
The Windows binary is `PhoneBridge.exe`; the macOS product is `PhoneBridge.app`.

## Development and validation

Use Flutter 3.41.9, then `flutter pub get`, `flutter analyze`, and `flutter test`.
The protocol tests use ephemeral loopback servers and fake child processes; they do
not touch saved pairing, firewall rules, or the managed service.

Set `PHONEBRIDGE_SCREENSHOTS=1` when running tests to write four fixture screenshots
into `artifacts/`. These show test data, not proof of a live phone connection.

Build with `flutter build windows --release` or `flutter build macos --release`.
Use the repository packaging scripts to combine the Flutter output with the bundled
Node runtime, dashboard scripts, and bridge. Running an unpackaged Flutter build
shows a visible missing-runtime message.

Windows resources sit beside the executable (`runtime/node.exe`,
`desktop/server.mjs`); macOS resources sit in `Contents/Resources`
(`runtime/node`, `desktop/macos/server.mjs`). Native runners handle diagnostic
arguments before creating Flutter windows.

The UI stores only its language choice in `~/.phonebridge/desktop-language`.
Private session URLs remain in memory. Requests reject redirects and use exact
Origin and CSRF headers for mutations. Window close and macOS Quit clean up only
the child dashboard process owned by this frontend; installed services remain
independent.

Noto Sans SC is bundled under the SIL Open Font License in `assets/fonts/OFL.txt`.
The brand image is exported from the repository's canonical generated source.
