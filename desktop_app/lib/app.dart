import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'backend.dart';
import 'design.dart';

bool isStableMcpConfiguration(Map<String, dynamic>? config) {
  final servers = config?['mcpServers'];
  final entry = servers is Map ? servers['phonebridge'] : null;
  if (entry is! Map) return false;
  final command = entry['command'];
  if (command is! String) return false;
  if (RegExp(
        r'(^|[/\\])PhoneBridgeMcp\.exe$',
        caseSensitive: false,
      ).hasMatch(command) ||
      command.endsWith('/phonebridge-mcp')) {
    return true;
  }
  final args = entry['args'];
  return command == '/bin/sh' &&
      args is List &&
      args.length == 1 &&
      args.first is String &&
      (args.first as String).endsWith('/phonebridge-mcp');
}

class PhoneBridgeApp extends StatefulWidget {
  const PhoneBridgeApp({
    required this.controller,
    this.initialChinese = false,
    this.onLanguageChanged,
    this.supportsLanPermission,
    this.chooseFile,
    super.key,
  });
  final DesktopController controller;
  final bool initialChinese;
  final ValueChanged<bool>? onLanguageChanged;
  final bool? supportsLanPermission;
  final Future<String?> Function()? chooseFile;
  @override
  State<PhoneBridgeApp> createState() => _PhoneBridgeAppState();
}

class _PhoneBridgeAppState extends State<PhoneBridgeApp> {
  late bool zh = widget.initialChinese;
  int page = 0;
  bool choosingFile = false;
  String? fileError;
  Future<void> sendFile() async {
    setState(() {
      choosingFile = true;
      fileError = null;
    });
    try {
      final path =
          await (widget.chooseFile?.call() ??
              const MethodChannel(
                'dev.phonebridge/files',
              ).invokeMethod<String>('chooseFile'));
      if (path != null && mounted) {
        await c.mutate('send-file', {'path': path});
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => fileError = t(
            '无法打开文件选择器，请重试',
            'Could not open the file chooser. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => choosingFile = false);
    }
  }

  String t(String cn, String en) => zh ? cn : en;
  DesktopController get c => widget.controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PhoneBridge',
    debugShowCheckedModeBanner: false,
    theme: phoneTheme(),
    home: AnimatedBuilder(
      animation: c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 820 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21;
          final titles = [
            t('连接', 'Connection'),
            t('接入 AI', 'Connect AI'),
            t('设置', 'Settings'),
          ];
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  if (wide)
                    SizedBox(
                      width: 228,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 28, 16, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _brand(),
                            const SizedBox(height: 42),
                            for (var i = 0; i < 3; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Material(
                                  color: page == i
                                      ? const Color(0xFFE4EDFC)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                  clipBehavior: Clip.antiAlias,
                                  child: ListTile(
                                    leading: Icon(
                                      [
                                        Icons.devices_rounded,
                                        Icons.auto_awesome_outlined,
                                        Icons.settings_outlined,
                                      ][i],
                                      color: page == i ? blue : muted,
                                    ),
                                    title: Text(
                                      titles[i],
                                      style: TextStyle(
                                        color: page == i ? blue : ink,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    selected: page == i,
                                    onTap: () => setState(() => page = i),
                                  ),
                                ),
                              ),
                            const Spacer(),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                t(
                                  '让手机，成为 AI 的双手。',
                                  'Your phone.\nIn reach of your AI.',
                                ),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: muted,
                                  height: 1.8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 28 : 20,
                        wide ? 40 : 24,
                        wide ? 40 : 20,
                        32,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 980),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!wide) ...[
                                _brand(),
                                const SizedBox(height: 28),
                              ],
                              Text(
                                titles[page],
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                [
                                  t(
                                    '连接你的手机，开启更多可能。',
                                    'Connect your phone. Open up new possibilities.',
                                  ),
                                  t(
                                    '把手机能力带到你熟悉的 AI 工具中。',
                                    'Bring your phone to the AI tools you already use.',
                                  ),
                                  t(
                                    '按照你的习惯，设置 PhoneBridge。',
                                    'Make PhoneBridge feel at home.',
                                  ),
                                ][page],
                              ),
                              const SizedBox(height: 28),
                              if (c.failure != null) ...[
                                _failure(context),
                                const SizedBox(height: 16),
                              ],
                              if (page == 0) ..._connection(context),
                              if (page == 1) ..._ai(context),
                              if (page == 2) ..._settings(context),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: page,
                    onDestinationSelected: (value) =>
                        setState(() => page = value),
                    destinations: [
                      for (var i = 0; i < 3; i++)
                        NavigationDestination(
                          icon: Icon(
                            [
                              Icons.devices_rounded,
                              Icons.auto_awesome_outlined,
                              Icons.settings_outlined,
                            ][i],
                          ),
                          label: titles[i],
                        ),
                    ],
                  ),
          );
        },
      ),
    ),
  );

  Widget _brand() => Row(
    children: [
      Image.asset('assets/brand/logo.png', width: 38, height: 38),
      const SizedBox(width: 10),
      const Flexible(
        child: Text(
          'PhoneBridge',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -.5,
            color: ink,
          ),
        ),
      ),
    ],
  );
  Widget card(Widget child) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: const EdgeInsets.all(28), child: child),
  );
  Widget label(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w500,
      color: ink,
    ),
  );

  Widget _failure(BuildContext context) => card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: Color(0xFF9B5B16)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                c.connectionFailed
                    ? t('暂时无法连接', 'Unable to connect')
                    : t('操作未完成', 'Action could not be completed'),
                style: const TextStyle(fontWeight: FontWeight.w500, color: ink),
              ),
            ),
            if (!c.connectionFailed)
              IconButton(
                onPressed: c.dismissActionFailure,
                tooltip: t('关闭提示', 'Dismiss message'),
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          (c.failure?.detail ==
                      'Copy PhoneBridge.app to Applications before starting the service.'
                  ? t(
                      '请先将 PhoneBridge.app 拖入「应用程序」文件夹，再重新打开。',
                      'Copy PhoneBridge.app to Applications, then reopen it.',
                    )
                  : c.failure?.detail) ??
              (c.failure?.code == 'runtime'
                  ? t(
                      '内置运行时缺失或无法启动，请重新安装完整的 PhoneBridge。',
                      'The bundled runtime is missing or cannot start. Reinstall the complete PhoneBridge application.',
                    )
                  : t(
                      '本地服务未响应。请确认电脑已连接私人网络，然后重试。',
                      'The local service did not respond. Check your private network, then try again.',
                    )),
        ),
        if (c.connectionFailed) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: c.starting || c.mutating ? null : c.start,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t('重试连接', 'Retry connection')),
          ),
        ],
      ],
    ),
  );

  List<Widget> _connection(BuildContext context) {
    final s = c.status;
    final connected =
        s?.connected == true && s?.unavailable != true && !c.connectionFailed;
    final title = c.starting
        ? t('正在准备连接', 'Getting ready')
        : c.connectionFailed
        ? t('连接已中断', 'Connection interrupted')
        : s?.unavailable == true
        ? t('服务暂不可用', 'Service unavailable')
        : connected
        ? t('手机已连接', 'Your phone is connected')
        : t('等待手机连接', 'Waiting for your phone');
    return [
      card(
        SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              ConnectionIllustration(
                connected: connected,
                semanticLabel: connected
                    ? t('手机与电脑已连接', 'Phone and computer connected')
                    : t('手机等待连接电脑', 'Waiting to connect your phone'),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                connected
                    ? t(
                        '一切就绪，前往「接入 AI」开始使用。',
                        'All set. Open Connect AI to get started.',
                      )
                    : t(
                        '手机和电脑连接同一 Wi-Fi，即可安全配对。',
                        'Keep your phone and computer on the same private Wi-Fi.',
                      ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (c.starting)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (connected)
                FilledButton.icon(
                  onPressed: () => setState(() => page = 1),
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text(t('接入 AI', 'Connect AI')),
                )
              else if (!c.connectionFailed &&
                  (s == null || s.unavailable || s.error != null))
                FilledButton.icon(
                  onPressed: c.mutating
                      ? null
                      : c.ready
                      ? () => c.mutate('start')
                      : c.start,
                  icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                  label: Text(
                    c.mutating
                        ? t('正在处理…', 'Working…')
                        : t('启动桌面服务', 'Start desktop service'),
                  ),
                ),
              if (s != null) ...[
                const SizedBox(height: 22),
                Text(
                  '${s.name}  ·  ${s.address}:${s.port}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
              if (s?.error != null) ...[
                const SizedBox(height: 14),
                Text(
                  s!.error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF9B5B16)),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      if (Platform.isMacOS || widget.chooseFile != null) ...[
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              label(t('发送文件到手机', 'Send a file to your phone')),
              const SizedBox(height: 10),
              Text(
                t(
                  '选择图片或文件，手机接收后可分享给微信、WhatsApp 等应用。每次一个文件，最大 50 MB。',
                  'Choose an image or file. Receive it on your phone, then share to WeChat, WhatsApp or another app. One file at a time, up to 50 MB.',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('send-file'),
                onPressed:
                    !connected ||
                        !c.ready ||
                        c.mutating ||
                        choosingFile ||
                        [
                          'uploading',
                          'pending',
                          'receiving',
                        ].contains(s?.transfer?['state'])
                    ? null
                    : sendFile,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: Text(
                  choosingFile || c.mutating
                      ? t('正在处理…', 'Working…')
                      : t('选择文件', 'Choose file'),
                ),
              ),
              if (!connected)
                Text(
                  t('连接手机后即可发送', 'Connect your phone to send files'),
                  style: const TextStyle(fontSize: 12),
                ),
              if (s?.transfer != null) ...[
                const SizedBox(height: 12),
                Text(s!.transfer!['name'] as String? ?? ''),
                Text(switch (s.transfer!['state']) {
                  'pending' => t(
                    '等待手机接收 · 请打开手机 PhoneBridge',
                    'Waiting for receipt · Open PhoneBridge on your phone',
                  ),
                  'receiving' => t(
                    '手机正在接收并校验',
                    'Phone is receiving and verifying',
                  ),
                  'received' => t(
                    '手机已接收，可在手机上点分享',
                    'Received on your phone. Tap Share there.',
                  ),
                  'declined' => t('手机已拒绝接收', 'Declined on the phone'),
                  'expired' => t(
                    '文件已过期，请重新选择发送',
                    'Expired. Choose the file again to send.',
                  ),
                  'cancelled' => t(
                    '连接已中断，请确认手机状态',
                    'Connection interrupted. Check the phone.',
                  ),
                  'uploading' => t('正在传输…', 'Uploading…'),
                  _ => t(
                    '传输失败，请确认手机状态后重试',
                    'Transfer failed. Check the phone before retrying.',
                  ),
                }, style: const TextStyle(fontSize: 12)),
              ],
              if (fileError != null)
                Text(
                  fileError!,
                  style: const TextStyle(color: Color(0xFFA34726)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
      if (!connected &&
          s?.unavailable == false &&
          s?.qr != null &&
          !c.connectionFailed)
        card(
          LayoutBuilder(
            builder: (context, box) {
              final explanation = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(t('扫码连接这台电脑', 'Scan to connect')),
                  const SizedBox(height: 12),
                  Text(
                    t(
                      '打开手机上的 PhoneBridge，点击首页右上角「扫一扫」（旧版可点电脑卡片 → 配对另一台电脑 → 扫描电脑配对码）。配对后，你可以随时在手机上暂停控制。',
                      'Open PhoneBridge on your phone and tap Scan at the top right. On older versions, tap the computer card → Pair another computer → Scan computer pairing code. You can pause control on your phone at any time.',
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    t(
                      '01  打开手机应用\n02  扫描二维码\n03  确认连接',
                      '01  Open the phone app\n02  Scan this QR code\n03  Confirm the connection',
                    ),
                    style: const TextStyle(height: 2, color: ink),
                  ),
                ],
              );
              final qr = Semantics(
                label: t('手机配对二维码', 'Phone pairing QR code'),
                child: Image.memory(
                  s!.qr!,
                  width: 184,
                  height: 184,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 184,
                    height: 184,
                    child: Icon(Icons.qr_code_rounded, size: 96, color: muted),
                  ),
                ),
              );
              return box.maxWidth > 480
                  ? Row(
                      children: [
                        Expanded(child: explanation),
                        const SizedBox(width: 24),
                        qr,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        explanation,
                        const SizedBox(height: 20),
                        Center(child: qr),
                      ],
                    );
            },
          ),
        ),
      if (connected)
        card(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined, color: blue),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label(t('控制权，始终在你手中', 'Always in your control')),
                    const SizedBox(height: 8),
                    Text(
                      t(
                        '配对信息保存在本机。关闭此窗口后，已安装的后台服务会继续运行。',
                        'Pairing stays on this computer. The installed background service keeps running when you close this window.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _ai(BuildContext context) {
    final config = c.status?.mcpConfiguration;
    final stable = isStableMcpConfiguration(config);
    return [
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.auto_awesome_outlined, color: blue, size: 32),
            const SizedBox(height: 20),
            label(t('连接你的 AI 助手', 'Connect your AI assistant')),
            const SizedBox(height: 12),
            Text(
              t(
                '将下方配置添加到支持 MCP 的 AI 客户端。保存后重新连接客户端，即可发现 PhoneBridge 的手机工具。',
                'Add the configuration below to an AI client that supports MCP. Save it and reconnect the client to discover PhoneBridge phone tools.',
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: canvas,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SelectableText(
                config == null
                    ? t(
                        '本地服务准备好后，配置会显示在这里。',
                        'Your configuration will appear when the local service is ready.',
                      )
                    : const JsonEncoder.withIndent('  ').convert(config),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.7,
                  color: ink,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: config == null
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text: const JsonEncoder.withIndent(
                            '  ',
                          ).convert(config),
                        ),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              t('MCP 配置已复制', 'MCP configuration copied'),
                            ),
                          ),
                        );
                      }
                    },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t('复制 MCP 配置', 'Copy MCP configuration')),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label(t('升级后，无需重新配对', 'Keep your pairing after upgrades')),
            const SizedBox(height: 10),
            Text(
              stable
                  ? t(
                      '配置使用固定入口。升级 PhoneBridge 后，重新连接 AI 客户端即可使用新版本。已运行的 AI 会话会在重连前保持原版本。',
                      'The configuration uses a stable entry point. Reconnect your AI client after a PhoneBridge upgrade to use the new version. Existing sessions stay on their current version until reconnected.',
                    )
                  : t(
                      '安装桌面客户端后，即可使用随版本升级自动更新的 MCP 固定入口。如果你之前添加过旧版配置，请在安装后重新复制一次。',
                      'Install the desktop client to enable the stable MCP entry point that follows upgrades. If you previously added an older configuration, copy it again once after installation.',
                    ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _settings(BuildContext context) {
    final s = c.status;
    final networks = {
      for (final n in s?.networks ?? <({String address, String name})>[])
        n.address: n.name,
    };
    return [
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label(t('偏好设置', 'Preferences')),
            const SizedBox(height: 22),
            Row(
              children: [
                const Icon(Icons.language_rounded, color: muted),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    t('语言', 'Language'),
                    style: const TextStyle(color: ink),
                  ),
                ),
                DropdownButton<bool>(
                  key: const Key('language'),
                  value: zh,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: true, child: Text('中文')),
                    DropdownMenuItem(value: false, child: Text('English')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => zh = v);
                      widget.onLanguageChanged?.call(v);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 22),
            label(t('电脑网络', 'Computer network')),
            const SizedBox(height: 8),
            Text(
              t(
                '使用手机所在的私人 Wi-Fi 或以太网。切换网络前，请先断开手机。',
                'Use the private Wi-Fi or Ethernet network your phone is on. Disconnect the phone before switching.',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'network-${s?.address}-${networks.keys.join()}-${c.mutating}',
              ),
              initialValue: networks.containsKey(s?.address)
                  ? s?.address
                  : null,
              isExpanded: true,
              hint: Text(t('选择网络', 'Choose a network')),
              items: [
                for (final n in networks.entries)
                  DropdownMenuItem(
                    value: n.key,
                    child: Text(
                      '${n.value} · ${n.key}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: !c.ready || c.mutating || s?.connected == true
                  ? null
                  : (value) {
                      if (value != null && value != s?.address) {
                        c.mutate('network', {'address': value});
                      }
                    },
            ),
            if (s != null && !networks.containsKey(s.address)) ...[
              const SizedBox(height: 10),
              Text(
                '${t('已保存的网络不可用', 'Saved network unavailable')}: ${s.address}',
              ),
            ],
            if (widget.supportsLanPermission ?? Platform.isWindows) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: !c.ready || c.mutating
                    ? null
                    : () => c.mutate('allow-lan'),
                icon: const Icon(Icons.wifi_rounded, size: 18),
                label: Text(t('允许局域网连接', 'Allow LAN connections')),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 20),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _brand(),
            const SizedBox(height: 18),
            Text(
              t(
                '让 AI 看见手机，也让你始终掌控每一步。',
                'Let AI work with your phone, while you stay in control.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              c.installedVersion == null
                  ? t('开发版', 'Development build')
                  : t(
                      '版本 ${c.installedVersion}',
                      'Version ${c.installedVersion}',
                    ),
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
      ),
    ];
  }
}
