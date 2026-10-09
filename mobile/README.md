# PhoneBridge Android app

See the [root README](../README.md) for setup, pairing, privacy, and building.

- `lib/`: Flutter consent, connection controls, and playground.
- `android/`: Kotlin AccessibilityService and transport.
- `test/`: widget regression tests.
- `integration_test/`: real Android service smoke test, run on an isolated emulator.

Build a normal preview APK with `flutter build apk --debug`; never distribute the integration-test APK. It uses a test-only entrypoint and temporary test credentials.
