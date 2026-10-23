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
  '等待控制': 'Waiting for control',
  '保持屏幕常亮': 'Keep screen awake',
  '关闭': 'Off',
  '控制期间': 'While controlling',
  '始终': 'Always',
  '控制期间仅在 AI 正在控制时生效；始终在 PhoneBridge 无障碍服务运行时生效。手动息屏或锁屏优先，不会唤醒或解锁手机。':
      'While controlling applies while AI controls your phone. Always applies while the PhoneBridge accessibility service runs. Turning off or locking the screen takes priority; this never wakes or unlocks your phone.',
  '无法读取屏幕常亮设置，请重试': 'Could not read the screen awake setting. Try again.',
  '无法保存屏幕常亮设置，请重试': 'Could not save the screen awake setting. Try again.',
  '台电脑在线': 'computers online',
  '当前控制方': 'Controlled by',
  '点击电脑可将控制权交给它，其他电脑保持连接。':
      'Tap a computer to hand over control. Other computers stay connected.',
  '正在控制': 'Controlling',
  '连接异常，请检查电脑服务或网络': 'Connection issue. Check the computer service or network.',
  '恢复连接': 'Resume connection',
  "\u6765\u81ea\u7535\u8111\u7684\u6587\u4ef6": "Files from your computer",
  "\u63a5\u6536\u540e\u70b9\u5206\u4eab\uff0c\u9009\u62e9\u5fae\u4fe1\u3001WhatsApp \u6216\u5176\u4ed6\u5e94\u7528":
      "Receive, then share to WeChat, WhatsApp or another app.",
  "\u7b49\u5f85\u4f60\u63a5\u6536": "Waiting for you to receive",
  "\u6b63\u5728\u63a5\u6536\u5e76\u6821\u9a8c\u2026":
      "Receiving and verifying\u2026",
  "\u5df2\u63a5\u6536": "Received",
  "\u5df2\u62d2\u7edd": "Declined",
  "\u6587\u4ef6\u5df2\u8fc7\u671f\uff0c\u8bf7\u8ba9\u7535\u8111\u91cd\u65b0\u53d1\u9001":
      "Expired. Ask the computer to send it again.",
  "\u8fde\u63a5\u5df2\u65ad\u5f00\uff0c\u8bf7\u8ba9\u7535\u8111\u91cd\u65b0\u53d1\u9001":
      "Disconnected. Ask the computer to send it again.",
  "\u63a5\u6536\u5931\u8d25\uff0c\u8bf7\u8ba9\u7535\u8111\u91cd\u65b0\u53d1\u9001":
      "Reception failed. Ask the computer to send it again.",
  "\u63a5\u6536": "Receive",
  "\u62d2\u7edd": "Decline",
  "\u5206\u4eab": "Share",
  "\u79fb\u9664": "Remove",
  '\u6709\u6587\u4ef6\u7b49\u5f85\u4f60\u63a5\u6536':
      'A file is waiting for you',
  '\u4e2a\u6587\u4ef6': 'files',
  '\u8fd8\u6ca1\u6709\u6536\u5230\u6587\u4ef6': 'No files yet',
  '\u5b58\u50a8': 'Storage',
  '\u6587\u4ef6\u5939': 'Folder',
  '\u4e0b\u8f7d/PhoneBridge': 'Download/PhoneBridge',
  '\u6253\u5f00\u6587\u4ef6\u5939': 'Open folder',
  '\u6587\u4ef6\u4fdd\u5b58\u5728\u300c\u4e0b\u8f7d/PhoneBridge\u300d\uff0c\u4e5f\u53ef\u4ee5\u5728\u7cfb\u7edf\u6587\u4ef6\u7ba1\u7406\u91cc\u67e5\u770b\u548c\u5220\u9664\u3002':
      'Files are saved in Download/PhoneBridge. You can also view or delete them in your file manager.',
  '\u66f4\u65b0\u5b89\u88c5\u5305\u548c\u4e34\u65f6\u6587\u4ef6':
      'Update packages and temporary files',
  '\u6e05\u9664\u7f13\u5b58': 'Clear cache',
  '\u6e05\u9664\u7f13\u5b58\uff1f': 'Clear cache?',
  '\u4f1a\u5220\u9664\u5df2\u4e0b\u8f7d\u7684\u66f4\u65b0\u5b89\u88c5\u5305\u548c\u4e34\u65f6\u6587\u4ef6\u3002\u6536\u5230\u7684\u6587\u4ef6\u3001\u914d\u5bf9\u548c\u6388\u6743\u4e0d\u53d7\u5f71\u54cd\u3002':
      'Downloaded update packages and temporary files will be deleted. Received files, pairing and permissions are kept.',
  '\u6e05\u9664': 'Clear',
  '\u5df2\u6e05\u9664': 'Cleared',
  '\u65e0\u6cd5\u6e05\u9664\u7f13\u5b58': 'Could not clear the cache',
  '\u6e05\u7406\u65e7\u6587\u4ef6': 'Clean up old files',
  '\u4f1a\u4ece\u624b\u673a\u4e0a\u5220\u9664\u8fd9\u4e9b\u6587\u4ef6\u3002\u7b49\u5f85\u63a5\u6536\u7684\u6587\u4ef6\u4e0d\u53d7\u5f71\u54cd\u3002':
      'These files will be deleted from your phone. Files waiting to be received are kept.',
  '7 \u5929\u524d\u7684\u6587\u4ef6': 'Older than 7 days',
  '30 \u5929\u524d\u7684\u6587\u4ef6': 'Older than 30 days',
  '\u5168\u90e8\u6587\u4ef6': 'All files',
  '\u6ca1\u6709\u7b26\u5408\u6761\u4ef6\u7684\u6587\u4ef6':
      'No files to clean up',
  '\u5df2\u6e05\u7406': 'Removed',
  '\u65e0\u6cd5\u6e05\u7406\u6587\u4ef6': 'Could not clean up files',
  '\u6ca1\u6709\u53ef\u4ee5\u6253\u5f00\u6587\u4ef6\u5939\u7684\u6587\u4ef6\u7ba1\u7406\u5e94\u7528':
      'No file manager can open this folder',
  '\u663e\u793a\u66f4\u591a': 'Show more',
  '\u66f4\u591a': 'More',
  "\u64cd\u4f5c\u65e5\u5fd7": "Operation history",
  "\u6309\u65f6\u95f4\u67e5\u770b\u64cd\u4f5c\u4e0e\u6587\u4ef6\u4f20\u8f93\u8bb0\u5f55":
      "Timeline of operations and file transfers",
  "\u5237\u65b0": "Refresh",
  "\u8bfb\u53d6\u754c\u9762": "Read screen",
  "\u67e5\u770b\u622a\u56fe": "View screenshot",
  "\u70b9\u51fb": "Tap",
  "\u957f\u6309": "Long press",
  "\u6ed1\u52a8": "Swipe",
  "\u8f93\u5165\u6587\u5b57": "Enter text",
  "\u7cfb\u7edf\u5bfc\u822a": "System navigation",
  "\u6253\u5f00\u5e94\u7528": "Launch app",
  "\u53d1\u9001\u6587\u4ef6\u9080\u8bf7": "Offer file",
  "\u6587\u4ef6\u4f20\u8f93": "File transfer",
  "\u64cd\u4f5c": "Operation",
  "\u9080\u8bf7\u5df2\u9001\u8fbe\uff0c\u7b49\u5f85\u624b\u673a\u63a5\u6536":
      "Offer delivered; waiting for receipt",
  "\u8bbe\u5907\u5df2\u5b8c\u6210": "Device reported success",
  "\u5931\u8d25": "Failed",
  "\u7ed3\u679c\u4e0d\u786e\u5b9a\uff0c\u8bf7\u68c0\u67e5\u624b\u673a":
      "Outcome unknown; check your phone",
  "\u7b49\u5f85\u63a5\u6536": "Awaiting receipt",
  "\u6b63\u5728\u63a5\u6536": "Receiving",
  "\u5df2\u8fc7\u671f": "Expired",
  "\u8fde\u63a5\u4e2d\u65ad": "Disconnected",
  "\u5df2\u6253\u5f00\u5206\u4eab\u9762\u677f\uff0c\u53d1\u9001\u7ed3\u679c\u7531\u76ee\u6807\u5e94\u7528\u786e\u8ba4":
      "Share sheet opened; check the target app for sending outcome",
  "\u72b6\u6001\u672a\u77e5": "Unknown status",
  "\u6700\u8fd1 100 \u6761\u7535\u8111\u64cd\u4f5c\u4e0e\u672c\u673a\u6587\u4ef6\u8bb0\u5f55 \u00b7 \u6700\u65b0\u5728\u524d":
      "Latest 100 computer operations and local file events \u00b7 Newest first",
  "\u4e0d\u8bb0\u5f55\u8f93\u5165\u5185\u5bb9\u3001\u622a\u56fe\u6216\u914d\u5bf9\u5bc6\u94a5":
      "No entered text, screenshots or pairing keys are logged",
  "\u6b63\u5728\u8bfb\u53d6\u65e5\u5fd7\u2026": "Loading history\u2026",
  "\u6682\u65e0\u64cd\u4f5c\u8bb0\u5f55": "No operations yet",
  "\u65e0\u6cd5\u8bfb\u53d6\u65e5\u5fd7\uff0c\u8bf7\u7a0d\u540e\u5237\u65b0":
      "History unavailable. Please refresh later.",
  "\u8fde\u63a5\u7535\u8111\u540e\u53ef\u67e5\u770b\u7535\u8111\u64cd\u4f5c\u65e5\u5fd7":
      "Connect to view the computer's operation history",
  "\u65e0\u6cd5\u8bfb\u53d6\u7535\u8111\u65e5\u5fd7\uff0c\u8bf7\u68c0\u67e5\u8fde\u63a5\u540e\u5237\u65b0":
      "Could not load computer history. Check the connection and refresh.",
  "\u8fde\u63a5\u5df2\u5207\u6362\uff0c\u8bf7\u5237\u65b0\u65e5\u5fd7":
      "Connection changed. Refresh history.",
  "\u63a5\u6536\u5931\u8d25\uff0c\u6587\u4ef6\u53ef\u80fd\u5df2\u8fc7\u671f\uff0c\u8bf7\u8ba9\u7535\u8111\u91cd\u65b0\u53d1\u9001":
      "Reception failed or expired. Ask the computer to send it again.",
  "\u6587\u4ef6\u5df2\u63a5\u6536\uff0c\u7535\u8111\u672a\u6536\u5230\u56de\u6267":
      "Received; the computer did not receive confirmation",
  "\u65e0\u6cd5\u4fdd\u5b58\u63a5\u6536\u8bb0\u5f55\uff0c\u8bf7\u68c0\u67e5\u624b\u673a\u5b58\u50a8\u7a7a\u95f4":
      "Could not save the receipt. Check phone storage.",
  '显示操作轨迹': 'Show operation trails',
  '显示 AI 点击与滑动的位置': 'Show where AI taps and swipes',
  '无法读取操作轨迹设置，请重试': 'Could not load operation trail setting. Try again.',
  '无法保存操作轨迹设置，请重试': 'Could not save operation trail setting. Try again.',
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
  '暂时连不上电脑。请确认电脑端 PhoneBridge 已打开，手机和电脑在同一网络。':
      "Can't reach your computer yet. Make sure PhoneBridge is open on it and both devices are on the same network.",
  '无障碍服务已关闭': 'Accessibility is off',
  '在最近任务里上滑清除 PhoneBridge 或强制停止后，系统会关闭它。开启后会自动连接已记住的电脑；在最近任务里锁定 PhoneBridge 可避免再次被关闭。':
      'Android turns it off when PhoneBridge is swiped away in Recents or force stopped. Turn it on to reconnect to your saved computer, and lock PhoneBridge in Recents to keep it on.',
  '开启无障碍服务': 'Enable accessibility',
  '开启无障碍服务后才能切换电脑': 'Enable accessibility to switch computers',
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
  '已记住的电脑': 'Saved computers',
  '当前电脑': 'Current computer',
  '配对另一台电脑': 'Pair another computer',
  '电脑名称': 'Computer name',
  '点击切换': 'Tap to switch',
  '删除电脑': 'Remove computer',
  '删除这台电脑？': 'Remove this computer?',
  '删除': 'Remove',
  '暂无已记住的电脑': 'No saved computers',
  '删除后会断开当前连接并移除这台电脑的配对与授权。再次连接需要重新扫码。':
      'This disconnects the current computer and removes its pairing and permissions. Scan again to reconnect.',
  '将移除这台电脑的配对与授权。再次连接需要重新扫码，其他电脑不受影响。':
      'This removes this computer’s pairing and permissions. Scan again to reconnect. Other computers are not affected.',
  '名称': 'Name',
  '修改名称': 'Rename',
  '取消': 'Cancel',
  '保存': 'Save',
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
  '扫一扫': 'Scan',
  '扫描新的电脑？': 'Scan a new computer?',
  '扫码前需要暂停当前连接。已记住的电脑和授权会保留。':
      'Pause the current connection before scanning. Your saved computers and permissions will be kept.',
  '暂停并扫码': 'Pause and scan',
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
