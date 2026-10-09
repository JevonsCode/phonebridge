# Contributing

Use small changes with a clear reproducible problem. Run the bridge tests/build and Flutter analyze/tests before submitting. If touching native accessibility, also run `mobile/android/gradlew :app:testDebugUnitTest` and build an APK. Record Android version, device/ROM and app version for real-device reports, with all private data removed.

Do not weaken consent, authentication, read-only default, window checks, secure screenshot handling, or stop behavior to make an automation pass. Add regression coverage for protocol and permission changes. Never add telemetry without a separate design and explicit opt-in.

Protocol changes must preserve v1 or negotiate a new version. Keep the mobile command dispatcher and MCP schemas aligned. Each action must have bounded parameters and report actual platform results; multi-step tasks belong to the agent, not hidden retries.

Source contributions are licensed under MIT. Use dependencies whose licenses permit redistribution and document bundled components. Generated local settings, tokens, certificates, signing keys, device screenshots and build outputs must stay out of Git.
