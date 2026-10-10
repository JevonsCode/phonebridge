# F-Droid packaging request draft

Not submitted. Resolve the build and updater prerequisites in [distribution status](distribution.md) before sending this request.

## App

Name: PhoneBridge

Application ID: `dev.phonebridge.phonebridge`

Source: https://github.com/JevonsCode/phonebridge

Website: https://xn--8ovp9s.xn--m8txu.com/phonebridge/

License: MIT

## Description

PhoneBridge connects an Android phone to an MCP-compatible AI client through a desktop Node.js bridge. It uses an owner-enabled accessibility service to inspect the visible interface, capture screenshots, and execute taps, holds, swipes and text input. The phone saves its paired computer and supports local-network wireless reconnects. Chinese and English are supported.

The App includes no AI model or cloud relay. The selected AI client may send screen content to its model provider. Source code is AI-assisted. Screenshots and control require the owner's accessibility authorization; actions are separately enabled on the phone.

## Packaging notes requiring resolution

- Android: Flutter + Kotlin; Node.js 22+ desktop setup is documented in README.
- Current public binaries are ARM64 developer previews signed with a debug key. They are not a validated F-Droid release build.
- Fastlane descriptions and the project icon are included. Publish privacy-safe screenshots before submission.
- Validate a source-build recipe with pinned Flutter/Android dependencies and a tagged release.
- The current optional updater downloads GitHub release APKs after an explicit button press. Add the required F-Droid bypass notice or disable that updater in an F-Droid distribution variant before submission.
- Preserve installation/signature continuity; F-Droid signing must not be presented as an in-place update of the existing preview key.
- Search existing RFP and fdroiddata entries for duplicates before opening a request.

No claim of F-Droid acceptance or successful source build is made in this draft.
