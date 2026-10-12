# PhoneBridge 0.6.1 — Mac client, file transfer and activity timeline

## Changes

- A bundled Flutter desktop client for macOS 13+ (Apple Silicon and Intel), with pairing, network selection and MCP configuration. Windows uses the same desktop interface. The Mac login service keeps running when the window closes.
- Send a local file from the Mac window or the `phone_send_file` MCP tool. Receive it explicitly on Android, then open the system share sheet to choose a supported app such as WeChat or WhatsApp. One non-empty file at a time, up to 50 MiB; invitations expire after 10 minutes. Receipt checks file size and SHA-256. Opening the share sheet is not confirmation that a message was sent.
- Android's home screen now has a visible **Scan / 扫一扫** entry. Saved computer cards show a switch hint, each computer has its own delete confirmation, and cancelling a rename keeps the computer list open.
- **Settings → Operation log** shows a chronological timeline of computer operations and local file events, newest first. Local file events remain visible offline. Mixed timestamp precision and time-zone offsets sort by actual time.
- Mac upgrades retain pairing identity, wait for the previous launchd job to exit, and detect changed runtime files at the same installation path. File endpoints now pass through the installed background supervisor.
- File sharing uses a separate Android Provider component from APK updates, preserving each component's directory restrictions.

## 中文

新增自带运行环境的 Mac 客户端；Mac 界面和 AI 都可发送局域网文件。手机确认接收并校验后，可从系统分享面板选择微信、WhatsApp 等应用。扫一扫移到首页，电脑切换、改名和删除更清楚；设置底部新增按时间排列的操作日志，断线仍可查看本机文件记录。修复 Mac 后台升级、文件路由、安卓分享组件冲突及日志排序问题。

## Upgrade and validation

This remains a developer preview. Android releases must retain the existing preview certificate for an in-place update. Do not uninstall the old app to work around a signature mismatch. Mac packages are ad-hoc signed and not Developer ID notarized; Windows packages are unsigned.

Source tests cover bridge authentication, bounded transfer and disconnect handling, desktop lifecycle, Android metadata and hash validation, UI interactions and log ordering. An isolated Android API 36.1 emulator verifies both file-provider authorities through the real system ContentResolver and tests their directory isolation.

On the existing Xiaomi phone, file receipt and SHA-256 verification passed before the share-provider repair. The repaired local test build passed Mac-window sending, Android receipt, system image-sharing preview, and online/offline logs on an isolated emulator. A repaired original-signed physical-phone upgrade is a remaining release check while that signing key and USB device are unavailable. No messages to real contacts were sent in these transfer tests.

GitHub Actions builds and checks macOS arm64/x64 and Windows packages. CI packages do not establish physical-device compatibility, macOS reboot/login behavior, or app-store approval. See [file transfer](file-transfer.md), [Mac testing](macos-testing.md) and [release distribution](release-automation.md).
