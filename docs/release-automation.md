# Release distribution

Source validation remains in `ci.yml`. `release-distribution.yml` runs when a GitHub Release is published, or manually against an existing published tag such as `v0.6.0`. It uses the automation on `main`, downloads exactly `phonebridge-VERSION-arm64.apk` from the official release, and never builds, replaces, signs, or uploads an APK.

Before writing public files, the Node script checks the published tag and exact GitHub asset URL, asset size, SHA-256, Android package `dev.phonebridge.phonebridge`, tag-matching versionName, increasing versionCode, ARM64-only native libraries, and the existing preview certificate:

```text
8ce72b7e5687933ea65307b99d3e2b1e41c837a26d18740f9dbc72aeb0bcdbc0
```

`apksigner verify` must exit successfully; printed certificate text alone is insufficient. GitHub's asset digest must match when present. If that digest is absent, supply a trusted `expected_sha256` workflow input. The checked-in manifest hash is an allowed fallback only when its version and APK URL exactly match the requested release. A new release with no GitHub digest and no explicit expected hash fails. Keep the existing preview signing identity for compatible updates; this workflow does not convert debug-signed previews into formally signed production releases.

Only these public text files may be generated and committed:

- `website/dist/update.json`
- `website/dist/index.html`
- `website/dist/en/index.html`
- `README.md`

The script updates all direct official APK links and both illustrated About-version labels. It computes manifest size/hash from the downloaded bytes. APKs and submission kits stay in runner temporary storage; symlinked public paths and artifact outputs inside the checkout are rejected. All metadata checks and text transformations precede public writes. A trigger older than the current manifest cannot roll back the published version. Replacing bytes or versionCode for the same version is rejected; new versions must increase versionCode.

The workflow serializes with `pages.yml` using the `github-pages` concurrency group. It refreshes `main` before generation, commits the explicit text allowlist using `github-actions[bot]`, and pushes without force. A branch-protection or concurrent-push failure stops deployment and remains visible as a failed run. The job requests only repository contents, Pages, and OIDC permissions needed for its commit and deployment. `GITHUB_TOKEN` bot pushes do not start the ordinary push workflow, so this workflow explicitly uploads and deploys Pages after the verified update. An unchanged matching release can redeploy the current website; stale triggers skip deployment.

The preceding Windows job runs `scripts/test-desktop-client.ps1` on trusted `main` and checks optional exact release assets `phonebridge-VERSION-windows-setup.exe` and `phonebridge-VERSION-windows-x64.zip`. Their GitHub SHA-256 and size must match downloaded bytes. The custom installer supports `--diagnose` and `--self-test` without installation; the portable client is extracted after ZIP-path/symlink/expanded-size checks and runs `--diagnose`. A failed Windows check blocks manifest commits and Pages deployment. Desktop metadata joins the submission kit, and existing official desktop download links in both website languages/README are updated when the corresponding asset is present. These Windows companion assets are not submitted to the Android store.

Both Windows `--diagnose` calls write an explicitly selected temporary `--report-path` JSON file. The job requires `product: PhoneBridge`, a version matching the release tag, `platform: windows-x64`, and `dryRun: true`; the ZIP's root `package-manifest.json` must independently match product/version/platform before its launcher runs. Exit code zero alone is insufficient. UTF-8 BOMs from the Windows package manifest/report are accepted. ZIP backslashes normalize explicitly through character codes 92 and 47 before traversal checks.

The Windows job persists its exact `release.json` snapshot as an immutable per-run workflow artifact after successful checks. The publication job downloads that same snapshot, including optional desktop asset absence, names, sizes, and digests, rather than fetching mutable release metadata again. Later metadata edits cannot add unvalidated desktop assets to the submission kit or public links; downloaded APK bytes still must match the original snapshot's digest/size.

Snapshot and submission-kit upload names include both the workflow run ID and run attempt, so reruns do not collide with immutable earlier uploads. The producer exposes its uploaded snapshot `artifact-id` as a job output; publication downloads that exact ID, rather than constructing a name from its own attempt. Rerunning only a failed publication job therefore keeps the successful producer's snapshot while generating a new kit name. Rerunning all jobs produces and consumes a new verified snapshot. Snapshots are retained for seven days; if the original snapshot expires, rerun the producer/all jobs rather than substituting unverified fresh metadata.

## Uptodown handoff

The workflow uploads a 90-day submission-kit artifact with JSON metadata, exact APK URL, SHA-256/size, signing identity, bilingual descriptions, and the existing developer console:

<https://www.uptodown.dev/apps/1000896707>

No documented developer store-upload API was found during the approved release design. No private cookies, guessed API, store upload, or public-listing claim is used. Leave the existing console's official-source editorial tracking enabled. If editorial tracking has not collected the release, use the kit for the console upload/review step. Verify editorial approval and the actual public download/version separately; creating a console record or generating this kit does not establish store availability. F-Droid submission is a separate process.

## Run and verify

Run the local fixture tests with Node.js 22 or later:

```sh
node --test scripts/test/release-distribution.test.mjs
```

After source CI and actual-phone upgrade validation, publish the already signed release or run **Distribute verified release** with its published tag. Inspect every workflow step, the submission kit, and the Pages deployment. Then read the live official `update.json`, check both website APK links and the README against the exact release asset, and verify the live APK's size/hash. A green fixture test or generated manifest proves local validation behavior; publication requires the GitHub run and live checks. Uptodown remains pending until its public listing/version is observed.
