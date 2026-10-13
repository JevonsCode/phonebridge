# Android download QR and local Mac installation

**Goal:** Install the published Mac 0.6.1 without changing pairing, and let users scan a public Android APK download QR from the release, README and both website languages.

**Design:** Encode the exact verified GitHub ARM64 APK URL, with a white quiet zone and black modules. Website/README show the current QR beside a version label and a clickable download link. Each release keeps a version-specific PNG asset in its notes. Reuse the locked `qrcode` dependency already shipped in Bridge; no external QR service, redirect service or pairing credentials.

**Implementation and verification:**
- [x] Verify the official Mac ARM64 ZIP digest/signature; stop only the owned service/window; back up and replace the App in `/Applications`; launch and check the installed runtime, original identity and MCP.
- [x] Extend `scripts/release-distribution.mjs` with an explicit binary QR output in its existing guarded path allowlist. Generate only after APK validation. Preserve current public QR on stale releases; keep generation deterministic and same-release runs idempotent. Cover these behaviors in `scripts/test/release-distribution.test.mjs` before implementation.
- [x] Add a focused release-note publisher with official APK identity checks, immutable QR asset uploads and an idempotent bilingual notes section. Test unchanged body preservation, duplicate sections, conflicting asset bytes and invalid targets before publishing.
- [x] Add a labeled QR in README and the Chinese/English download sections. A phone-browser link stays usable without another screen to scan. Update release workflow dependency preparation, allowlisted staging and QR publication.
- [x] Independently decode generated PNG with macOS Vision and compare the exact APK URL. Inspect pages in the user's real Chrome at desktop/mobile widths. Fixtures are synthetic test metadata only; published QR and download checks use the actual release.
- [ ] Run relevant Node suites, commit/push the user-requested GitHub changes, merge after CI, dispatch distribution on main, verify public release PNG and all entry points. Keep existing APK/desktop assets and v0.6.1 tag unchanged.

**Scope:** No new App binary, private pairing QR publication, store submission, security-setting changes, or unrelated site redesign.
