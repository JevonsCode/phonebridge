import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'playground.dart';

void main() => runApp(const PhoneBridgeApp());

class PhoneBridgeApp extends StatelessWidget {
  const PhoneBridgeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PhoneBridge',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFBD532D),
        surface: const Color(0xFFFAF8F3),
      ),
      scaffoldBackgroundColor: const Color(0xFFFAF8F3),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
    home: const ConnectionPage(),
  );
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});
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
  String? error;
  bool get connected => status['connected'] == true;
  bool get connecting => status['connecting'] == true;
  bool get enabled => status['accessibilityEnabled'] == true;

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
        setState(() => status = next ?? {});
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
      if (method == 'disconnect' || method == 'connect') token.clear();
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
    if (token.text.trim().length < 32) {
      setState(() => error = '请输入电脑端生成的完整配对密钥（至少 32 个字符）');
      return;
    }
    await perform('requestNotificationPermission');
    if (!mounted || error != null) return;
    await perform('connect', {
      'endpoint': endpoint.text.trim(),
      'token': token.text.trim(),
      'allowInsecureLocal': insecureLocal,
      'packages': packages.text
          .split(RegExp(r'[\s,;]+'))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final nativeError = status['lastError'] as String?;
    final message =
        error ?? (nativeError?.isNotEmpty == true ? nativeError : null);
    return Scaffold(
      bottomNavigationBar: connected || connecting
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.tonalIcon(
                  key: const Key('stop'),
                  onPressed: busy ? null : () => perform('disconnect'),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('立即停止并断开'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
              ),
            )
          : null,
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.device_hub_rounded),
            SizedBox(width: 10),
            Text('PhoneBridge'),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Chip(label: Text('开源预览版')),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
              children: [
                Text(
                  '让 AI 帮你用手机',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '你决定何时连接、能看哪些应用，以及是否允许操作。',
                  style: TextStyle(fontSize: 16, height: 1.6),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF253B35),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        connected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: const Color(0xFFB7DBBC),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connected
                                  ? (status['actionsEnabled'] == true
                                        ? '已连接 · 可操作'
                                        : '已连接 · 只读')
                                  : connecting
                                  ? '正在连接…'
                                  : '由你开启，随时停止',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              connected
                                  ? '停止后，电脑将立即失去访问权限'
                                  : enabled
                                  ? '无障碍已就绪，等待与电脑配对'
                                  : '完成下面的授权与配对即可开始',
                              style: const TextStyle(
                                color: Color(0xFFCAD8D1),
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(message, key: const Key('error')),
                  ),
                ],
                const SizedBox(height: 20),
                section('01', '授权给你的手机助手', [
                  const Text(
                    '无障碍服务用于读取界面文字、截图、点击、滑动和输入。你需要在系统设置中亲自开启它。',
                    style: TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform('openAccessibilitySettings'),
                    icon: Icon(
                      enabled
                          ? Icons.check_circle_outline
                          : Icons.accessibility_new,
                    ),
                    label: Text(enabled ? '已开启 · 查看无障碍设置' : '打开无障碍设置'),
                  ),
                ]),
                const SizedBox(height: 14),
                section('02', '连接你的电脑', [
                  const Text(
                    '先按项目 README 启动电脑端服务，再填入设备地址和配对密钥。密钥只保存在当前会话内。',
                    style: TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: endpoint,
                    enabled: !connected && !connecting,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '设备连接地址',
                      helperText: 'USB 默认地址；局域网时填写电脑的私有 IP',
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 16),
                  if (!connected)
                    TextField(
                      controller: token,
                      enabled: !connecting,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '配对密钥',
                        prefixIcon: Icon(Icons.key_rounded),
                      ),
                    ),
                  if (!connected) const SizedBox(height: 16),
                  TextField(
                    controller: packages,
                    enabled: !connected && !connecting,
                    minLines: 2,
                    maxLines: 5,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '允许访问的应用包名',
                      helperText: '每行一个；默认仅此应用和微信',
                    ),
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: insecureLocal,
                    onChanged: connected || connecting
                        ? null
                        : (v) => setState(() => insecureLocal = v ?? false),
                    title: const Text('允许本次使用本地明文连接'),
                    subtitle: const Text(
                      '仅用于 USB 回环或可信私有网络。网络内其他人可能看到传输内容；跨网络请使用 WSS。',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  CheckboxListTile(
                    key: const Key('consent'),
                    contentPadding: EdgeInsets.zero,
                    value: consent,
                    onChanged: connected || connecting
                        ? null
                        : (v) => setState(() => consent = v ?? false),
                    title: const Text('我同意把允许应用的界面内容发送给配对的电脑'),
                    subtitle: const Text(
                      '连接的 AI 可能将内容发送给其模型服务商。请确认该 AI 的数据设置；PhoneBridge 不自建云端、不收集遥测。',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 8),
                  if (!connected && !connecting)
                    FilledButton.icon(
                      key: const Key('connect'),
                      onPressed: busy || !consent || !enabled ? null : connect,
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('连接 · 默认只读'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                ]),
                const SizedBox(height: 14),
                section('03', '由你决定是否允许操作', [
                  SwitchListTile(
                    key: const Key('actions'),
                    contentPadding: EdgeInsets.zero,
                    value: status['actionsEnabled'] == true,
                    onChanged: connected && !busy
                        ? (v) => perform('setActionsEnabled', {'enabled': v})
                        : null,
                    title: const Text('允许 AI 点击和输入'),
                    subtitle: const Text(
                      '仅对本次连接有效。开启后，AI 能在允许的应用里操作；发送、购买等动作请先在 AI 客户端确认。',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PlaygroundPage(),
                      ),
                    ),
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('打开操作练习场'),
                  ),
                ]),
                const SizedBox(height: 20),
                const Text(
                  '保持手机解锁。分屏、键盘或其他悬浮窗口可能阻止截图与操作；遇到限制时先回到目标应用。系统受保护内容无法读取。',
                  style: TextStyle(color: Color(0xFF68645F), height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget section(String number, String title, List<Widget> children) =>
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE9E4DA)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  number,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      );
}
