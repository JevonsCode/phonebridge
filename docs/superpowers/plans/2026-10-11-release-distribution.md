# Release distribution automation

User authorized autonomous implementation and public release updates on 2026-10-11.

## Design

Use the existing GitHub CI for source validation. On a published GitHub Release, verify the already-signed ARM64 APK, package/version/certificate and digest, generate the official update manifest, and update both website download URLs and README. Deploy the resulting website through GitHub Pages. The workflow does not replace a verified release APK or change its signing identity.

Obtainium tracks the official GitHub source with previews enabled. The website offers the direct APK, GitHub Releases and Obtainium. Uptodown is labelled pending until its public listing is verified.

Current official Uptodown documentation describes console uploads and editorial tracking of official sources; no documented developer upload API was found. Retain editorial-source updates in the console. Generate a per-release submission kit and workflow summary with the exact APK URL/hash/metadata and existing developer-console link; do not fake an automated store upload or use private browser cookies in CI. F-Droid submission prerequisites remain separate.

## Implementation

- Node script to validate release metadata and verified APK inputs, generate manifest and synchronize public links. Unit tests cover bad versions, wrong package/signer, hashes, stale release handling and bilingual URL updates.
- Release-published/manual workflow downloads the exact release asset, checks it with Android build tools, runs script tests, uploads submission kit, updates public tracked files and deploys Pages. Explicit concurrency and least required permissions. Do not print tokens or commit binaries/keys.
- Preserve website layout, add bilingual download-channel links and accurate status, test mobile overflow and link targets.
- Run workflow on the verified v0.2.6 release after actual phone validation; inspect GitHub logs, deployed manifest and public asset links before completion.
