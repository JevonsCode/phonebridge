import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'backend.dart';
import 'design.dart';
import 'tray.dart';

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
    this.initialTrayIcon = true,
    this.onTrayIconChanged,
    super.key,
  });
  final DesktopController controller;
  final bool initialChinese;
  final ValueChanged<bool>? onLanguageChanged;
  final bool? supportsLanPermission;
  final Future<String?> Function()? chooseFile;
  final bool initialTrayIcon;

  /// Shows the tray setting; the host applies and persists the choice.
  final ValueChanged<bool>? onTrayIconChanged;
  @override
  State<PhoneBridgeApp> createState() => _PhoneBridgeAppState();
}

class _PhoneBridgeAppState extends State<PhoneBridgeApp> {
  late bool zh = widget.initialChinese;
  late bool trayIcon = widget.initialTrayIcon;
  int page = 0;
  bool choosingFile = false;
  bool get pairingAvailable =>
      c.status?.unavailable == false &&
      c.status?.qr != null &&
      !c.connectionFailed;

  Future<void> showPairingQr(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: c,
      builder: (context, _) => AlertDialog(
        key: const Key('phone-pairing-dialog'),
        constraints: const BoxConstraints(maxWidth: 440),
        title: Row(
          children: [
            Expanded(child: Text(t('扫码连接这台电脑', 'Scan to connect'))),
            IconButton(
              tooltip: t('关闭', 'Close'),
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pairingAvailable)
                _pairingImage(c.status!, size: 240)
              else
                Text(
                  t(
                    '连接服务暂不可用，请关闭后重试。',
                    'Connection service is unavailable. Close and try again.',
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                t(
                  '打开手机上的 PhoneBridge，点击首页右上角「扫一扫」。',
                  'Open PhoneBridge on your phone and tap Scan at the top right.',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                t(
                  '可继续连接其他手机，已连接的手机不受影响。',
                  'You can connect more phones. Existing phones stay connected.',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _pairingImage(DesktopStatus status, {double size = 184}) => Semantics(
    label: t('手机配对二维码', 'Phone pairing QR code'),
    child: Image.memory(
      status.qr!,
      width: size,
      height: size,
      errorBuilder: (_, _, _) => SizedBox(
        width: size,
        height: size,
        child: const Icon(Icons.qr_code_rounded, size: 96, color: muted),
      ),
    ),
  );

  String? fileError;
  String? fileDeviceId;
  Future<void> sendFile() async {
    // Capture the user's target before the native chooser opens. Polling may
    // change the online list, but must never redirect an in-flight choice.
    final target = fileDeviceId;
    final targetDevice = c.status?.devices
        .where((d) => d.id == target)
        .firstOrNull;
    if (target == null ||
        targetDevice == null ||
        !targetDevice.connected ||
        targetDevice.busy) {
      return;
    }
    final connectionId = targetDevice.connectionId;
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
        final current = c.status?.devices
            .where((d) => d.id == target)
            .firstOrNull;
        if (connectionId != null &&
            (current?.connectionId != connectionId ||
                current?.connected != true)) {
          setState(
            () => fileError = t(
              '手机连接已变化，请确认接收手机后重试',
              'The phone connection changed. Check the receiving phone and try again.',
            ),
          );
          return;
        }
        await c.mutate('send-file', {
          'path': path,
          'deviceId': target,
          'connectionId': ?connectionId,
        });
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
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 20,
                                runSpacing: 12,
                                children: [
                                  Text(
                                    titles[page],
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineMedium,
                                  ),
                                  if (page == 0)
                                    OutlinedButton.icon(
                                      key: const Key('show-pairing-qr'),
                                      onPressed: pairingAvailable
                                          ? () => showPairingQr(context)
                                          : null,
                                      icon: const Icon(
                                        Icons.qr_code_rounded,
                                        size: 18,
                                      ),
                                      label: Text(t('显示二维码', 'Show QR code')),
                                    ),
                                ],
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
    final title = connectionTitle(c, zh);
    final devices = s?.devices ?? <DesktopDevice>[];
    final selectedDevice = devices
        .where((d) => d.id == fileDeviceId)
        .firstOrNull;
    final transfer =
        selectedDevice?.transfer ??
        (selectedDevice?.connected == true &&
                devices.where((d) => d.connected).length == 1
            ? s?.transfer
            : null);
    String deviceLabel(DesktopDevice device) =>
        devices.where((d) => d.displayName == device.displayName).length > 1
        ? '${device.displayName} (${device.id.length > 8 ? device.id.substring(0, 8) : device.id})'
        : device.displayName;
    final targetReady = devices.any(
      (d) => d.id == fileDeviceId && d.connected && !d.busy,
    );
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
      if (devices.isNotEmpty) ...[
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label(t('手机设备', 'Phones')),
              const SizedBox(height: 12),
              for (final device in devices)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smartphone_rounded,
                        color: device.connected ? blue : muted,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.displayName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              device.id.length > 12
                                  ? device.id.substring(0, 12)
                                  : device.id,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              !device.connected
                                  ? t('离线', 'Offline')
                                  : device.busy
                                  ? t('使用中', 'Busy')
                                  : t('在线', 'Online'),
                              key: Key('device-state-${device.id}'),
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (device.readOnly)
                              Text(
                                t('仅观察', 'Read only'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            if (device.controlOwnerName?.isNotEmpty == true)
                              Text(
                                t(
                                  '由${device.controlOwnerName}控制',
                                  'Controlled by ${device.controlOwnerName}',
                                ),
                                style: const TextStyle(fontSize: 12),
                              ),
                            if (device.waitingCount > 0)
                              Text(
                                '${t('等待控制', 'Waiting for control')} · ${device.waitingCount}',
                                key: Key('device-waiting-${device.id}'),
                                style: const TextStyle(fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
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
              DropdownButtonFormField<String>(
                key: const Key('file-device-target'),
                initialValue: fileDeviceId,
                isExpanded: true,
                borderRadius: BorderRadius.circular(14),
                decoration: InputDecoration(
                  labelText: t('接收手机', 'Receiving phone'),
                ),
                hint: Text(t('请选择接收手机', 'Choose a receiving phone')),
                items: [
                  if (fileDeviceId != null &&
                      !devices.any((d) => d.id == fileDeviceId))
                    DropdownMenuItem(
                      value: fileDeviceId,
                      child: Text('$fileDeviceId · ${t('离线', 'Offline')}'),
                    ),
                  for (final device in devices)
                    DropdownMenuItem(
                      value: device.id,
                      child: Text(
                        '${deviceLabel(device)} · ${!device.connected
                            ? t('离线', 'Offline')
                            : device.busy
                            ? t('使用中', 'Busy')
                            : device.readOnly
                            ? t('仅观察', 'Read only')
                            : t('在线', 'Online')}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: choosingFile || c.mutating
                    ? null
                    : (id) => setState(() => fileDeviceId = id),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('send-file'),
                onPressed:
                    !connected ||
                        !targetReady ||
                        !c.ready ||
                        c.mutating ||
                        choosingFile ||
                        [
                          'uploading',
                          'pending',
                          'receiving',
                        ].contains(transfer?['state'])
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
              if (transfer != null) ...[
                const SizedBox(height: 12),
                Text(transfer['name'] as String? ?? ''),
                Text(switch (transfer['state']) {
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
      if (pairingAvailable && !connected)
        card(
          LayoutBuilder(
            key: const Key('phone-pairing-panel'),
            builder: (context, box) {
              final explanation = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(
                    connected
                        ? t('添加另一台手机', 'Add another phone')
                        : t('扫码连接这台电脑', 'Scan to connect'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    connected
                        ? t(
                            '用另一台手机上的 PhoneBridge 扫码连接，已连接的手机不受影响。',
                            'Scan with PhoneBridge on another phone. Existing phones stay connected.',
                          )
                        : t(
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
              final qr = _pairingImage(s!);
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
            if (widget.onTrayIconChanged != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.push_pin_outlined, color: muted),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          Platform.isMacOS
                              ? t('在菜单栏显示图标', 'Show icon in the menu bar')
                              : t('在任务栏显示图标', 'Show icon in the system tray'),
                          style: const TextStyle(color: ink),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t(
                            '开启后，关闭窗口会收起到图标，点击图标即可找回配对二维码。',
                            'When on, closing the window keeps PhoneBridge in the icon. Click it to get back to the pairing code.',
                          ),
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Switch(
                    key: const Key('tray-icon'),
                    value: trayIcon,
                    onChanged: (v) {
                      setState(() => trayIcon = v);
                      widget.onTrayIconChanged?.call(v);
                    },
                  ),
                ],
              ),
            ],
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
