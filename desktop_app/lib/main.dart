import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'backend.dart';
import 'tray.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final controller = DesktopController(
    installedVersion: await readInstalledVersion(),
  );
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
  final trayPreference = TrayPreference(
    home == null ? null : File('$home/.phonebridge/desktop-tray-icon'),
  );
  var chinese = Platform.localeName.startsWith('zh');
  try {
    final saved = await languageFile?.readAsString();
    if (saved == 'zh' || saved == 'en') chinese = saved == 'zh';
  } catch (_) {}
  final trayIcon = await trayPreference.load();
  var quitting = false;
  late final DesktopTray tray;
  Future<void> quit() async {
    if (quitting) return;
    quitting = true;
    await tray.setVisible(false);
    await controller.shutdown();
    await windowManager.destroy();
  }

  tray = DesktopTray(
    controller: controller,
    chinese: chinese,
    showWindow: showMainWindow,
    quit: quit,
  );
  windowManager.addListener(_CloseListener(tray, quit));
  await windowManager.setPreventClose(true);
  runApp(
    PhoneBridgeApp(
      controller: controller,
      initialChinese: chinese,
      onLanguageChanged: (zh) async {
        tray.chinese = zh;
        try {
          await languageFile?.parent.create(recursive: true);
          await languageFile?.writeAsString(zh ? 'zh' : 'en', flush: true);
        } catch (_) {}
      },
      initialTrayIcon: trayIcon,
      onTrayIconChanged: (enabled) {
        unawaited(tray.setVisible(enabled));
        unawaited(trayPreference.save(enabled));
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
  if (trayIcon) unawaited(tray.setVisible(true));
  unawaited(controller.start());
}

Future<void> showMainWindow() async {
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
}

/// With the tray icon on, closing only hides the window; the dashboard keeps
/// polling so the tray status stays current. Otherwise closing quits.
class _CloseListener extends WindowListener {
  _CloseListener(this.tray, this.quit);
  final DesktopTray tray;
  final Future<void> Function() quit;
  @override
  void onWindowClose() async {
    if (tray.visible) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }
}
