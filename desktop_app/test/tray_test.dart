import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/app.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'package:phonebridge_desktop/tray.dart';
import 'backend_test.dart' show statusData;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tray_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> fromPlatform(String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
  List<Map> menu() =>
      ((calls.lastWhere((c) => c.method == 'setContextMenu').arguments
                  as Map)['menu']
              as Map)['items']
          .cast<Map>();
  Map item(String key) => menu().firstWhere((i) => i['key'] == key);

  group('tray preference', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pb-tray-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('defaults on and remembers the choice', () async {
      final preference = TrayPreference(
        File('${dir.path}/a/desktop-tray-icon'),
      );
      expect(await preference.load(), true);
      await preference.save(false);
      expect(await preference.load(), false);
      expect(
        await TrayPreference(File('${dir.path}/a/desktop-tray-icon')).load(),
        false,
      );
      await preference.save(true);
      expect(await preference.load(), true);
      expect(await const TrayPreference(null).load(), true);
    });
  });

  test('icon shows status, follows the connection and hides', () async {
    final c = DesktopController()
      ..status = DesktopStatus({...statusData(), 'connected': false});
    addTearDown(c.dispose);
    var shown = 0, quits = 0;
    final tray = DesktopTray(
      controller: c,
      chinese: false,
      showWindow: () async => shown++,
      quit: () async => quits++,
    );
    await tray.setVisible(true);
    expect(tray.visible, true);
    expect(calls.first.method, 'setIcon');
    expect(
      (calls.first.arguments as Map)['iconPath'],
      endsWith(Platform.isWindows ? 'tray.ico' : 'logo.png'),
    );
    expect(item('open')['label'], 'Open PhoneBridge');
    expect(item('status')['label'], 'Status: Waiting for your phone');
    expect(item('status')['disabled'], true);
    expect(
      item('quit')['label'],
      'Quit window (background service keeps running)',
    );

    calls.clear();
    c.changed();
    await tray.setVisible(true);
    expect(calls, isEmpty, reason: 'unchanged status does not rebuild menu');

    c.status = DesktopStatus(statusData());
    c.changed();
    await tray.setVisible(true);
    expect(item('status')['label'], 'Status: Your phone is connected');
    expect(
      calls.lastWhere((c) => c.method == 'setToolTip').arguments['toolTip'],
      'PhoneBridge · Your phone is connected',
    );

    tray.chinese = true;
    await tray.setVisible(true);
    expect(item('open')['label'], '打开 PhoneBridge');
    expect(item('status')['label'], '状态：手机已连接');
    expect(item('quit')['label'], '退出窗口（后台服务继续运行）');

    await fromPlatform('onTrayIconMouseDown');
    expect(shown, 1);
    await fromPlatform('onTrayMenuItemClick', {'id': item('open')['id']});
    expect(shown, 2);
    await fromPlatform('onTrayMenuItemClick', {'id': item('quit')['id']});
    expect(quits, 1);
    await fromPlatform('onTrayIconRightMouseDown');
    expect(calls.last.method, 'popUpContextMenu');

    calls.clear();
    await tray.setVisible(false);
    expect(tray.visible, false);
    expect(calls.single.method, 'destroy');
    await fromPlatform('onTrayIconMouseDown');
    c.changed();
    await tray.setVisible(false);
    expect(shown, 2, reason: 'a hidden icon no longer reacts');
    expect(calls.single.method, 'destroy');
  });

  test('rapid toggling settles on the last choice', () async {
    final c = DesktopController();
    addTearDown(c.dispose);
    final tray = DesktopTray(
      controller: c,
      chinese: false,
      showWindow: () async {},
      quit: () async {},
    );
    tray.setVisible(true);
    tray.setVisible(false);
    await tray.setVisible(true);
    expect(tray.visible, true);
    expect(calls.map((c) => c.method), [
      'setIcon',
      'setToolTip',
      'setContextMenu',
      'destroy',
      'setIcon',
      'setToolTip',
      'setContextMenu',
    ]);
    await tray.setVisible(false);
  });

  for (final zh in [false, true]) {
    testWidgets('settings toggle applies the tray choice ${zh ? "zh" : "en"}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = DesktopController()..status = DesktopStatus(statusData());
      addTearDown(c.dispose);
      final changes = <bool>[];
      await tester.pumpWidget(
        PhoneBridgeApp(
          controller: c,
          initialChinese: zh,
          onTrayIconChanged: changes.add,
        ),
      );
      await tester.tap(find.text(zh ? '设置' : 'Settings').first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          Platform.isMacOS
              ? (zh ? '在菜单栏显示图标' : 'Show icon in the menu bar')
              : (zh ? '在任务栏显示图标' : 'Show icon in the system tray'),
        ),
        findsOneWidget,
      );
      final toggle = find.byKey(const Key('tray-icon'));
      expect(tester.widget<Switch>(toggle).value, true);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(changes, [false, true]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tray setting is hidden where the host has no tray', (
    tester,
  ) async {
    final c = DesktopController()..status = DesktopStatus(statusData());
    addTearDown(c.dispose);
    await tester.pumpWidget(PhoneBridgeApp(controller: c));
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tray-icon')), findsNothing);
  });
}
