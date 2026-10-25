import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'design.dart';

/// Identifies only the connection-changing row, never its surrounding screen.
class ProtectedControl extends StatelessWidget {
  const ProtectedControl({required this.name, required this.child, super.key});
  final String name;
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    identifier: 'phonebridge.protected.$name',
    container: true,
    explicitChildNodes: true,
    child: child,
  );
}

class AutomationSetting extends StatefulWidget {
  const AutomationSetting({
    required this.preference,
    required this.title,
    required this.subtitle,
    super.key,
  });
  final String preference, title, subtitle;
  @override
  State<AutomationSetting> createState() => _AutomationSettingState();
}

class _AutomationSettingState extends State<AutomationSetting> {
  static const channel = MethodChannel('dev.phonebridge/control');
  bool enabled = true, known = false, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final value = await channel.invokeMethod<bool>('get${widget.preference}');
      if (value == null) throw PlatformException(code: 'UNAVAILABLE');
      if (mounted) {
        setState(() {
          enabled = value;
          known = true;
          error = null;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          known = false;
          error = '无法读取设置，请重试';
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          known = false;
          error = '无法读取设置，请重试';
        });
      }
    }
  }

  Future<void> save(bool value) async {
    setState(() {
      busy = true;
      error = null;
    });
    var failed = false;
    try {
      await channel.invokeMethod<void>('set${widget.preference}', {
        'enabled': value,
      });
    } on PlatformException {
      failed = true;
    } on MissingPluginException {
      failed = true;
    }
    await load();
    if (mounted) {
      setState(() {
        busy = false;
        if (failed || (known && enabled != value)) error = '无法保存设置，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => ProtectedControl(
    name: widget.preference,
    child: SwitchListTile(
      key: Key(widget.preference),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      value: enabled,
      onChanged: known && !busy ? save : null,
      title: Text(
        tr(context, widget.title),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(context, error ?? widget.subtitle),
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: error == null
                  ? muted
                  : Theme.of(context).colorScheme.error,
            ),
          ),
          if (error != null)
            TextButton(
              onPressed: busy ? null : load,
              child: Text(tr(context, '重试')),
            ),
        ],
      ),
    ),
  );
}
