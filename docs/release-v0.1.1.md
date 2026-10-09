# PhoneBridge v0.1.1 — Developer Preview

首次连接支持扫码配对：电脑运行 `npm start -- --allow-lan --pairing-qr`，手机扫描本机配对页面即可填写地址与密钥。扫码不会自动授权，连接与操作仍由机主确认。

局域网模式下，截图、读取控件、点击和输入均通过 PhoneBridge App，无需 ADB 控制或 USB 调试安全设置。相机仅用于配对扫码。配对页面五分钟后隐藏二维码，但会话密钥持续有效，直到 Hub 停止或更换密钥。

这是 Android 11+ 自用开发者预览，APK 使用 debug 签名。无障碍需要机主手动开启；不绕过锁屏、受保护窗口和系统授权。手机界面只传给配对的 Hub。此版本不内置模型或云服务。

下载 `phonebridge-v0.1.1-arm64-preview-debug.zip`，解压后安装其中的 APK。压缩包包含 ARM64 APK 与 SHA256 校验值，APK 与本次真机安装文件相同。其他 CPU 架构可按 README 自行构建。

验证范围和已知限制见仓库 `docs/verification.md`。请勿把个人屏幕、聊天、配对二维码或密钥上传到 issue。
