# PhoneBridge 0.7.0 integration and release plan

**Goal:** Integrate the open app-authorization PR with multi-device control, verify combined behavior, update the bilingual website and README, and publish a consistent developer-preview release.

**Authorization:** The owner explicitly requested merge, integration testing, documentation updates and a new release. Preserve phone pairing and the existing preview signer; request owner help through DingDong only for actual local authorization or an external blocker.

**Release identity:** v0.7.0 already exists as an unpublished draft with no tag. Include the merged authorization fix in the final tag. Use Android source build 2024 (ARM64 split 4024), newer than the installed local 4023. Desktop version is already 0.7.0. Existing desktop CI artifacts may be reused only after confirming their source inputs match this release's unchanged desktop code.

- [x] Enumerate open/recent PRs and checks. #8 already merged; #9 checks passed, no conflicts, merged as 46b0e10.
- [ ] Verify bridge, desktop lifecycle/distribution and Flutter desktop tests; retain current integrated mobile 105 / native 145 test evidence and build the final signed APK.
- [ ] Compare desktop CI source inputs, download and hash-check all platform assets; exercise the actual Apple Silicon package locally.
- [ ] Upgrade the physical phone preserving pairing and grants. Verify Chrome and PhoneBridge observations/actions, two independent AI task queues, selected app grants, screen-awake settings, LAN file receipt/share entry and operation history without sending to a contact.
- [ ] Refresh README and Chinese/English website for multi-device control, queue handoff, allowed-app selection and LAN file transfer. Keep download links/QR tied to verified published bytes through release automation.
- [ ] Commit the release changes, open/merge their PR after checks, tag the final source, upload all checked assets and publish the existing 0.7.0 draft as a preview.
- [ ] Confirm distribution/Pages success, release asset hashes, live manifest, bilingual downloads and QR target. Record physical vs simulated test boundaries and provide the release link.

No new broad permissions, system-consent bypass, unverified store-listing claim or silent retry of phone mutations. Website work preserves the incumbent design and changes product copy/download affordances only. Unit fixtures are synthetic; real-device observations are recorded separately.

## Progress

- PR #9 merged after its checks passed; #8 was already on main.
- Integrated tests, final Android signing and physical upgrade, Mac upgrade, two-process MCP queue, existing Chrome grant, wake-lock release, and file/share smoke checks completed. Exact results and limitations are in `docs/release-v0.7.0.md`.
- Website and README updated; final publication and distribution verification remain.
