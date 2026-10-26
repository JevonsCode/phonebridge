import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'design.dart';
import 'package:flutter/foundation.dart';
import 'pairing.dart';
import 'pairing_scanner.dart';
import 'app_updates.dart';
import 'app_access.dart';
import 'app_language.dart';
import 'operation_trails.dart';
import 'screen_awake.dart';
import 'file_inbox.dart';
import 'file_receive_setting.dart';
import 'automation_settings.dart';
import 'operation_history.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans SC',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(const PhoneBridgeApp());
}

class PhoneBridgeApp extends StatelessWidget {
  const PhoneBridgeApp({super.key});
  @override
  Widget build(BuildContext context) => AppLanguage(
    builder: (context, locale) => MaterialApp(
      title: 'PhoneBridge',
      debugShowCheckedModeBanner: false,
      theme: phoneTheme(),
      locale: locale,
      supportedLocales: [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const ConnectionPage(),
    ),
  );
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, this.pairingScannerBuilder});
  final WidgetBuilder? pairingScannerBuilder;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

const _retryNotices = {
  'Connection was interrupted.',
  'Connection lost. Reconnecting to the trusted computer.',
  'Connection timed out. Reconnecting to the trusted computer.',
  'Desktop disconnected. Reconnecting to the trusted computer.',
  'Observation timed out. Reconnecting to the trusted computer.',
};

class _ConnectionPageState extends State<ConnectionPage> {
  static const channel = MethodChannel('dev.phonebridge/control');
  static const _defaultPairingPackages =
      'dev.phonebridge.phonebridge\ncom.tencent.mm';
  final endpoint = TextEditingController(text: 'ws://127.0.0.1:8765/device');
  final token = TextEditingController();
  final packages = TextEditingController(text: _defaultPairingPackages);
  Timer? timer;
  Map<String, dynamic> status = {};
  bool consent = false, insecureLocal = false, busy = false, polling = false;
  bool remember = true;
  bool packagesEdited = false;
  bool startingDesktop = false;
  bool openingScanner = false;
  String? error;
  bool pairingPrefilled = false;
  int tab = 0;
  int automationRevision = 0;
  bool showPairing = false, manual = false;
  String? pairingTargetEndpoint, pairingTargetComputerId;
  bool pairingHadConnection = false;
  // Retries alternate between scheduled and in flight; keep the hint until connected.
  bool reconnectFailed = false;
  VoidCallback? refreshComputerSheet;
  final files = ValueNotifier<List<Map<String, dynamic>>>(const []);
  Map<String, dynamic>? storage;

  Future<void> loadStorage() async {
    try {
      final next = await channel.invokeMapMethod<String, dynamic>(
        'storageStatus',
      );
      if (mounted) setState(() => storage = next);
    } on PlatformException {
      // Sizes are informative only; the rows still work without them.
    } on MissingPluginException {
      // Not running on Android.
    }
  }

  void notify(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, '清除缓存？')),
        content: Text(tr(context, '会删除已下载的更新安装包和临时文件。收到的文件、配对和授权不受影响。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, '取消')),
          ),
          FilledButton(
            key: const Key('confirm-clear-cache'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, '清除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final freed = await channel.invokeMethod<int>('clearCache') ?? 0;
      if (mounted) notify('${tr(context, '已清除')} ${fileSize(freed)}');
    } on PlatformException catch (e) {
      if (mounted) notify(tr(context, userError(e.code, e.message, '无法清除缓存')));
    }
    await loadStorage();
  }

  Future<int?> cleanupFiles(int? olderThanDays) async {
    try {
      final count = await channel.invokeMethod<int>('cleanupFiles', {
        'olderThanDays': olderThanDays,
      });
      await refresh();
      await loadStorage();
      return count;
    } on PlatformException catch (e) {
      if (mounted) notify(tr(context, userError(e.code, e.message, '无法清理文件')));
      return null;
    }
  }

  bool get connected =>
      (status['selectedConnected'] ?? status['connected']) == true;
  bool get connecting =>
      (status['selectedConnecting'] ?? status['connecting']) == true;
  bool get anyConnectionActive =>
      status['connected'] == true ||
      status['connecting'] == true ||
      status['reconnecting'] == true ||
      autoReconnect;
  bool get enabled => status['accessibilityEnabled'] == true;
  bool get hasSavedPairing => status['hasSavedPairing'] == true;
  List<Map<String, dynamic>> get computers =>
      (status['computers'] as List? ?? [])
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
  String get computerName =>
      (status['computerName'] as String?)?.isNotEmpty == true
      ? status['computerName'] as String
      : '我的电脑';
  bool get autoReconnect => status['autoReconnectEnabled'] == true;
  int get waitingCount {
    final value = status['waitingCount'];
    return value is int && value >= 0 && value <= 64 ? value : 0;
  }

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    endpoint.dispose();
    token.dispose();
    packages.dispose();
    files.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (polling) return;
    polling = true;
    try {
      final next = await channel.invokeMapMethod<String, dynamic>('status');
      if (mounted) {
        final wasActive = connected || connecting;
        setState(() {
          status = next ?? {};
          completePairingIfConnected();
          if (connected || !autoReconnect) {
            reconnectFailed = false;
          } else if (status['reconnecting'] == true) {
            reconnectFailed = true;
          }
        });
        files.value = (status['files'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (wasActive && !connected && !connecting && !showPairing) {
          token.clear();
        }
        refreshComputerSheet?.call();
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = userError(e.code, e.message, '无法读取连接状态'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => error = '控制服务仅在 Android 11 或更新版本上可用');
    } finally {
      polling = false;
    }
  }

  Future<void> perform(String method, [Map<String, dynamic>? args]) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await channel.invokeMethod<void>(method, args);
      if ([
        'disconnect',
        'connect',
        'forgetSavedConnection',
        'forgetComputer',
      ].contains(method)) {
        token.clear();
      }
      if (method == 'forgetSavedConnection' || method == 'forgetComputer') {
        consent = false;
        insecureLocal = false;
        pairingPrefilled = false;
        showPairing = false;
      }
      if (method == 'allowAllAutomation' && mounted) {
        setState(() => automationRevision++);
      }
      await refresh();
      if ((method == 'forgetSavedConnection' || method == 'forgetComputer') &&
          !hasSavedPairing &&
          computers.isEmpty) {
        if (mounted) setState(() => showPairing = true);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = userError(e.code, e.message, '操作失败，请检查手机状态'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => error = '请在安卓设备上打开 PhoneBridge');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> connect() async {
    if (busy || openingScanner || startingDesktop || !consent || !enabled) {
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(token.text.trim())) {
      setState(() => error = '请输入电脑端生成的完整配对密钥（32–256 个字母、数字、- 或 _）');
      return;
    }
    final target = endpoint.text.trim();
    final hadConnection = anyConnectionActive;
    final arguments = <String, dynamic>{
      'endpoint': target,
      'token': token.text.trim(),
      'allowInsecureLocal': insecureLocal,
      'remember': remember,
      'replaceAllowedPackages': packagesEdited,
      'packages': packages.text
          .split(RegExp(r'[\s,;]+'))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
    };
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await channel.invokeMethod<void>('requestNotificationPermission');
      if (!mounted || !showPairing) return;
      final result = await channel.invokeMapMethod<String, dynamic>(
        'connect',
        arguments,
      );
      if (!mounted) return;
      token.clear();
      setState(() {
        final acceptedEndpoint = result?['endpoint'];
        // Native normalizes accepted addresses to /device.
        pairingTargetEndpoint =
            acceptedEndpoint is String && acceptedEndpoint.isNotEmpty
            ? acceptedEndpoint
            : target;
        pairingTargetComputerId = result?['activeComputerId'] as String?;
        pairingHadConnection = hadConnection;
        if (result != null) status = result;
        completePairingIfConnected();
      });
      await refresh();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = userError(e.code, e.message, '操作失败，请检查手机状态'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => error = '请在安卓设备上打开 PhoneBridge');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void pairingCredentialsChanged() => setState(() {
    packages.text = _defaultPairingPackages;
    packagesEdited = false;
    consent = false;
    insecureLocal = false;
    pairingTargetEndpoint = null;
    pairingTargetComputerId = null;
  });

  void completePairingIfConnected() {
    if (!showPairing || pairingTargetEndpoint == null) return;
    final id = pairingTargetComputerId;
    final targetConnected = status.containsKey('selectedConnected')
        ? connected &&
              status['endpoint'] == pairingTargetEndpoint &&
              (id == null || id.isEmpty || status['activeComputerId'] == id)
        : id != null && id.isNotEmpty
        ? computers.any(
            (computer) =>
                computer['id'] == id &&
                computer['endpoint'] == pairingTargetEndpoint &&
                (computer['connected'] == true ||
                    computer['state'] == 'connected' ||
                    computer['state'] == 'controlling'),
          )
        : (status['endpoint'] == pairingTargetEndpoint &&
                  (status['effectiveAllowedPackages'] as List? ?? [])
                      .isNotEmpty) ||
              (!pairingHadConnection &&
                  computers.isEmpty &&
                  connected &&
                  !connecting);
    if (targetConnected) {
      showPairing = false;
      pairingTargetEndpoint = null;
      pairingTargetComputerId = null;
    }
  }

  Future<void> openAppAccess({bool draft = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final snapshot = await channel
          .invokeMapMethod<String, dynamic>('getAppAccess', {
            'draft': draft,
            if (draft) 'endpoint': endpoint.text.trim(),
            if (draft) 'token': token.text.trim(),
          });
      if (snapshot == null) {
        throw PlatformException(code: 'APP_ACCESS_UNAVAILABLE');
      }
      if (draft && packagesEdited) {
        snapshot['allowedPackages'] = packages.text.split('\n');
      }
      if (!mounted) return;
      final result = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          builder: (_) => AppAccessPage(snapshot: snapshot, draft: draft),
        ),
      );
      if (mounted && draft && result != null) {
        setState(() {
          packages.text = result.join('\n');
          packagesEdited = true;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = userError(e.code, e.message, '无法读取应用授权，请重试'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => error = '请更新安卓端 PhoneBridge 后再试');
    } finally {
      try {
        await channel.invokeMethod<void>('closeAppAccess');
      } on PlatformException {
        // The native activity also clears its local editor guard when destroyed.
      } on MissingPluginException {
        // Non-Android widget tests do not have a native editor guard.
      }
      await refresh();
      if (mounted) setState(() => busy = false);
    }
  }

  Widget appAccessEntry(String key) => ProtectedControl(
    name: 'app-access',
    child: SettingsRow(
      key: Key(key),
      icon: Icons.apps_rounded,
      title: '允许访问的应用',
      subtitle:
          '${(status['allowedPackages'] as List? ?? []).length} ${tr(context, '个应用 · 点击修改')}',
      onTap: busy ? null : () => openAppAccess(),
    ),
  );

  Future<void> startDesktopService() async {
    if (startingDesktop || busy || !hasSavedPairing || connected) return;
    setState(() {
      startingDesktop = true;
      error = null;
    });
    try {
      // Credentials stay in Android's encrypted pairing store.
      await channel.invokeMethod<void>('startDesktopService');
      await refresh();
    } on PlatformException catch (e) {
      final message = switch (e.code) {
        'ACCESSIBILITY_DISABLED' => '请先开启 PhoneBridge 无障碍服务',
        'DEVICE_LOCKED' => '请先解锁手机，再启动电脑服务',
        'NOTIFICATIONS_DISABLED' => '请允许 PhoneBridge 的连接通知后再试',
        'NO_SAVED_PAIRING' => '请先与电脑配对',
        _ => userError(e.code, e.message, '电脑服务启动失败，请检查电脑端后台服务'),
      };
      if (mounted) setState(() => error = message);
    } on MissingPluginException {
      if (mounted) setState(() => error = '请更新安卓端 PhoneBridge 后再试');
    } finally {
      if (mounted) setState(() => startingDesktop = false);
    }
  }

  Future<void> scanPairing() async {
    if (busy || startingDesktop) return;
    setState(() {
      busy = true;
      error = null;
      pairingTargetEndpoint = null;
      pairingTargetComputerId = null;
    });
    try {
      final pairing = await Navigator.of(context).push<PairingData>(
        MaterialPageRoute<PairingData>(
          builder:
              widget.pairingScannerBuilder ?? (_) => const PairingScannerPage(),
        ),
      );
      if (!mounted || pairing == null) return;
      await refresh();
      if (!mounted) return;
      setState(() {
        endpoint.text = pairing.endpoint;
        token.text = pairing.token;
        // A different computer must never inherit an earlier acknowledgement.
        consent = false;
        insecureLocal = false;
        pairingPrefilled = true;
        packages.text = _defaultPairingPackages;
        packagesEdited = false;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scanFromHome() async {
    if (busy || startingDesktop || openingScanner) return;
    setState(() => openingScanner = true);
    try {
      preparePairing();
      await scanPairing();
    } finally {
      if (mounted) setState(() => openingScanner = false);
    }
  }

  String get computerAddress {
    final value =
        status['savedEndpoint'] as String? ??
        status['endpoint'] as String? ??
        endpoint.text;
    final uri = Uri.tryParse(value);
    return uri?.host.isNotEmpty == true ? uri!.host : '你的电脑';
  }

  Future<void> openFiles() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FileInboxPage(
        files: files,
        onAction: (method, id) async {
          await perform(method, {'id': id});
          final message = error;
          if (message != null && mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(tr(context, message))));
          }
        },
        onOpenFolder: () => perform('openFilesFolder'),
        onCleanup: cleanupFiles,
      ),
    ),
  );

  void openPairing() => setState(() {
    showPairing = true;
    manual = false;
    pairingTargetEndpoint = null;
    pairingTargetComputerId = null;
  });

  Future<void> showInfo(String title, String body) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr(context, title),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  tr(context, body),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final nativeError = status['lastError'] as String?;
    // While retrying, the home subtitle already says so; a banner would
    // repeat it and shift the page each time it appears.
    final retrying =
        autoReconnect && !connected && _retryNotices.contains(nativeError);
    final message =
        error ??
        (nativeError?.isNotEmpty == true && !retrying
            ? userError(null, nativeError, '操作失败，请检查手机状态')
            : null);
    return PopScope(
      canPop: !showPairing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => showPairing = false);
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 24,
          leading: showPairing
              ? IconButton(
                  tooltip: tr(context, '返回'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() => showPairing = false),
                )
              : null,
          title: Text(
            tr(
              context,
              showPairing
                  ? '连接电脑'
                  : tab == 0
                  ? 'PhoneBridge'
                  : '设置',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: !showPairing && tab == 0
              ? [
                  TextButton.icon(
                    key: const Key('home-scan-pairing'),
                    onPressed: busy || startingDesktop || openingScanner
                        ? null
                        : scanFromHome,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                    label: Text(tr(context, '扫一扫')),
                  ),
                  IconButton(
                    tooltip: tr(context, '帮助'),
                    onPressed: () => showInfo(
                      '连接，一次就好',
                      '首次扫描电脑端的配对码。记住电脑后，更新 App 或网络恢复时会自动重连。\n\n保持手机解锁，电脑端服务运行即可。你可以随时暂停连接。',
                    ),
                    icon: const Icon(Icons.help_outline_rounded, size: 22),
                  ),
                  const SizedBox(width: 12),
                ]
              : null,
        ),
        bottomNavigationBar: showPairing && !anyConnectionActive
            ? null
            : SafeArea(
                top: false,
                bottom: showPairing,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (anyConnectionActive)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 6),
                        child: SizedBox(
                          width: 512,
                          child: ProtectedControl(
                            name: 'pause',
                            child: OutlinedButton.icon(
                              key: const Key('stop'),
                              onPressed: busy
                                  ? null
                                  : () => perform('disconnect'),
                              icon: const Icon(Icons.pause_rounded, size: 20),
                              label: Text(tr(context, '暂停连接')),
                            ),
                          ),
                        ),
                      ),
                    if (!showPairing)
                      NavigationBar(
                        selectedIndex: tab,
                        onDestinationSelected: (value) {
                          setState(() => tab = value);
                          if (value == 1) unawaited(loadStorage());
                        },
                        destinations: [
                          NavigationDestination(
                            key: Key('nav-connection'),
                            icon: Icon(Icons.devices_outlined),
                            selectedIcon: Icon(Icons.devices_rounded),
                            label: tr(context, '连接'),
                          ),
                          NavigationDestination(
                            key: Key('nav-settings'),
                            icon: Icon(Icons.settings_outlined),
                            selectedIcon: Icon(Icons.settings_rounded),
                            label: tr(context, '设置'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                key: ValueKey(showPairing ? 'pairing-page' : 'page-$tab'),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFCEEEB),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.info_outline_rounded,
                                size: 20,
                                color: Color(0xFF9C4033),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  tr(context, message),
                                  key: const Key('error'),
                                  style: const TextStyle(
                                    color: Color(0xFF9C4033),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (showPairing)
                      ...pairingView()
                    else if (tab == 0)
                      ...homeView()
                    else
                      ...settingsView(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> homeView() {
    final active = anyConnectionActive;
    final granted = connected
        ? (status['selectedActionsEnabled'] ?? status['actionsEnabled']) == true
        : hasSavedPairing && status['rememberedActions'] == true;
    // Without the service no transport can open, so "waiting" would mislead.
    final needsAccessibility = !enabled && !connected && hasSavedPairing;
    final title = connected
        ? '已连接'
        : needsAccessibility
        ? '无障碍服务已关闭'
        : connecting || autoReconnect
        ? '正在连接'
        : hasSavedPairing
        ? '连接已暂停'
        : '连接你的电脑';
    final subtitle = needsAccessibility
        ? '在最近任务里上滑清除 PhoneBridge 或强制停止后，系统会关闭它。开启后会自动连接已记住的电脑；在最近任务里锁定 PhoneBridge 可避免再次被关闭。'
        : autoReconnect && reconnectFailed
        ? '暂时连不上电脑。请确认电脑端 PhoneBridge 已打开，手机和电脑在同一网络。'
        : autoReconnect
        ? '正在等待电脑，连接会自动恢复'
        : hasSavedPairing
        ? '电脑已记住，随时可以继续'
        : '连接电脑，让 AI 帮你处理手机上的事';
    return [
      const SizedBox(height: 12),
      Center(child: ConnectionIllustration(connected: connected)),
      const SizedBox(height: 22),
      Text(
        tr(context, title),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.displaySmall,
      ),
      if (waitingCount > 0) ...[
        const SizedBox(height: 10),
        Text(
          '${tr(context, '等待控制')} · $waitingCount',
          key: const Key('control-waiting-count'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 13),
        ),
      ],
      if (!connected) ...[
        const SizedBox(height: 10),
        Text(
          tr(context, subtitle),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: muted, height: 1.6),
        ),
      ],
      if (needsAccessibility) ...[
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('enable-accessibility'),
          onPressed: busy ? null : () => perform('openAccessibilitySettings'),
          icon: const Icon(Icons.accessibility_new_rounded, size: 20),
          label: Text(tr(context, '开启无障碍服务')),
        ),
      ],
      const SizedBox(height: 32),
      if (hasSavedPairing || connected || computers.isNotEmpty) ...[
        SurfaceGroup(
          children: [
            SettingsRow(
              icon: Icons.computer_rounded,
              title: computerName,
              subtitle:
                  '${computerAddress.isEmpty || computerAddress == computerName ? '' : '$computerAddress\n'}${tr(context, '点击切换')}',
              onTap: busy || startingDesktop ? null : showComputer,
              trailing: Container(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: connected
                      ? const Color(0xFFE9F4ED)
                      : const Color(0xFFF0F2F5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tr(context, connected ? '已连接' : '已记住'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: connected ? const Color(0xFF26734D) : muted,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
      if (!hasSavedPairing && !connected) ...[
        FilledButton.icon(
          key: const Key('start-pairing'),
          onPressed: busy ? null : openPairing,
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
          label: Text(tr(context, '连接电脑')),
        ),
        const SizedBox(height: 20),
      ],
      SurfaceGroup(
        children: [
          ProtectedControl(
            name: 'actions',
            child: SwitchListTile(
              key: const Key('actions'),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
              value: granted,
              onChanged: connected && !busy
                  ? (v) => perform('setActionsEnabled', {'enabled': v})
                  : null,
              title: Text(
                tr(context, '允许操作'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                tr(
                  context,
                  !connected && granted
                      ? '操作授权已保留，重连后恢复'
                      : granted
                      ? 'AI 可以操作下方已授权的应用'
                      : 'AI 只能查看下方已授权的应用',
                ),
                style: const TextStyle(fontSize: 12, color: muted, height: 1.6),
              ),
            ),
          ),
        ],
      ),
      if (hasSavedPairing || connected || connecting) ...[
        const SizedBox(height: 12),
        SurfaceGroup(children: [appAccessEntry('home-app-access')]),
      ],
      if (files.value.isNotEmpty) ...[
        const SizedBox(height: 16),
        FileInboxEntry(files: files.value, onOpen: openFiles),
      ],
      const SizedBox(height: 24),
      if (!active && hasSavedPairing)
        FilledButton.icon(
          key: const Key('resume-saved'),
          onPressed: busy || startingDesktop || !enabled
              ? null
              : () => perform('resumeSavedConnection'),
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: Text(tr(context, '继续连接')),
        ),
      if (hasSavedPairing && !connected) ...[
        if (!active) const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('start-desktop-service'),
          onPressed: busy || startingDesktop || !enabled
              ? null
              : startDesktopService,
          icon: Icon(
            startingDesktop
                ? Icons.hourglass_top_rounded
                : Icons.power_settings_new_rounded,
            size: 20,
          ),
          label: Text(tr(context, startingDesktop ? '正在启动电脑服务…' : '启动电脑服务')),
        ),
      ],
      if (!enabled && !needsAccessibility) ...[
        const SizedBox(height: 16),
        TextButton(
          onPressed: busy ? null : () => perform('openAccessibilitySettings'),
          child: Text(tr(context, '开启无障碍服务以继续')),
        ),
      ],
      const SizedBox(height: 16),
      Text(
        tr(
          context,
          active
              ? (hasSavedPairing ? '配对与授权已保留 · 随时可以暂停' : '仅限本次连接 · 随时可以暂停')
              : '只连接你信任的电脑',
        ),
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFF777F8B), fontSize: 11),
      ),
    ];
  }

  List<Widget> settingsView() => [
    const SizedBox(height: 12),
    if (hasSavedPairing || connected) ...[
      ProtectedControl(
        name: 'allow-all',
        child: FilledButton.icon(
          key: const Key('allow-all-automation'),
          onPressed: busy ? null : () => perform('allowAllAutomation'),
          icon: const Icon(Icons.done_all_rounded, size: 20),
          label: Text(tr(context, '全部允许')),
        ),
      ),
      const SizedBox(height: 12),
    ],
    SurfaceGroup(
      key: ValueKey('automation-$automationRevision'),
      children: const [
        AutomationSetting(
          preference: 'ClipboardAccessEnabled',
          title: '允许 AI 使用剪贴板',
          subtitle: '读取、复制和粘贴手机上的文字',
        ),
        FileReceiveSetting(),
        AutomationSetting(
          preference: 'SaveMediaToGallery',
          title: '图片和视频保存到相册',
          subtitle: '收到后可直接在其他应用中选择',
        ),
        AutomationSetting(
          preference: 'ProtectConnectionControls',
          title: '避免 AI 误断开连接',
          subtitle: '保护连接和授权开关，防止操作中误触',
        ),
      ],
    ),
    const SizedBox(height: 12),
    const SurfaceGroup(children: [OperationTrailSetting()]),
    const SizedBox(height: 12),
    const SurfaceGroup(children: [ScreenAwakeSetting()]),
    const SizedBox(height: 28),
    sectionLabel('连接与权限'),
    SurfaceGroup(
      children: [
        SettingsRow(
          icon: Icons.accessibility_new_rounded,
          title: '无障碍服务',
          subtitle: enabled ? '已开启' : '尚未开启',
          onTap: busy ? null : () => perform('openAccessibilitySettings'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(),
        ),
        ProtectedControl(
          name: 'computers',
          child: SettingsRow(
            icon: Icons.laptop_mac_outlined,
            title: '已记住的电脑',
            subtitle: computers.isNotEmpty || hasSavedPairing
                ? computerAddress
                : '尚未配对',
            onTap: busy || startingDesktop
                ? null
                : computers.isNotEmpty || hasSavedPairing
                ? showComputer
                : openPairing,
          ),
        ),
        if (hasSavedPairing || connected || connecting) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(),
          ),
          appAccessEntry('settings-app-access'),
        ],
      ],
    ),
    const SizedBox(height: 28),
    sectionLabel('存储'),
    SurfaceGroup(
      children: [
        SettingsRow(
          key: const Key('open-files-folder'),
          icon: Icons.folder_open_outlined,
          title: '文件夹',
          subtitle: storage == null
              ? '下载/PhoneBridge'
              : '${tr(context, '下载/PhoneBridge')} · ${storage!['downloadFiles'] ?? storage!['files']} ${tr(context, '个文件')} · ${fileSize((storage!['downloadBytes'] ?? storage!['bytes']) as num? ?? 0)}',
          onTap: busy ? null : () => perform('openFilesFolder'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(),
        ),
        SettingsRow(
          key: const Key('clear-cache'),
          icon: Icons.cleaning_services_outlined,
          title: '清除缓存',
          subtitle: storage == null
              ? '更新安装包和临时文件'
              : '${tr(context, '更新安装包和临时文件')} · ${fileSize(storage!['cacheBytes'] as num? ?? 0)}',
          onTap: busy ? null : clearCache,
        ),
      ],
    ),
    const SizedBox(height: 28),
    SurfaceGroup(
      children: [
        SettingsRow(
          icon: Icons.translate_rounded,
          title: '语言',
          subtitle: switch (AppLanguage.of(context)?.preference) {
            'zh' => '中文',
            'en' => 'English',
            _ => '跟随系统',
          },
          onTap: showLanguage,
        ),
      ],
    ),
    const SizedBox(height: 28),
    sectionLabel('关于'),
    const AppUpdateCard(),
    const SizedBox(height: 16),
    SurfaceGroup(
      children: [
        SettingsRow(
          icon: Icons.open_in_new_rounded,
          title: 'GitHub',
          subtitle: '查看源码、下载与反馈',
          onTap: () => perform('openProjectLink', {'destination': 'github'}),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(),
        ),
        SettingsRow(
          icon: Icons.language_rounded,
          title: '官方网站',
          subtitle: '了解 PhoneBridge 与安装方法',
          onTap: () => perform('openProjectLink', {'destination': 'website'}),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(),
        ),
        SettingsRow(
          icon: Icons.privacy_tip_outlined,
          title: '隐私与数据',
          subtitle: '了解界面内容如何传输',
          onTap: () => showInfo(
            '隐私与数据',
            'PhoneBridge 将允许应用的界面内容发送给配对电脑，不建立云端、不收集遥测、不保存聊天记录。\n\n连接的 AI 可能将内容发送给其模型服务商，请查看该客户端的数据设置。截图可能包含个人信息。\n\n手机会加密保存配对与授权。忘记电脑后，保存的授权会被删除。',
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(),
        ),
        SettingsRow(
          icon: Icons.code_rounded,
          title: '开源许可',
          subtitle: 'PhoneBridge · MIT License',
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'PhoneBridge',
            applicationIcon: Image.asset(
              'assets/brand/logo.png',
              width: 64,
              height: 64,
            ),
            applicationLegalese: 'MIT License',
          ),
        ),
      ],
    ),
    const SizedBox(height: 28),
    SurfaceGroup(
      children: [
        SettingsRow(
          icon: Icons.history_rounded,
          title: '操作日志',
          subtitle: '按时间查看操作与文件传输记录',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => OperationHistoryPage(computerName: computerName),
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: 28),
    Center(child: Image.asset('assets/brand/logo.png', width: 64, height: 64)),
    Center(
      child: Text(
        tr(context, 'PhoneBridge'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, height: 2, color: Color(0xFF89919C)),
      ),
    ),
  ];

  Future<void> showLanguage() async {
    final owner = AppLanguage.of(context);
    if (owner == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final choice in const {
              'system': '跟随系统',
              'zh': '中文',
              'en': 'English',
            }.entries)
              ListTile(
                key: Key('language-${choice.key}'),
                title: Text(tr(sheetContext, choice.value)),
                trailing: owner.preference == choice.key
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: owner.saving
                    ? null
                    : () async {
                        if (owner.saving) return;
                        try {
                          await owner.select(choice.key);
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                        } on PlatformException {
                          if (mounted) setState(() => error = '无法保存语言设置，请重试');
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                        }
                      },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 12),
    child: Text(
      tr(context, text),
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: muted),
    ),
  );

  Future<void> renameComputer(Map<String, dynamic> computer) async {
    final name = TextEditingController(text: computer['name'] as String? ?? '');
    final renamed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        scrollable: true,
        title: Text(tr(context, '电脑名称')),
        content: SizedBox(
          width: 440,
          child: TextField(
            key: const Key('computer-name'),
            controller: name,
            autofocus: true,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: tr(context, '名称'),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFD8DEE8)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: blue, width: 1.5),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr(context, '取消')),
          ),
          FilledButton(
            key: const Key('save-computer-name'),
            onPressed: () {
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(dialogContext, name.text.trim());
              }
            },
            child: Text(tr(context, '保存')),
          ),
        ],
      ),
    );
    // Dialog exit animations may still be using the controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    if (mounted && renamed != null) {
      await perform('renameComputer', {'id': computer['id'], 'name': renamed});
    }
  }

  Future<void> pairAnotherComputer() async {
    if (busy || startingDesktop || openingScanner) return;
    preparePairing();
  }

  void preparePairing() {
    error = null;
    token.clear();
    consent = false;
    insecureLocal = false;
    pairingPrefilled = false;
    packages.text = _defaultPairingPackages;
    packagesEdited = false;
    remember = true;
    openPairing();
  }

  Future<void> forgetComputer(Map<String, dynamic> computer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(tr(context, '删除这台电脑？')),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              computer['name'] as String? ?? '',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(computer['endpoint'] as String? ?? ''),
            const SizedBox(height: 16),
            Text(
              tr(
                context,
                computer['active'] == true
                    ? '删除后会断开当前连接并移除这台电脑的配对与授权。再次连接需要重新扫码。'
                    : '将移除这台电脑的配对与授权。再次连接需要重新扫码，其他电脑不受影响。',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, '取消')),
          ),
          FilledButton(
            key: const Key('confirm-forget-computer'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB13B31),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, '删除')),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await perform('forgetComputer', {'id': computer['id']});
    }
  }

  Future<void> showComputer() async {
    var editing = false;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, updateSheet) {
          refreshComputerSheet = () {
            if (sheetContext.mounted) updateSheet(() {});
          };
          Future<void> edit(Future<void> Function() action) async {
            if (editing || busy || startingDesktop) return;
            updateSheet(() => editing = true);
            try {
              await action();
            } finally {
              if (sheetContext.mounted) updateSheet(() => editing = false);
            }
          }

          final disabled = editing || busy || startingDesktop;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(context, '已记住的电脑'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${status['connectedComputerCount'] ?? computers.where((c) => c['connected'] == true || c['state'] == 'connected').length} ${tr(context, '台电脑在线')}',
                    key: const Key('connected-computer-count'),
                  ),
                  if ((status['controlOwnerName'] as String? ?? '').isNotEmpty)
                    Text(
                      '${tr(context, '当前控制方')} · ${status['controlOwnerName']}',
                      key: const Key('control-owner'),
                    ),
                  if (waitingCount > 0)
                    Text(
                      '${tr(context, '等待控制')} · $waitingCount',
                      key: const Key('computer-sheet-waiting-count'),
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  Text(
                    tr(context, 'AI 按顺序排队，用完自动交接；点选电脑仅查看设置。'),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  if (!enabled) ...[
                    Text(
                      tr(context, '开启无障碍服务后才能切换电脑'),
                      key: const Key('computer-sheet-accessibility'),
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (error != null) ...[
                    Text(
                      tr(context, error!),
                      key: const Key('computer-sheet-error'),
                      style: const TextStyle(color: Color(0xFFB13B31)),
                    ),
                    const SizedBox(height: 12),
                  ],
                  for (final computer in computers) ...[
                    Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: Key('computer-${computer['id']}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: disabled || !enabled
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                perform('selectComputer', {
                                  'id': computer['id'],
                                });
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      computer['name'] as String? ?? '',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                  ),
                                  IconButton(
                                    key: Key('rename-${computer['id']}'),
                                    tooltip: tr(context, '修改名称'),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 20,
                                    ),
                                    onPressed: disabled
                                        ? null
                                        : () => edit(
                                            () => renameComputer(computer),
                                          ),
                                  ),
                                  IconButton(
                                    key: Key('forget-${computer['id']}'),
                                    tooltip: tr(context, '删除电脑'),
                                    color: const Color(0xFFB13B31),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                    ),
                                    onPressed: disabled
                                        ? null
                                        : () => edit(
                                            () => forgetComputer(computer),
                                          ),
                                  ),
                                ],
                              ),
                              Text(
                                computer['endpoint'] as String? ?? '',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${tr(context, switch (computer['state']) {
                                  'controlling' => '正在控制',
                                  'connected' => '已连接',
                                  'connecting' => '正在连接',
                                  'paused' => '连接已暂停',
                                  _ => '已记住',
                                })}${computer['active'] == true ? ' · ${tr(context, '当前电脑')}' : ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: muted,
                                ),
                              ),
                              if (computer['controlling'] == true)
                                Text(
                                  tr(context, '正在控制'),
                                  style: const TextStyle(
                                    color: blue,
                                    fontSize: 12,
                                  ),
                                ),
                              if ((computer['lastError'] as String? ?? '')
                                  .isNotEmpty)
                                Text(
                                  tr(context, '连接异常，请检查电脑服务或网络'),
                                  style: const TextStyle(
                                    color: Color(0xFFB13B31),
                                    fontSize: 12,
                                  ),
                                ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  ProtectedControl(
                                    name: 'computer-resume',
                                    child: TextButton(
                                      key: Key('resume-${computer['id']}'),
                                      onPressed: disabled || !enabled
                                          ? null
                                          : () => edit(
                                              () => perform(
                                                'setComputerResumeAllowed',
                                                {
                                                  'id': computer['id'],
                                                  'enabled':
                                                      computer['resumeAllowed'] !=
                                                      true,
                                                },
                                              ),
                                            ),
                                      child: Text(
                                        tr(
                                          context,
                                          computer['resumeAllowed'] == true
                                              ? '暂停连接'
                                              : '恢复连接',
                                        ),
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    key: Key('start-service-${computer['id']}'),
                                    onPressed: disabled || !enabled
                                        ? null
                                        : () => edit(
                                            () => perform(
                                              'startDesktopService',
                                              {'id': computer['id']},
                                            ),
                                          ),
                                    child: Text(tr(context, '启动电脑服务')),
                                  ),
                                ],
                              ),
                              ProtectedControl(
                                name: 'computer-actions',
                                child: SwitchListTile(
                                  key: Key('actions-${computer['id']}'),
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    tr(context, '允许操作'),
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  value: computer['actionsEnabled'] == true,
                                  onChanged: disabled
                                      ? null
                                      : (value) => edit(
                                          () => perform('setActionsEnabled', {
                                            'id': computer['id'],
                                            'enabled': value,
                                          }),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(),
                  ],
                  if (computers.isEmpty) Text(tr(context, '暂无已记住的电脑')),
                  const SizedBox(height: 16),
                  Text(
                    tr(context, '连接信息和你的授权已加密保存在手机中。更新 App 或网络恢复后，无需重新扫码。'),
                    style: const TextStyle(
                      height: 1.7,
                      fontSize: 13,
                      color: muted,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ProtectedControl(
                    name: 'pair-another',
                    child: FilledButton.icon(
                      key: const Key('pair-another-computer'),
                      onPressed: disabled
                          ? null
                          : () {
                              Navigator.pop(sheetContext);
                              pairAnotherComputer();
                            },
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: Text(tr(context, '配对另一台电脑')),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    refreshComputerSheet = null;
  }

  List<Widget> pairingView() => [
    const SizedBox(height: 8),
    if (!manual && !pairingPrefilled) ...[
      const SizedBox(height: 20),
      const Center(child: ConnectionIllustration(connected: false)),
      const SizedBox(height: 28),
    ],
    Text(
      tr(context, '只需配对一次'),
      style: Theme.of(context).textTheme.headlineMedium,
    ),
    const SizedBox(height: 10),
    Text(tr(context, '扫描电脑端的二维码。之后的连接，交给 PhoneBridge。')),
    const SizedBox(height: 24),
    if (!enabled) ...[
      SurfaceGroup(
        children: [
          SettingsRow(
            icon: Icons.accessibility_new_rounded,
            title: '先开启无障碍服务',
            subtitle: '用于读取界面和执行操作',
            onTap: busy ? null : () => perform('openAccessibilitySettings'),
          ),
        ],
      ),
      const SizedBox(height: 16),
    ],
    FilledButton.icon(
      key: const Key('scan-pairing'),
      onPressed: busy || openingScanner || startingDesktop ? null : scanPairing,
      icon: const Icon(Icons.qr_code_scanner_rounded),
      label: Text(tr(context, '扫描电脑配对码')),
    ),
    const SizedBox(height: 8),
    TextButton(
      key: const Key('manual-pairing'),
      onPressed: busy || openingScanner
          ? null
          : () => setState(() => manual = !manual),
      child: Text(tr(context, manual ? '收起手动设置' : '手动输入连接信息')),
    ),
    if (pairingPrefilled) ...[
      const SizedBox(height: 12),
      SurfaceGroup(
        children: [
          SettingsRow(
            icon: Icons.check_circle_outline_rounded,
            title: '已识别电脑',
            subtitle: Uri.tryParse(endpoint.text)?.host,
            trailing: const Icon(Icons.check_rounded, color: Color(0xFF18845A)),
          ),
        ],
      ),
      Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          tr(context, '核对电脑地址后，确认以下连接选项。'),
          key: Key('pairing-prefilled'),
        ),
      ),
    ],
    if (manual) ...[
      const SizedBox(height: 16),
      TextField(
        controller: endpoint,
        onChanged: (_) => pairingCredentialsChanged(),
        enabled: !busy && !openingScanner,
        autocorrect: false,
        decoration: InputDecoration(labelText: tr(context, '设备连接地址')),
        keyboardType: TextInputType.url,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: token,
        onChanged: (_) => pairingCredentialsChanged(),
        enabled: !busy && !openingScanner,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: InputDecoration(labelText: tr(context, '配对密钥')),
      ),
    ],
    if (manual || pairingPrefilled) ...[
      const SizedBox(height: 16),
      SurfaceGroup(
        children: [
          SettingsRow(
            key: const Key('pairing-app-access'),
            icon: Icons.apps_rounded,
            title: '允许访问的应用',
            subtitle: packagesEdited
                ? '${packages.text.split('\n').length} ${tr(context, '个应用 · 点击修改')}'
                : '点击查看或修改；重新配对会保留原授权',
            onTap: busy ? null : () => openAppAccess(draft: true),
          ),
        ],
      ),
      const SizedBox(height: 24),
      SurfaceGroup(
        children: [
          CheckboxListTile(
            key: const Key('insecure-local'),
            value: insecureLocal,
            onChanged: busy || openingScanner
                ? null
                : (v) => setState(() => insecureLocal = v ?? false),
            title: Text(
              tr(context, '使用可信本地网络'),
              style: TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              tr(context, '允许本地明文连接；同一网络内的其他人可能看到传输内容。'),
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          const Divider(indent: 20, endIndent: 20),
          CheckboxListTile(
            key: const Key('consent'),
            value: consent,
            onChanged: busy || openingScanner
                ? null
                : (v) => setState(() => consent = v ?? false),
            title: Text(
              tr(context, '允许共享应用界面'),
              style: TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              tr(context, '内容发送给配对电脑；AI 客户端可能转发给模型服务商。'),
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          const Divider(indent: 20, endIndent: 20),
          CheckboxListTile(
            key: const Key('remember-pairing'),
            value: remember,
            onChanged: busy || openingScanner
                ? null
                : (v) => setState(() => remember = v ?? false),
            title: Text(tr(context, '记住电脑与授权'), style: TextStyle(fontSize: 14)),
            subtitle: Text(
              tr(context, '更新或网络恢复后，自动连接。'),
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
        ],
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        key: const Key('connect'),
        onPressed:
            busy || openingScanner || startingDesktop || !consent || !enabled
            ? null
            : connect,
        icon: const Icon(Icons.link_rounded),
        label: Text(tr(context, busy ? '正在连接…' : '确认连接')),
      ),
      const SizedBox(height: 12),
      Text(
        tr(context, '首次连接为只读，操作开关由你开启。'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: muted),
      ),
    ],
  ];
}
