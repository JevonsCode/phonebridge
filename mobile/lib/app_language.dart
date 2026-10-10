import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Owns only display language. The connection page remains the same child.
class AppLanguage extends StatefulWidget {
  const AppLanguage({required this.builder, super.key});
  final Widget Function(BuildContext, Locale) builder;

  static AppLanguageState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LanguageScope>()?.owner;

  static Locale resolve(String preference, Locale system) => Locale(
    preference == 'system'
        ? (system.languageCode == 'zh' ? 'zh' : 'en')
        : preference,
  );

  @override
  State<AppLanguage> createState() => AppLanguageState();
}

class AppLanguageState extends State<AppLanguage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('dev.phonebridge/control');
  String preference = 'system';
  bool saving = false;
  int _revision = 0;
  Locale get locale => AppLanguage.resolve(
    preference,
    WidgetsBinding.instance.platformDispatcher.locale,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final value = await _channel.invokeMethod<String>(
        'getLanguagePreference',
      );
      if (mounted &&
          revision == _revision &&
          {'system', 'zh', 'en'}.contains(value)) {
        setState(() => preference = value!);
      }
    } on MissingPluginException {
      // Flutter-only hosts follow their system language without persistence.
    } on PlatformException {
      // A failed preference read never interferes with connection initialization.
    }
  }

  Future<void> select(String value) async {
    if (saving || !{'system', 'zh', 'en'}.contains(value)) return;
    _revision++;
    setState(() => saving = true);
    try {
      await _channel.invokeMethod<void>('setLanguagePreference', {
        'language': value,
      });
      if (mounted) setState(() => preference = value);
    } on MissingPluginException {
      if (mounted) setState(() => preference = value);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted && preference == 'system') setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LanguageScope(
    owner: this,
    language: locale.languageCode,
    preference: preference,
    child: Builder(builder: (context) => widget.builder(context, locale)),
  );
}

class _LanguageScope extends InheritedWidget {
  const _LanguageScope({
    required this.owner,
    required this.language,
    required this.preference,
    required super.child,
  });
  final AppLanguageState owner;
  final String language, preference;
  @override
  bool updateShouldNotify(_LanguageScope oldWidget) =>
      language != oldWidget.language || preference != oldWidget.preference;
}

/// Chinese copy is the stable translation key; protocol/log text is unchanged.
String tr(BuildContext context, String text) {
  final language =
      AppLanguage.of(context)?.locale.languageCode ??
      (Localizations.maybeLocaleOf(context)?.languageCode == 'zh'
          ? 'zh'
          : 'en');
  if (language == 'zh') return _chineseNative[text] ?? text;
  return _english[text] ?? text;
}

/// Do not expose untranslated platform exceptions or transport diagnostics.
String userError(String? code, String? message, String fallback) =>
    _errors[code] ??
    (_english.containsKey(message) || _chineseNative.containsKey(message)
        ? message!
        : fallback);

const _errors = <String, String>{
  'ACCESSIBILITY_DISABLED': '请先开启 PhoneBridge 无障碍服务',
  'DEVICE_LOCKED': '请先解锁手机，再继续',
  'NOTIFICATIONS_DISABLED': '请允许 PhoneBridge 的连接通知后再试',
  'NO_SAVED_PAIRING': '请先与电脑配对',
  'DESKTOP_UNREACHABLE': '无法联系电脑，请确认电脑已开机并连接同一网络',
  'DESKTOP_AUTH_FAILED': '电脑拒绝了配对身份，请检查电脑端配对设置',
  'DESKTOP_UPDATE_REQUIRED': '电脑端尚不支持一键启动，请更新并安装电脑端后台服务',
  'DESKTOP_START_FAILED': '电脑服务启动失败，请检查电脑端后台服务',
  'RECOVERY_CANCELLED': '连接状态已改变，启动请求已取消，请重新确认后操作',
  'ACTIVITY_CLOSED': '界面已关闭，请重新打开 PhoneBridge',
  'BUSY': '操作正在进行，请稍候',
  'NO_SESSION': '连接已结束，请先连接电脑',
  'READ_ONLY': '请在手机上开启允许操作',
  'INVALID_ARGUMENT': '连接设置无效，请检查后重试',
  'PAIRING_STORAGE_FAILED': '无法安全保存配对，请重新配对',
  'UPDATE_CHECK_FAILED': '无法检查版本，请检查网络后重试',
  'INVALID_MANIFEST': '版本信息无效，请稍后重试',
  'UPDATE_DOWNLOAD_FAILED': '下载失败，请检查网络或存储后重试',
  'APK_LENGTH_MISMATCH': 'APK 下载不完整，请重新下载',
  'APK_HASH_MISMATCH': 'APK 校验失败，请重新下载',
  'APK_PACKAGE_MISMATCH': 'APK 的应用或版本不符，请重新下载',
  'APK_SIGNATURE_MISMATCH': 'APK 签名不符，无法安装',
  'UPDATE_REDIRECT_REJECTED': '更新服务跳转到不可信来源',
  'UPDATE_NOT_CHECKED': '请先检查版本',
  'UPDATE_NOT_READY': '请先下载 APK',
  'UPDATE_INSTALL_FAILED': '无法打开系统安装界面，请重试',
};

const _english = <String, String>{
  '请先解锁手机，再继续': 'Unlock your phone to continue',
  '无法连接更新服务器': 'Could not connect to the update server',
  '检查失败，请重试': 'Check failed. Retry.',
  '无法打开系统安装界面': 'Could not open the system installer',
  '无法联系电脑，请确认电脑已开机并连接同一网络':
      'Cannot reach your computer. Check that it is on and on the same network.',
  '电脑拒绝了配对身份，请检查电脑端配对设置':
      'Your computer rejected this pairing. Check its pairing settings.',
  '电脑端尚不支持一键启动，请更新并安装电脑端后台服务':
      'Update and install the computer background service to enable remote start.',
  '连接状态已改变，启动请求已取消，请重新确认后操作':
      'Connection state changed. The start request was cancelled. Check and try again.',
  '界面已关闭，请重新打开 PhoneBridge': 'This screen closed. Reopen PhoneBridge.',
  '操作正在进行，请稍候': 'An operation is in progress. Please wait.',
  '连接已结束，请先连接电脑': 'The session ended. Connect to your computer first.',
  '请在手机上开启允许操作': 'Enable Allow actions on your phone.',
  '连接设置无效，请检查后重试': 'Invalid connection settings. Check and retry.',
  '无法安全保存配对，请重新配对': 'Could not safely save pairing. Pair again.',
  '无法检查版本，请检查网络后重试':
      'Could not check for updates. Check your network and retry.',
  '版本信息无效，请稍后重试': 'Invalid release information. Try again later.',
  '下载失败，请检查网络或存储后重试':
      'Download failed. Check your network or storage and retry.',
  'APK 下载不完整，请重新下载': 'The APK download is incomplete. Download again.',
  'APK 校验失败，请重新下载': 'APK verification failed. Download again.',
  'APK 的应用或版本不符，请重新下载':
      'The APK app or version does not match. Download again.',
  'APK 签名不符，无法安装': 'The APK signature does not match. Installation is blocked.',
  '更新服务跳转到不可信来源': 'The update service redirected to an untrusted source.',
  '请先检查版本': 'Check for updates first.',
  '请先下载 APK': 'Download the APK first.',
  '无法打开系统安装界面，请重试': 'Could not open the system installer. Retry.',
  '返回': 'Back',
  '帮助': 'Help',
  '设置': 'Settings',
  '连接': 'Connection',
  '暂停连接': 'Pause connection',
  '连接电脑': 'Connect computer',
  '连接，一次就好': 'Pair once. Stay connected.',
  '首次扫描电脑端的配对码。记住电脑后，更新 App 或网络恢复时会自动重连。\n\n保持手机解锁，电脑端服务运行即可。你可以随时暂停连接。':
      'Scan the pairing code on your computer the first time. Once saved, PhoneBridge reconnects after app updates or network recovery.\n\nKeep your phone unlocked and the computer service running. You can pause the connection at any time.',
  '你的电脑': 'Your computer',
  '已连接': 'Connected',
  '正在连接': 'Connecting',
  '连接已暂停': 'Connection paused',
  '连接你的电脑': 'Connect your computer',
  '手机已与这台电脑连接': 'Your phone is connected to this computer',
  '正在等待电脑，连接会自动恢复':
      'Waiting for your computer. Connection resumes automatically.',
  '电脑已记住，随时可以继续': 'Computer saved. Resume whenever you like.',
  '连接电脑，让 AI 帮你处理手机上的事':
      'Connect your computer so AI can help with tasks on your phone',
  '我的电脑': 'My computer',
  '已记住': 'Saved',
  '允许操作': 'Allow actions',
  '操作授权已保留，重连后恢复': 'Action permission saved. Restored on reconnect.',
  'AI 可以点击、滑动和输入': 'AI can tap, swipe and type',
  '关闭时，AI 只能查看界面': 'When off, AI can only view the screen',
  '继续连接': 'Resume connection',
  '正在启动电脑服务…': 'Starting computer service…',
  '启动电脑服务': 'Start computer service',
  '开启无障碍服务以继续': 'Enable accessibility to continue',
  '配对与授权已保留 · 随时可以暂停': 'Pairing & permissions saved · Pause any time',
  '仅限本次连接 · 随时可以暂停': 'This session only · Pause any time',
  '只连接你信任的电脑': 'Only connect to a computer you trust',
  '连接与权限': 'Connection & permissions',
  '无障碍服务': 'Accessibility service',
  '已开启': 'Enabled',
  '尚未开启': 'Not enabled',
  '已记住的电脑': 'Saved computer',
  '尚未配对': 'Not paired',
  '关于': 'About',
  '查看源码、下载与反馈': 'Source code, downloads and feedback',
  '官方网站': 'Official website',
  '了解 PhoneBridge 与安装方法': 'About PhoneBridge and installation',
  '隐私与数据': 'Privacy & data',
  '了解界面内容如何传输': 'How screen content is shared',
  'PhoneBridge 将允许应用的界面内容发送给配对电脑，不建立云端、不收集遥测、不保存聊天记录。\n\n连接的 AI 可能将内容发送给其模型服务商，请查看该客户端的数据设置。截图可能包含个人信息。\n\n手机会加密保存配对与授权。忘记电脑后，保存的授权会被删除。':
      'PhoneBridge sends screen content from allowed apps to your paired computer. It has no cloud service, collects no telemetry and stores no chat history.\n\nYour AI client may send content to its model provider. Check that client\'s data settings. Screenshots may contain personal information.\n\nPairing and permissions are encrypted on your phone. Forgetting a computer deletes its saved permissions.',
  '开源许可': 'Open source licenses',
  '连接信息和你的授权已加密保存在手机中。更新 App 或网络恢复后，无需重新扫码。':
      'Your connection details and permissions are encrypted on your phone. There is no need to scan again after app updates or network recovery.',
  '忘记这台电脑': 'Forget this computer',
  '只需配对一次': 'Pair just once',
  '扫描电脑端的二维码。之后的连接，交给 PhoneBridge。':
      'Scan the QR code on your computer. PhoneBridge handles future connections.',
  '先开启无障碍服务': 'Enable accessibility first',
  '用于读取界面和执行操作': 'Used to read the screen and perform actions',
  '扫描电脑配对码': 'Scan computer pairing code',
  '收起手动设置': 'Hide manual setup',
  '手动输入连接信息': 'Enter connection details manually',
  '已识别电脑': 'Computer recognized',
  '核对电脑地址后，确认以下连接选项。':
      'Check the computer address, then confirm the options below.',
  '设备连接地址': 'Device connection address',
  '配对密钥': 'Pairing key',
  '允许访问的应用包名': 'Allowed app package names',
  '每行一个；默认此应用和微信': 'One per line; this app and WeChat by default',
  '使用可信本地网络': 'Use a trusted local network',
  '允许本地明文连接；同一网络内的其他人可能看到传输内容。':
      'Allows unencrypted local connections. Others on the network may see shared content.',
  '允许共享应用界面': 'Allow sharing app screens',
  '内容发送给配对电脑；AI 客户端可能转发给模型服务商。':
      'Content is sent to your paired computer. Your AI client may forward it to its model provider.',
  '记住电脑与授权': 'Remember computer & permissions',
  '更新或网络恢复后，自动连接。':
      'Reconnect automatically after updates or network recovery.',
  '正在连接…': 'Connecting…',
  '确认连接': 'Confirm connection',
  '首次连接为只读，操作开关由你开启。':
      'The first connection is read only. You enable actions yourself.',
  '无法读取连接状态': 'Could not read connection status',
  '控制服务仅在 Android 11 或更新版本上可用': 'Control service requires Android 11 or later',
  '操作失败，请检查手机状态': 'Action failed. Check your phone and try again.',
  '请在安卓设备上打开 PhoneBridge': 'Open PhoneBridge on an Android device',
  '请输入电脑端生成的完整配对密钥（32–256 个字母、数字、- 或 _）':
      'Enter the complete pairing key generated by your computer (32–256 letters, digits, - or _)',
  '请先开启 PhoneBridge 无障碍服务':
      'Enable the PhoneBridge accessibility service first',
  '请先解锁手机，再启动电脑服务': 'Unlock your phone before starting the computer service',
  '请允许 PhoneBridge 的连接通知后再试':
      'Allow PhoneBridge connection notifications and try again',
  '请先与电脑配对': 'Pair with your computer first',
  '电脑服务启动失败，请检查电脑端后台服务':
      'Could not start the computer service. Check its background service.',
  '请更新安卓端 PhoneBridge 后再试': 'Update PhoneBridge on Android and try again',
  '请先停止当前连接，再扫描新的配对码。':
      'Pause the current connection before scanning a new pairing code.',
  '扫描电脑端配对码': 'Scan computer pairing code',
  '对准电脑上 PhoneBridge 显示的二维码。扫码只填写连接信息，之后仍需你确认并连接。\n相机画面不会上传或保存。':
      'Point at the QR code shown by PhoneBridge on your computer. Scanning only fills in connection details; you still confirm and connect.\nCamera images are never uploaded or saved.',
  '暂时无法识别，请调整距离后重试。':
      'Could not read the code. Adjust the distance and try again.',
  '请勿扫描陌生人提供的配对码。返回后核对电脑地址。':
      'Do not scan pairing codes from strangers. Check the computer address after returning.',
  '这不是有效的 PhoneBridge 配对二维码，请重新打开电脑端配对页面。':
      'This is not a valid PhoneBridge pairing code. Reopen the pairing page on your computer.',
  '需要相机权限才能扫码': 'Camera permission is needed to scan',
  '相机暂时不可用': 'Camera unavailable',
  '请在手机系统设置中允许 PhoneBridge 使用相机，再返回重试。也可以返回手动填写连接信息。':
      'Allow PhoneBridge camera access in system settings, then return and retry. You can also enter connection details manually.',
  '请关闭正在使用相机的其他应用后重试，或返回手动填写连接信息。':
      'Close other apps using the camera and retry, or enter connection details manually.',
  '重试': 'Retry',
  '返回手动填写': 'Back to manual setup',
  '手机与电脑已连接': 'Phone connected to computer',
  '手机等待连接电脑': 'Phone waiting to connect to computer',
  '无法接收更新状态，请重试': 'Could not receive update status. Retry.',
  '无法读取更新状态，请重试': 'Could not read update status. Retry.',
  '应用更新仅在 Android 上可用': 'App updates are available on Android',
  '更新操作失败，请重试': 'Update action failed. Retry.',
  '正在检查更新…': 'Checking for updates…',
  '正在开始下载…': 'Starting download…',
  '正在打开系统安装界面…': 'Opening system installer…',
  '已是最新版本': 'You\'re up to date',
  '新版本已就绪，下载后按提示安装':
      'A new version is available. Download it and follow the installation prompts.',
  '正在下载，可继续使用手机控制': 'Downloading. Phone control remains available.',
  'APK 已下载，点击安装继续': 'APK downloaded. Tap Install to continue.',
  '请允许 PhoneBridge 安装应用，然后继续安装':
      'Allow PhoneBridge to install apps, then continue.',
  '请在系统安装界面确认；取消后可再次安装':
      'Confirm in the system installer. You can install again if cancelled.',
  '更新失败，请重试': 'Update failed. Retry.',
  '检查新版本或下载最新 APK': 'Check for updates or download the latest APK',
  '应用更新': 'App updates',
  '正在读取安装版本…': 'Reading installed version…',
  '当前版本': 'Current version',
  '最新版本': 'Latest version',
  '已下载': 'Downloaded',
  '重试检查': 'Retry check',
  '检查更新': 'Check updates',
  '允许并安装': 'Allow & install',
  '安装更新': 'Install update',
  '正在下载…': 'Downloading…',
  '重试下载': 'Retry download',
  '下载更新': 'Download update',
  '下载 APK': 'Download APK',
  '语言': 'Language',
  '跟随系统': 'Follow system',
  '无法保存语言设置，请重试': 'Could not save language preference. Retry.',
};
const _chineseNative = <String, String>{
  'Accessibility was interrupted.': '无障碍服务已中断，正在尝试恢复连接',
  'Could not safely save pairing. Please pair again.': '无法安全保存配对，请重新配对',
  'PhoneBridge session notifications were disabled.':
      'PhoneBridge 连接通知已关闭，请重新允许',
  'Saved connection needs local attention.': '保存的连接需要你在手机上确认，请检查权限与配对',
  'Saved pairing is invalid. Pair with your computer again.':
      '保存的配对已失效，请重新与电脑配对',
  'Connection was interrupted.': '连接已中断，正在尝试恢复',
  'Command exceeded the size limit.': '电脑命令超出大小限制，连接已暂停',
  'Binary commands are not supported.': '电脑发送了不支持的命令，连接已暂停',
  'Desktop rejected this session. Resume locally after checking pairing.':
      '电脑拒绝了连接，请检查配对后在手机上继续',
  'Desktop disconnected. Reconnecting to the trusted computer.':
      '电脑已断开，正在重新连接可信电脑',
  'Pairing or certificate was rejected. Check your computer, then resume locally.':
      '配对或证书被拒绝，请检查电脑后在手机上继续',
  'Connection lost. Reconnecting to the trusted computer.': '连接已丢失，正在重新连接可信电脑',
  'Connection timed out. Reconnecting to the trusted computer.':
      '连接超时，正在重新连接可信电脑',
  'Invalid command format.': '电脑命令格式无效，连接已暂停',
  'Observation timed out. Reconnecting to the trusted computer.':
      '界面读取超时，正在重新连接可信电脑',
  'Operation timed out. Resume locally and observe before retrying.':
      '操作超时，请在手机上继续并检查界面后再重试',
  'Operation result exceeded the size limit.': '操作结果超出大小限制，连接已暂停',
  'Result could not be delivered. Observe after reconnection; never retry automatically.':
      '无法传送操作结果，请重连后检查界面，不要自动重试',
  'Saved pairing is unavailable. Unlock the phone and reopen PhoneBridge.':
      '保存的配对不可用，请解锁手机并重新打开 PhoneBridge',
  'Accessibility service stopped.': '无障碍服务已停止，请重新开启',
  'Saved pairing could not be removed. Try again.': '无法删除保存的配对，请重试',
  'Waiting for the phone to be unlocked.': '正在等待手机解锁',
  'Could not persist Stop. Forget this computer before closing PhoneBridge.':
      '无法保存暂停状态，请在关闭 PhoneBridge 前忘记这台电脑',
};
