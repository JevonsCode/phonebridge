# 局域网文件传输（预览）

Mac 与安卓手机连接同一可信网络，并在 PhoneBridge 中完成配对后：

1. Mac「连接」页点「选择文件」，选择一张图片或一个文件。
2. 手机首页出现「来自电脑的文件」。点「接收」，等待校验完成。
3. 点「分享」，在系统分享面板选择微信、WhatsApp 或其他支持该文件类型的已安装应用，再选择接收人。

AI 也可使用 `phone_send_file`，参数为用户指定文件的绝对路径，例如 `{"path":"/Users/example/Pictures/photo.png"}`。该工具只发出文件邀请，不选择联系人、不代发消息。更新后需让已打开的 AI 客户端重新连接 MCP，才能发现新工具。

每次一个非空文件，最大 50 MiB。待接收文件在电脑内存保留最多 10 分钟；手机断开连接即取消。手机确认接收后，通过已配对电脑的认证端点下载，校验字节数与 SHA-256，完成后才允许分享。手机最多保留 10 个文件、总计 200 MiB，可点「移除」清理；不会自动保存到相册。接收不要求开启 AI 的「允许操作」。

文件沿用现有配对的局域网传输设置，不经过云端。明文 WS 配对对应明文 HTTP；SHA-256 用于传输完整性校验，不替代 TLS。下载不接受任意 URL、不跟随重定向，分享仅授予目标应用读取所选文件的临时权限。

Mac 显示「等待接收」「正在接收」「已接收」等状态。手机打开分享面板不表示消息已发送，实际结果需在目标应用确认。超时或断线不会自动重发文件。

手机「设置」底部的「操作日志」按时间倒序显示当前电脑最近 100 条操作，以及本机最近 100 条文件事件；离线仍能查看本机文件事件。文件事件注明来源电脑。日志不保存输入文字、截图、文件内容或配对密钥。

## 开发回归

文件分享和 APK 更新必须使用不同的 Provider 组件类。仅仅为同一个 `FileProvider` 类配置两个 authority，并不能保证 Android 创建两个独立组件；生成 URI 成功也不能证明系统能读取它。

`FileProviderManifestTest` 检查组件声明。`FileProviderInstrumentation` 则通过真正的 `ContentResolver` 验证两个 authority 的 MIME、分享 ClipData、文件字节以及目录隔离。它只接受显式确认的 Android 模拟器，在唯一的临时子目录中创建文件，结束时清理这些文件；不应用于个人手机。

在新建的隔离模拟器 `emulator-5580` 上，从 `mobile` 目录执行（已配置 Flutter、Android SDK 和 JDK）：

```sh
flutter build apk --debug --target-platform android-arm64
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebugAndroidTest -PphonebridgeTestRunner=dev.phonebridge.phonebridge.FileProviderInstrumentation
cd ..
adb -s emulator-5580 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5580 install -r build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s emulator-5580 shell am instrument -w -e verifyFileProviders isolated-emulator dev.phonebridge.phonebridge.test/dev.phonebridge.phonebridge.FileProviderInstrumentation
```

成功结果必须包含 `fileProviders=passed`、`authoritiesVerified=2` 和 `INSTRUMENTATION_CODE: -1`；不能仅依赖 adb 的进程退出码。测试 APK 不进入生产包。未指定 Gradle 属性时，仍使用仓库原有的测试 runner。

界面验收还需覆盖：Mac 选择文件、手机确认接收、两端 SHA-256 一致、系统分享预览、在线及离线日志。只打开分享面板，不把测试消息发送给联系人。日志回归包含时间戳的小数精度和 UTC 偏移，按实际时间排序。
