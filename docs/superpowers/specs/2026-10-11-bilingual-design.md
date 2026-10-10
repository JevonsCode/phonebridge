# PhoneBridge bilingual experience

The owner approved this design: keep the existing website and App visual style, add complete Chinese/English experiences, detect language on first entry, permit an explicit persistent choice, synchronize the website phone illustration, publish on GitHub Pages and upgrade the connected phone.

## Website

Use two static pages, Chinese at `/phonebridge/` and English at `/phonebridge/en/`, sharing styles and scripts. This keeps both pages readable without JavaScript and gives each language a stable link. A single-page dictionary would avoid duplicate markup but require JavaScript for English; a translation service adds unnecessary dependencies. Static pages are selected.

At the Chinese entry page, before rendering, select a saved manual preference or the browser's first preferred language: `zh` variants use Chinese, all other languages use English. The English URL is an explicit English entry and does not auto-redirect. Header links labelled 中文 and English work without JavaScript; when JavaScript is available their clicks persist the choice. Storage failures never block navigation. Keep hash fragments across automatic redirects, avoid loops and use paths relative to the deployed `/phonebridge/` base. Update page language, titles, descriptions, accessibility labels and alternate/canonical metadata.

Translate all marketing, installation, FAQ, illustration and copy-command feedback text naturally. The phone illustration must match the current App's rounded surfaces, connection state, actions, persistent authorization and navigation. Add a compact representation of its current About update card so the new update capability is accurately shown. Both languages retain the same v0.2.5 direct APK link; the update manifest and original GPT-hosted redirect retain their existing contracts. Mobile and desktop layouts must accommodate English text without overflow.

## Android App

Default to the Android system language: Chinese for `zh`, English otherwise. A settings row opens a simple selection for Follow system / 中文 / English. Persist only the language preference; changing language updates visible UI immediately and must never pause, reconfigure or revoke the existing phone session. Android preferences are the persistence mechanism; the Flutter control channel exposes a small language get/set contract. Use Flutter localization delegates for built-in widgets.

Translate all shipped screens: connection state, saved computer, recovery, settings, consent/manual pairing/scanner/help, About and update lifecycle states/errors. Keep machine protocol codes and internal logs unchanged; map user-facing native bridge/updater errors into selected-language messages. Use Android localized resources for app-owned notification and other native visible text. Android's installer/permission settings remain controlled by the system language. Do not ship or add the old test playground to production navigation.

## Verification and publication

Meaningful tests cover system language fallback, manual selection and persistence, retained connection/action state during language changes, translated update errors, and small-screen English layouts. Browser checks cover fresh English and Chinese entry, manual switch and remembered choice, unavailable storage and direct English entry, copy feedback, links, and both languages at mobile and desktop widths.

Build v0.2.5 with the existing signature and official manifest URL. Upgrade the physical Android 16 phone through the existing App updater if practical, otherwise use an owner-authorized ADB update; no ADB UI gestures. Verify installed version/hash, original pairing and action consent, both languages, and official About checks. Publish only after these checks, using GitHub Releases and GitHub Pages. The current preview remains debug signed; do not claim other devices or recipient actions were tested.

Delete the README tagline `个人自用优先 · MIT 开源 · Android 11+ · Flutter + Kotlin · MCP` as requested. Keep factual installation and technical details where they help users.
