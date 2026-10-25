import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'design.dart';
import 'automation_settings.dart';

class FileReceiveSetting extends StatefulWidget {
  const FileReceiveSetting({super.key});

  @override
  State<FileReceiveSetting> createState() => _FileReceiveSettingState();
}

class _FileReceiveSettingState extends State<FileReceiveSetting> {
  static const _channel = MethodChannel('dev.phonebridge/control');
  bool _enabled = true;
  bool _known = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<bool> _read() async {
    final value = await _channel.invokeMethod<bool>(
      'getAutoReceiveFilesEnabled',
    );
    if (value == null) throw PlatformException(code: 'UNAVAILABLE');
    return value;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await _read();
      if (mounted) {
        setState(() {
          _enabled = value;
          _known = true;
        });
      }
    } on PlatformException {
      _readFailed();
    } on MissingPluginException {
      _readFailed();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _readFailed() {
    if (!mounted) return;
    setState(() {
      _known = false;
      _error = '无法读取自动接收设置，请重试';
    });
  }

  Future<void> _select(bool value) async {
    if (_loading || _saving || !_known) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    String? failure;
    try {
      await _channel.invokeMethod<void>('setAutoReceiveFilesEnabled', {
        'enabled': value,
      });
    } on PlatformException {
      failure = '无法保存自动接收设置，请重试';
    } on MissingPluginException {
      failure = '无法保存自动接收设置，请重试';
    }
    // A lost reply may follow a successful save. Always display the native value.
    try {
      final stored = await _read();
      if (mounted) {
        setState(() {
          _enabled = stored;
          _known = true;
          _error = failure ?? (stored == value ? null : '无法保存自动接收设置，请重试');
        });
      }
    } on PlatformException {
      _readFailed();
    } on MissingPluginException {
      _readFailed();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ProtectedControl(
    name: 'auto-receive',
    child: SwitchListTile(
      key: const Key('auto-receive-files'),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      value: _enabled,
      onChanged: _loading || _saving || !_known ? null : _select,
      title: Text(
        tr(context, '自动接收电脑文件'),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(context, _error ?? '已配对电脑发来的文件直接保存到手机'),
            style: TextStyle(
              fontSize: 12,
              color: _error == null
                  ? muted
                  : Theme.of(context).colorScheme.error,
              height: 1.6,
            ),
          ),
          if (_error != null)
            TextButton(
              key: const Key('retry-auto-receive-files'),
              onPressed: _loading || _saving ? null : _load,
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: Text(tr(context, '重试')),
            ),
        ],
      ),
    ),
  );
}
