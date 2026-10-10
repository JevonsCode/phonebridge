import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'design.dart';
import 'package:flutter/foundation.dart';
import 'pairing.dart';
import 'pairing_scanner.dart';

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
  Widget build(BuildContext context) => MaterialApp(
    title: 'PhoneBridge',
    debugShowCheckedModeBanner: false,
    theme: phoneTheme(),
    home: const ConnectionPage(),
  );
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, this.pairingScannerBuilder});
  final WidgetBuilder? pairingScannerBuilder;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  static const channel = MethodChannel('dev.phonebridge/control');
  final endpoint = TextEditingController(text: 'ws://127.0.0.1:8765/device');
  final token = TextEditingController();
  final packages = TextEditingController(
    text: 'dev.phonebridge.phonebridge\ncom.tencent.mm',
  );
  Timer? timer;
  Map<String, dynamic> status = {};
  bool consent = false, insecureLocal = false, busy = false, polling = false;
  bool remember = true;
  bool startingDesktop = false;
  String? error;
  bool pairingPrefilled = false;
  int tab = 0;
  bool showPairing = false, manual = false;
  bool get connected => status['connected'] == true;
  bool get connecting => status['connecting'] == true;
  bool get enabled => status['accessibilityEnabled'] == true;
  bool get hasSavedPairing => status['hasSavedPairing'] == true;
  bool get autoReconnect => status['autoReconnectEnabled'] == true;

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
          if (connected) showPairing = false;
        });
        if (wasActive && !connected && !connecting) token.clear();
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? '无法读取连接状态');
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
      if (['disconnect', 'connect', 'forgetSavedConnection'].contains(method)) {
        token.clear();
      }
      if (method == 'forgetSavedConnection') {
        consent = false;
        insecureLocal = false;
        pairingPrefilled = false;
        showPairing = true;
      }
      await refresh();
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? '操作失败，请检查手机状态');
    } on MissingPluginException {
      if (mounted) setState(() => error = '请在安卓设备上打开 PhoneBridge');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> connect() async {
    if (!consent || !enabled) return;
    if (!RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(token.text.trim())) {
      setState(() => error = '请输入电脑端生成的完整配对密钥（32–256 个字母、数字、- 或 _）');
      return;
    }
    await perform('requestNotificationPermission');
    if (!mounted || error != null) return;
    await perform('connect', {
      'endpoint': endpoint.text.trim(),
      'token': token.text.trim(),
      'allowInsecureLocal': insecureLocal,
      'remember': remember,
      'packages': packages.text
          .split(RegExp(r'[\s,;]+'))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
    });
  }

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
        _ => e.message ?? '电脑服务启动失败，请检查电脑端后台服务',
      };
      if (mounted) setState(() => error = message);
    } on MissingPluginException {
      if (mounted) setState(() => error = '请更新安卓端 PhoneBridge 后再试');
    } finally {
      if (mounted) setState(() => startingDesktop = false);
    }
  }

  Future<void> scanPairing() async {
    if (busy || connected || connecting) return;
    setState(() {
      busy = true;
      error = null;
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
      if (connected || connecting) {
        setState(() => error = '请先停止当前连接，再扫描新的配对码。');
        return;
      }
      setState(() {
        endpoint.text = pairing.endpoint;
        token.text = pairing.token;
        // A different computer must never inherit an earlier acknowledgement.
        consent = false;
        insecureLocal = false;
        pairingPrefilled = true;
      });
    } finally {
      if (mounted) setState(() => busy = false);
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

  void openPairing() => setState(() {
    showPairing = true;
    manual = false;
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
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text(body, style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final nativeError = status['lastError'] as String?;
    final message =
        error ?? (nativeError?.isNotEmpty == true ? nativeError : null);
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
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() => showPairing = false),
                )
              : null,
          title: Text(
            showPairing
                ? '连接电脑'
                : tab == 0
                ? 'PhoneBridge'
                : '设置',
          ),
          actions: !showPairing && tab == 0
              ? [
                  IconButton(
                    tooltip: '帮助',
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
        bottomNavigationBar:
            showPairing && !(connected || connecting || autoReconnect)
            ? null
            : SafeArea(
                top: false,
                bottom: showPairing,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (connected || connecting || autoReconnect)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 6),
                        child: SizedBox(
                          width: 512,
                          child: OutlinedButton.icon(
                            key: const Key('stop'),
                            onPressed: busy
                                ? null
                                : () => perform('disconnect'),
                            icon: const Icon(Icons.pause_rounded, size: 20),
                            label: const Text('暂停连接'),
                          ),
                        ),
                      ),
                    if (!showPairing)
                      NavigationBar(
                        selectedIndex: tab,
                        onDestinationSelected: (value) =>
                            setState(() => tab = value),
                        destinations: const [
                          NavigationDestination(
                            key: Key('nav-connection'),
                            icon: Icon(Icons.devices_outlined),
                            selectedIcon: Icon(Icons.devices_rounded),
                            label: '连接',
                          ),
                          NavigationDestination(
                            key: Key('nav-settings'),
                            icon: Icon(Icons.settings_outlined),
                            selectedIcon: Icon(Icons.settings_rounded),
                            label: '设置',
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
                                  message,
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
    final active = connected || connecting || autoReconnect;
    final granted = connected
        ? status['actionsEnabled'] == true
        : hasSavedPairing && status['rememberedActions'] == true;
    final title = connected
        ? '已连接'
        : connecting || autoReconnect
        ? '正在连接'
        : hasSavedPairing
        ? '连接已暂停'
        : '连接你的电脑';
    final subtitle = connected
        ? '手机已与这台电脑连接'
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
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 10),
      Text(
        subtitle,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14, color: muted),
      ),
      const SizedBox(height: 32),
      if (hasSavedPairing || connected) ...[
        SurfaceGroup(
          children: [
            SettingsRow(
              icon: Icons.computer_rounded,
              title: '我的电脑',
              subtitle: computerAddress,
              onTap: () => setState(() => tab = 1),
              trailing: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: connected
                      ? const Color(0xFFE9F4ED)
                      : const Color(0xFFF0F2F5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  connected ? '已连接' : '已记住',
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
          label: const Text('连接电脑'),
        ),
        const SizedBox(height: 20),
      ],
      SurfaceGroup(
        children: [
          SwitchListTile(
            key: const Key('actions'),
            contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
            value: granted,
            onChanged: connected && !busy
                ? (v) => perform('setActionsEnabled', {'enabled': v})
                : null,
            title: const Text(
              '允许操作',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              !connected && granted
                  ? '操作授权已保留，重连后恢复'
                  : granted
                  ? 'AI 可以点击、滑动和输入'
                  : '关闭时，AI 只能查看界面',
              style: const TextStyle(fontSize: 12, color: muted, height: 1.6),
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      if (!active && hasSavedPairing)
        FilledButton.icon(
          key: const Key('resume-saved'),
          onPressed: busy || startingDesktop || !enabled
              ? null
              : () => perform('resumeSavedConnection'),
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: const Text('继续连接'),
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
          label: Text(startingDesktop ? '正在启动电脑服务…' : '启动电脑服务'),
        ),
      ],
      if (!enabled) ...[
        const SizedBox(height: 16),
        TextButton(
          onPressed: busy ? null : () => perform('openAccessibilitySettings'),
          child: const Text('开启无障碍服务以继续'),
        ),
      ],
      const SizedBox(height: 16),
      Text(
        active
            ? (hasSavedPairing ? '配对与授权已保留 · 随时可以暂停' : '仅限本次连接 · 随时可以暂停')
            : '只连接你信任的电脑',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFF777F8B), fontSize: 11),
      ),
    ];
  }

  List<Widget> settingsView() => [
    const SizedBox(height: 12),
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
        SettingsRow(
          icon: Icons.laptop_mac_outlined,
          title: '已记住的电脑',
          subtitle: hasSavedPairing ? computerAddress : '尚未配对',
          onTap: hasSavedPairing ? () => showComputer() : openPairing,
        ),
      ],
    ),
    const SizedBox(height: 28),
    sectionLabel('关于'),
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
            applicationVersion: '0.2.3',
            applicationLegalese: 'MIT License',
          ),
        ),
      ],
    ),
    const SizedBox(height: 28),
    const Center(
      child: Text(
        'PhoneBridge 0.2.3',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, height: 2, color: Color(0xFF89919C)),
      ),
    ),
  ];

  Widget sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 12),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
    ),
  );

  Future<void> showComputer() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.laptop_mac_outlined, size: 36, color: blue),
            const SizedBox(height: 16),
            Text(
              '我的电脑',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              status['savedEndpoint'] as String? ?? '',
              key: const Key('saved-endpoint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: muted),
            ),
            const SizedBox(height: 24),
            const Text(
              '连接信息和你的授权已加密保存在手机中。更新 App 或网络恢复后，无需重新扫码。',
              style: TextStyle(height: 1.7),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              key: const Key('forget-saved'),
              onPressed: busy
                  ? null
                  : () {
                      Navigator.of(sheetContext).pop();
                      perform('forgetSavedConnection');
                    },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFB13B31),
              ),
              icon: const Icon(Icons.link_off_rounded, size: 20),
              label: const Text('忘记这台电脑'),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> pairingView() => [
    const SizedBox(height: 8),
    if (!manual && !pairingPrefilled) ...[
      const SizedBox(height: 20),
      const Center(child: ConnectionIllustration(connected: false)),
      const SizedBox(height: 28),
    ],
    Text('只需配对一次', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 10),
    const Text('扫描电脑端的二维码。之后的连接，交给 PhoneBridge。'),
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
      onPressed: busy || connected || connecting ? null : scanPairing,
      icon: const Icon(Icons.qr_code_scanner_rounded),
      label: const Text('扫描电脑配对码'),
    ),
    const SizedBox(height: 8),
    TextButton(
      key: const Key('manual-pairing'),
      onPressed: () => setState(() => manual = !manual),
      child: Text(manual ? '收起手动设置' : '手动输入连接信息'),
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
      const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('核对电脑地址后，确认以下连接选项。', key: Key('pairing-prefilled')),
      ),
    ],
    if (manual) ...[
      const SizedBox(height: 16),
      TextField(
        controller: endpoint,
        enabled: !connected && !connecting,
        autocorrect: false,
        decoration: const InputDecoration(labelText: '设备连接地址'),
        keyboardType: TextInputType.url,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: token,
        enabled: !connected && !connecting,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: const InputDecoration(labelText: '配对密钥'),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: packages,
        enabled: !connected && !connecting,
        minLines: 2,
        maxLines: 5,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '允许访问的应用包名',
          helperText: '每行一个；默认此应用和微信',
        ),
      ),
    ],
    if (manual || pairingPrefilled) ...[
      const SizedBox(height: 24),
      SurfaceGroup(
        children: [
          CheckboxListTile(
            key: const Key('insecure-local'),
            value: insecureLocal,
            onChanged: connected || connecting
                ? null
                : (v) => setState(() => insecureLocal = v ?? false),
            title: const Text('使用可信本地网络', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '允许本地明文连接；同一网络内的其他人可能看到传输内容。',
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
          ),
          const Divider(indent: 20, endIndent: 20),
          CheckboxListTile(
            key: const Key('consent'),
            value: consent,
            onChanged: connected || connecting
                ? null
                : (v) => setState(() => consent = v ?? false),
            title: const Text('允许共享应用界面', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '内容发送给配对电脑；AI 客户端可能转发给模型服务商。',
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
          ),
          const Divider(indent: 20, endIndent: 20),
          CheckboxListTile(
            key: const Key('remember-pairing'),
            value: remember,
            onChanged: connected || connecting
                ? null
                : (v) => setState(() => remember = v ?? false),
            title: const Text('记住电脑与授权', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '更新或网络恢复后，自动连接。',
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        key: const Key('connect'),
        onPressed: busy || !consent || !enabled || connected || connecting
            ? null
            : connect,
        icon: const Icon(Icons.link_rounded),
        label: Text(connecting ? '正在连接…' : '确认连接'),
      ),
      const SizedBox(height: 12),
      const Text(
        '首次连接为只读，操作开关由你开启。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: muted),
      ),
    ],
  ];
}
