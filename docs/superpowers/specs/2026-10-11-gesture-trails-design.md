# PhoneBridge operation trails — proposed design

## Requested behavior

Show where the AI acts on the phone. Add a Chinese/English Settings switch, enabled by default and saved across App updates and launches. It only controls visualization; changing it never reconnects or alters action permission.

## Choice

Use an AccessibilityService overlay so the indication works in allowed target Apps, including WeChat. A Flutter-only indicator cannot show over other Apps. Android's developer Pointer location/Show taps settings affect the whole phone and do not provide a portable per-App toggle.

## Visuals and scope

- Tap: a small blue dot with a short fading ring, about 450 ms.
- Long press: show the point during the hold, then fade.
- Swipe: move a small dot along the actual start/end coordinates and reveal a thin rounded path over the gesture duration; fade the remaining path in about 350 ms.
- Include coordinate gestures and accessible node clicks. Show a trace only once the operation is accepted; a trace is a location cue, not proof of target-App success.
- Display AI-issued actions only. No collection of the owner's manual touches or history.

## Native integration

Keep the overlay non-focusable, non-touchable and excluded from accessible content. Use the existing enabled accessibility service; do not request a new application-overlay permission. Match display coordinates and insets so dots align with the real gesture.

Bound drawing to one active animation. Remove it on switch-off, stop/disconnect, interruption, service teardown or display changes. Overlay failure must not fail or replay a phone action. The observation pipeline must remove the App's own trail before tree/screenshot reads, allow the compositor to settle, and retain all other window checks; never broadly ignore unrelated overlays.

Store one boolean preference independently of pairing, consent and language. Expose its get/set through the existing Flutter MethodChannel; disabling clears any current trace immediately. Translate its label and explanation.

## Verification and delivery

Verify default/persisted toggle behavior, coordinate timing, cancellation/cleanup and existing checks without tests that simply mirror UI implementation. Build and upgrade the current phone; foreground it with ordinary ADB am start (never force-stop). Record real tap and swipe animations on the phone, ensure switch-off hides them and screenshots/state reads keep working. Preserve pairing/actions. Publish the verified APK and update the official manifest/download links; leave previous releases available.
