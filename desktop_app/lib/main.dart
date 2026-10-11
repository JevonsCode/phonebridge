import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'backend.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final controller = DesktopController();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans SC',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  const MethodChannel('phonebridge/lifecycle').setMethodCallHandler((
    call,
  ) async {
    if (call.method == 'shutdown') await controller.shutdown();
  });
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final languageFile = home == null
      ? null
      : File('$home/.phonebridge/desktop-language');
  var chinese = Platform.localeName.startsWith('zh');
  try {
    final saved = await languageFile?.readAsString();
    if (saved == 'zh' || saved == 'en') chinese = saved == 'zh';
  } catch (_) {}
  windowManager.addListener(_CloseListener(controller));
  await windowManager.setPreventClose(true);
  runApp(
    PhoneBridgeApp(
      controller: controller,
      initialChinese: chinese,
      onLanguageChanged: (zh) async {
        try {
          await languageFile?.parent.create(recursive: true);
          await languageFile?.writeAsString(zh ? 'zh' : 'en', flush: true);
        } catch (_) {}
      },
    ),
  );
  unawaited(
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1120, 800),
        minimumSize: Size(400, 520),
        center: true,
        title: 'PhoneBridge',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    ),
  );
  unawaited(controller.start());
}

class _CloseListener extends WindowListener {
  _CloseListener(this.controller);
  final DesktopController controller;
  bool closing = false;
  @override
  void onWindowClose() async {
    if (closing) return;
    closing = true;
    await controller.shutdown();
    await windowManager.destroy();
  }
}
