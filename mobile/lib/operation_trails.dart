import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'design.dart';

/// Independent display preference; does not call connection or action methods.
class OperationTrailSetting extends StatefulWidget {
  const OperationTrailSetting({super.key});

  @override
  State<OperationTrailSetting> createState() => _OperationTrailSettingState();
}

class _OperationTrailSettingState extends State<OperationTrailSetting> {
  static const _channel = MethodChannel('dev.phonebridge/control');
  bool _enabled = true;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await _channel.invokeMethod<bool>('getShowOperationTrails');
      if (mounted && value != null) setState(() => _enabled = value);
    } on PlatformException {
      if (mounted) setState(() => _error = '无法读取操作轨迹设置，请重试');
    } on MissingPluginException {
      if (mounted) setState(() => _error = '无法读取操作轨迹设置，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(bool value) async {
    if (_loading || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _channel.invokeMethod<void>('setShowOperationTrails', {
        'enabled': value,
      });
      if (mounted) setState(() => _enabled = value);
    } on PlatformException {
      if (mounted) setState(() => _error = '无法保存操作轨迹设置，请重试');
    } on MissingPluginException {
      if (mounted) setState(() => _error = '无法保存操作轨迹设置，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const Key('show-operation-trails'),
    contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
    value: _enabled,
    onChanged: _loading || _saving ? null : _select,
    title: Text(
      tr(context, '显示操作轨迹'),
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
    ),
    subtitle: Text(
      tr(context, _error ?? '显示 AI 点击与滑动的位置'),
      style: TextStyle(
        fontSize: 12,
        color: _error == null ? muted : Theme.of(context).colorScheme.error,
        height: 1.6,
      ),
    ),
  );
}
