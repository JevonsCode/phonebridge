# PhoneBridge 应用内更新

用户已确认：进入关于自动检查版本，保留手动检查；App 内下载 APK，打开系统安装界面，保留配对和授权。直接 APK 发布已完成。本次新增流程不再重复请求设计授权。

## 体验

现有设置中的「关于」增加更新卡片，沿用 SurfaceGroup 圆角与点击裁剪。进入时检查一次，显示安装版本、最新版本、检查更新、下载 APK（有更新时为下载更新）。下载显示进度，完成后只打开一次系统安装界面；取消后可再次安装。失败显示可重试信息，离开页面或取消安装不能触发循环弹窗。更新状态与连接状态分开，下载不阻止暂停手机控制。

## 发布与协议

GitHub Pages `/phonebridge/update.json` 提供 `schema:1,versionName,versionCode,apkUrl,sha256,size,notes`，版本 code 使用实际 ARM64 分包值。最终版 0.2.4+8 对应 ARM64 2008。GitHub Releases 直接发布 APK，官网/README 直链同步。此版本包括 preview，不使用忽略预览版的 GitHub latest API。

Android 同一 control MethodChannel 新增无参数 `checkUpdate`（异步检查后返回状态）、`getUpdateStatus`、`downloadUpdate`（开始后立即返回）、`installUpdate`。状态包含 `phase`（idle/checking/current/available/downloading/ready/permissionRequired/installerOpened/error）、`currentVersion,currentVersionCode,versionName,versionCode,updateAvailable,downloadedBytes,totalBytes,progress,errorMessage`。初次 getUpdateStatus 返回当前真实 package 版本；UI 不使用硬编码的安装版本。checkUpdate 失败保留可重试 UI，不能把网络错误显示为最新。

实现评审补充：`dev.phonebridge/updates` EventChannel 在订阅时立即发送当前状态，并发送后续阶段与终态变化。重新进入 About 时保留已有 checking 并订阅结果，不重复调用 checkUpdate，也不增加下载之外的周期 polling。installUpdate 异步返回安装准备/启动的终态；校验失败或系统界面启动失败必须通过结果/事件显示错误，即使没有系统 pause/resume。取消 UI 订阅不取消原生操作，activity/engine cleanup 清理订阅及未完成回调。

原生 updater 只使用固定官方 HTTPS manifest，不向互联网发送配对 token。解析有界 manifest；仅接受官方仓库 APK URL。APK 流式下载到私有 cache/updates 临时文件，验证长度、SHA256、同包名、manifest 版本 code、与当前签名一致，再原子替换可安装文件。部分文件不安装。网络、磁盘或关闭 activity 失败可重试并清理临时文件；不修改配对存储。避免并发检查/下载竞态和 stale callback。缓存完成文件可重新使用，但安装前再次确认文件与当前元数据匹配。

FileProvider 仅暴露 updates cache 子目录，exported=false；通过只读 URI grant 打开系统安装器。声明 REQUEST_INSTALL_PACKAGES。第一次缺少允许来源安装时打开该应用的系统设置；返回授权后继续安装一次，未授权时留在可操作状态。系统安装确认由机主完成，不静默安装、不用无障碍代点确认。

原生层拥有下载完成后的自动安装意图：downloadUpdate 用户点击时创建一次 pending intent；完成验证后仅在 activity resumed 时启动安装，否则等其恢复。启动系统安装器之前先消费 pending；权限设置返回时复核允许来源，并消费一次 pending 再启动安装器。拒绝权限保留 permissionRequired，但不再自动打开设置。安装器返回而当前版本未变化时为 ready，必须手动 installUpdate 再试；Flutter 不自动调用 installUpdate，只显示状态/明确重试按钮。用真实 pause/resume 或结果回调区分安装器返回，不能把 launch 同一帧的 resume 当取消。activity 重建不恢复自动安装意图，最多重新确认缓存为 ready；状态在 Flutter resume 时刷新。

离开 About 保持下载，activity Destroy/engine cleanup 则取消请求、删除 partial、清空 pending，未完成 checkUpdate 结果只完成一次 ACTIVITY_CLOSED。checkUpdate 检查中/下载中拒绝重叠启动（BUSY），downloadUpdate 在检查中/下载中也拒绝；getUpdateStatus 总可读。下载使用开始时不可变 manifest snapshot，直到完成都不能被后来的检查替换。错误保留缓存已验证文件的独立身份，但不得安装任何 partial。关于组件 dispose 停止 polling/回调，不能影响手机连接。

## 验证

JVM 真实 HTTP fixture 验证 manifest、版本 code、错误、下载流/哈希/长度/取消；widget 验证自动/手动检查、最新/新版/错误、进度、一次安装和重试。运行 analyze、Flutter tests、native tests、ARM64 build。发布前读 apk package/signature metadata。

真机 E2E：先安装具有 updater 的 0.2.3+7 bootstrap（仅本地测试，不发布），保留原配对。bootstrap 构建时才设置 `PHONEBRIDGE_TEST_UPDATE_MANIFEST` 指向同一 LAN 的临时 manifest/APK fixture，APK 为最终 0.2.4 文件。测试构建只允许此私有 HTTP origin；最终 APK 与 release 构建始终使用官方 HTTPS 来源（最终 debug 构建不设置测试环境变量）。Manifest 包/hash/code/签名验证完全相同，测试入口不由 MethodChannel/Intent/用户配置开放。

通过 App 控制观察 About 检测新版本与实际下载；系统来源授权/安装确认需要用户操作。安装后核对 0.2.4/2008、原配对自动重连并回读已安装 APK hash。该链路通过后才公开发布最终 APK/官方 manifest，实读官方 manifest 并在最终 App 看到已最新。只有此链路成功才声称 App 内升级已实测；无法完成时准确报告边界。
