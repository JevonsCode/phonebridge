# In-App Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** About 自动检测、App 内下载并调用 Android 安装，直接发布 APK，真机覆盖升级。

**Architecture:** 固定 GitHub Pages manifest + 原生异步 updater/私有缓存/FileProvider；Flutter 独立更新卡片与 MethodChannel 状态。连接与配对逻辑不变。

**Tech Stack:** Flutter、Kotlin、OkHttp、Android package installer、GitHub Releases/Pages。

### 1. Android updater

- [ ] 在 `mobile/android/app/src/main/kotlin/dev/phonebridge/phonebridge/AppUpdater.kt`、必要的 policy/helper 中实现 spec 原生流程，MainActivity 只路由方法和 lifecycle。
- [ ] 修改 `mobile/android/app/src/main/AndroidManifest.xml`，新建 `res/xml/update_paths.xml`，使用现有 androidx FileProvider（如需依赖则显式添加）。
- [ ] JVM `AppUpdaterTest.kt` / policy tests 使用实际 socket 下载，覆盖可用/当前、版本 code、bad manifest/hash/length/URL、取消和单飞。
- [ ] `mobile/android/gradlew :app:testDebugUnitTest` 全通过，检查资源与 Kotlin 编译。

### 2. Flutter About UI

- [ ] 新建 `mobile/lib/app_updates.dart` 独立 Statefull 更新卡片，遵循 spec channel contract，避免全局 busy，poll 只在 downloading 时。
- [ ] `mobile/lib/main.dart` About 接入卡片，移除硬编码安装版本；`mobile/pubspec.yaml` 改 0.2.4+8。
- [ ] widget 测试自动检查/手动、错误、下载进度、安装一次、取消后重试、dispose；沿用 SurfaceGroup 与 SettingsRow 裁剪。
- [ ] `flutter analyze`、`flutter test` 全通过。

### 3. 集成与发布

- [ ] 实现 spec compliance 与代码质量评审，解决真实问题。
- [ ] 有效 PHONEBRIDGE_NDK_PATH 构建 ARM64 0.2.4 final 和 build-name 0.2.3/build-number 7 bootstrap。分别保存/hash；bootstrap 不发布。
- [ ] 新版 APK 先私有 draft release 上传并校验 digest，然后正式发布，写正确 size/hash/versionCode 的 update.json，官网/README 更新直链，Pages 部署成功后 HTTPS 实读确认。
- [ ] 安装 bootstrap 后用 App 观察升级检查、下载；OS 安装权限/确认交给用户。核对安装后真实版本、APK hash、配对重连与最新状态。修复发现问题，更新真实验证记录。
- [ ] 合并稳定 primary checkout；保留当前桌面登录服务和 pairing；发布源码/最终 APK。报告实际测试范围。
