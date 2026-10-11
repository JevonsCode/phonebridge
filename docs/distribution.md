# Distribution status

Checked against official documentation on 2026-10-11. Public availability is recorded separately from a submitted request or prepared metadata.

| Channel | Current status | Next step |
|---|---|---|
| GitHub Releases | v0.6.0 published with direct ARM64 APK, Windows installer and portable ZIP | Continue verified releases with the existing preview signer |
| Obtainium direct source | Official-source configuration prepared; it requires no directory listing | Import the configuration or use the README link; physical Obtainium import is not yet tested |
| Obtainium directory | Not eligible yet: repository created 2026-10-09, with 0 stars at this check | Its current criteria require 4 months and 35 stars for GitHub sources |
| GitHub-based store discovery | Public repository description/topics updated | Some clients only show stable releases; current releases remain explicitly previews |
| F-Droid main repository | Text metadata, project icon and [packaging request draft](fdroid-packaging-request.md) prepared; not submitted or listed | Provide screenshots, validate a release build recipe, adapt the updater's distribution notice/variant, and sign in to GitLab for submission |
| Uptodown | v0.6.0 APK (versionCode 2011), icon, website, Chinese/English descriptions and three real App screenshots submitted successfully; console status is Pending revision | Wait for editorial approval; submission and pending review do not establish a public listing |
| IzzyOnDroid | Not a suitable submission target | Current policy rejects generative-AI-produced App code; this project is AI-assisted. Other blockers include the debug preview binary and its size |
| Aptoide Connect | Not used for this free distribution task | Manual submissions for apps not on Google Play require a subscription under its current FAQ |

F-Droid normally builds from public source and signs with its own App key unless reproducible developer-signed builds are arranged. That means its APK would not automatically replace the current debug-signed preview while preserving data. Never ask users to uninstall an existing installation merely to bypass a signature mismatch.

Prepared Fastlane text metadata under `fastlane/metadata/android/` is not a statement that any market has accepted the App. Never mark it as listed until the public listing is actually verified.

The v0.6.0 release-distribution run [38097431823](https://github.com/JevonsCode/phonebridge/actions/runs/38097431823) passed Windows package diagnostics, Android APK identity/hash/signature checks, public update-manifest synchronization and GitHub Pages deployment. Future published releases dispatch this workflow on main. It generates an Uptodown submission kit; it does not call an invented store upload API or claim automatic editorial approval. This version's Uptodown submission was completed in the developer console.

Official references:

- [F-Droid submission guide](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/), [inclusion policy](https://f-droid.org/en/docs/Inclusion_Policy/), [signing FAQ](https://f-droid.org/en/docs/FAQ_-_App_Developers/#what-about-signing)
- [Obtainium directory criteria](https://github.com/ImranR98/apps.obtainium.imranr.dev/blob/main/APP_CRITERIA.md), [direct links](https://wiki.obtainium.imranr.dev/deep_links/)
- [GitHub Store](https://github.com/OpenHub-Store/GitHub-Store), [RepoStore requirements](https://repostore.in/docs.html)
- [Uptodown free publishing](https://en.uptodown.com/developers-console)
- [IzzyOnDroid inclusion and AI policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/)
- [Aptoide fees](https://docs.connect.aptoide.com/docs/app-submission-faqs)
