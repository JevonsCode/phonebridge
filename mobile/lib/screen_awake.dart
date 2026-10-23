import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'design.dart';

/// Persists independently of connection and control consent.
class ScreenAwakeSetting extends StatefulWidget {
  const ScreenAwakeSetting({super.key});
  @override
  State<ScreenAwakeSetting> createState() => _ScreenAwakeSettingState();
}

class _ScreenAwakeSettingState extends State<ScreenAwakeSetting> {
  static const channel = MethodChannel('dev.phonebridge/control');
  static const labels = {'off': '关闭', 'controlling': '控制期间', 'always': '始终'};
  String mode = 'controlling';
  String? error;
  bool loading = true, saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await channel.invokeMethod<String>('getScreenAwakeMode');
      if (mounted && labels.containsKey(value)) setState(() => mode = value!);
    } on PlatformException {
      if (mounted) setState(() => error = '无法读取屏幕常亮设置，请重试');
    } on MissingPluginException {
      if (mounted) setState(() => error = '无法读取屏幕常亮设置，请重试');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> select(String value) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await channel.invokeMethod<Object?>('setScreenAwakeMode', {
        'mode': value,
      });
      if (mounted) setState(() => mode = value);
    } on PlatformException {
      if (mounted) setState(() => error = '无法保存屏幕常亮设置，请重试');
    } on MissingPluginException {
      if (mounted) setState(() => error = '无法保存屏幕常亮设置，请重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> choose() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(context, '保持屏幕常亮'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  tr(
                    context,
                    '控制期间仅在 AI 正在控制时生效；始终在 PhoneBridge 无障碍服务运行时生效。手动息屏或锁屏优先，不会唤醒或解锁手机。',
                  ),
                  style: const TextStyle(color: muted, height: 1.6),
                ),
                const SizedBox(height: 12),
                for (final entry in labels.entries)
                  Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      key: Key('screen-awake-${entry.key}'),
                      title: Text(tr(context, entry.value)),
                      trailing: mode == entry.key
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(context, entry.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (choice != null && mounted) await select(choice);
  }

  @override
  Widget build(BuildContext context) => SettingsRow(
    key: const Key('screen-awake-setting'),
    icon: Icons.light_mode_outlined,
    title: '保持屏幕常亮',
    subtitle: error ?? labels[mode]!,
    onTap: loading || saving
        ? null
        : error != null && loading == false
        ? () async {
            await load();
            if (mounted && error == null) await choose();
          }
        : choose,
  );
}
