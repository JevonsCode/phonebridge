# PhoneBridge 应用内更新

用户已确认：进入关于自动检查版本，保留手动检查；App 内下载 APK，打开系统安装界面，保留配对和授权。直接 APK 发布已完成。本次新增流程不再重复请求设计授权。

## 体验

现有设置中的「关于」增加更新卡片，沿用 SurfaceGroup 圆角与点击裁剪。进入时检查一次，显示安装版本、最新版本、检查更新、下载 APK（有更新时为下载更新）。下载显示进度，完成后只打开一次系统安装界面；取消后可再次安装。失败显示可重试信息，离开页面或取消安装不能触发循环弹窗。更新状态与连接状态分开，下载不阻止暂停手机控制。

## 发布与协议

GitHub Pages `/phonebridge/update.json` 提供 `schema:1,versionName,versionCode,apkUrl,sha256,size,notes`，版本 code 使用实际 ARM64 分包值。最终版 0.2.4+8 对应 ARM64 2008。GitHub Releases 直接发布 APK，官网/README 直链同步。此版本包括 preview，不使用忽略预览版的 GitHub latest API。

Android 同一 control MethodChannel 新增无参数 `checkUpdate`（异步检查后返回状态）、`getUpdateStatus`、`downloadUpdate`（开始后立即返回）、`installUpdate`。状态包含 `phase`（idle/checking/current/available/downloading/ready/permissionRequired/installerOpened/error）、`currentVersion,currentVersionCode,versionName,versionCode,updateAvailable,downloadedBytes,totalBytes,progress,errorMessage`。初次 getUpdateStatus 返回当前真实 package 版本；UI 不使用硬编码的安装版本。checkUpdate 失败保留可重试 UI，不能把网络错误显示为最新。

原生 updater 只使用固定官方 HTTPS manifest，不向互联网发送配对 token。解析有界 manifest；仅接受官方仓库 APK URL。APK 流式下载到私有 cache/updates 临时文件，验证长度、SHA256、同包名、manifest 版本 code、与当前签名一致，再原子替换可安装文件。部分文件不安装。网络、磁盘或关闭 activity 失败可重试并清理临时文件；不修改配对存储。避免并发检查/下载竞态和 stale callback。缓存完成文件可重新使用，但安装前再次确认文件与当前元数据匹配。

FileProvider 仅暴露 updates cache 子目录，exported=false；通过只读 URI grant 打开系统安装器。声明 REQUEST_INSTALL_PACKAGES。第一次缺少允许来源安装时打开该应用的系统设置；返回授权后继续安装一次，未授权时留在可操作状态。系统安装确认由机主完成，不静默安装、不用无障碍代点确认。

## 验证

JVM 真实 HTTP fixture 验证 manifest、版本 code、错误、下载流/哈希/长度/取消；widget 验证自动/手动检查、最新/新版/错误、进度、一次安装和重试。运行 analyze、Flutter tests、native tests、ARM64 build。发布前读 apk package/signature metadata。

真机 E2E：先安装具有 updater 的 0.2.3+7 bootstrap（仅本地测试，不发布），保留原配对；官方 manifest 指向最终 0.2.4 APK。通过 App 控制观察 About 检测新版本与实际下载；系统来源授权/安装确认需要用户操作。安装后核对 0.2.4/2008、已最新、原配对自动重连，并回读已安装 APK hash。只有此链路成功才声称 App 内升级已实测；无法完成时准确报告边界。
