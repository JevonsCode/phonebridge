import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/app.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'backend_test.dart' show statusData;

void main() {
  for (final width in [400.0, 820.0]) {
    testWidgets('minimum height and enlarged text remain usable at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 520);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = DesktopController()..status = DesktopStatus(statusData());
      addTearDown(c.dispose);
      await tester.pumpWidget(PhoneBridgeApp(controller: c));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('unavailable service does not invite scanning an unusable QR', (
    tester,
  ) async {
    final c = DesktopController();
    addTearDown(c.dispose);
    c.status = DesktopStatus({
      ...statusData(),
      'connected': false,
      'unavailable': true,
      'qr': 'data:image/png;base64,AA==',
    });
    await tester.pumpWidget(PhoneBridgeApp(controller: c));
    expect(find.text('Service unavailable'), findsOneWidget);
    expect(find.text('Scan to connect'), findsNothing);
  });

  testWidgets(
    'healthy waiting service focuses on pairing without redundant start',
    (tester) async {
      final c = DesktopController();
      addTearDown(c.dispose);
      c.status = DesktopStatus({...statusData(), 'connected': false});
      await tester.pumpWidget(PhoneBridgeApp(controller: c));
      expect(find.text('Waiting for your phone'), findsOneWidget);
      expect(find.text('Start desktop service'), findsNothing);
    },
  );

  test(
    'stable MCP guidance recognizes Windows and shell-based macOS entries',
    () {
      Map<String, dynamic> configuration(
        String command, [
        List<String>? args,
      ]) => {
        'mcpServers': {
          'phonebridge': {'command': command, 'args': ?args},
        },
      };
      expect(
        isStableMcpConfiguration(
          configuration(r'C:\Users\me\.phonebridge\bin\PhoneBridgeMcp.exe'),
        ),
        true,
      );
      expect(
        isStableMcpConfiguration(
          configuration('/bin/sh', [
            '/Users/me/.phonebridge/bin/phonebridge-mcp',
          ]),
        ),
        true,
      );
      expect(
        isStableMcpConfiguration(
          configuration('/bin/sh', [
            '-c',
            '/Users/me/.phonebridge/bin/phonebridge-mcp',
          ]),
        ),
        false,
      );
      expect(
        isStableMcpConfiguration(
          configuration(
            '/Applications/PhoneBridge.app/Contents/Resources/runtime/node',
            ['/version/bridge/dist/mcp.js'],
          ),
        ),
        false,
      );
      expect(isStableMcpConfiguration(null), false);
    },
  );
  testWidgets('macOS does not offer unsupported LAN permission mutation', (
    tester,
  ) async {
    final c = DesktopController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      PhoneBridgeApp(controller: c, supportsLanPermission: false),
    );
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Computer network'), findsOneWidget);
    expect(find.text('Allow LAN connections'), findsNothing);
  });
  for (final width in [1120.0, 440.0]) {
    for (final zh in [false, true]) {
      testWidgets(
        'navigation language clipboard ${width.toInt()} ${zh ? "zh" : "en"}',
        (tester) async {
          tester.view.physicalSize = Size(width, 840);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final font = FontLoader('NotoSansSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
          await font.load();
          final icons = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
          final c = DesktopController(installedVersion: '1.2.3-preview.4');
          c.status = DesktopStatus(statusData());
          addTearDown(c.dispose);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: PhoneBridgeApp(controller: c, initialChinese: zh),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(zh ? '手机已连接' : 'Your phone is connected'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (Platform.environment['PHONEBRIDGE_SCREENSHOTS'] == '1') {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'artifacts/desktop-${width.toInt()}-${zh ? "zh" : "en"}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.tap(find.text(zh ? '接入 AI' : 'Connect AI').first);
          await tester.pumpAndSettle();
          expect(
            find.text(zh ? '复制 MCP 配置' : 'Copy MCP configuration'),
            findsOneWidget,
          );
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'];
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.ensureVisible(
            find.text(zh ? '复制 MCP 配置' : 'Copy MCP configuration'),
          );
          await tester.tap(
            find.text(zh ? '复制 MCP 配置' : 'Copy MCP configuration'),
          );
          await tester.pumpAndSettle();
          expect(jsonDecode(copied!), statusData()['mcpConfiguration']);
          await tester.tap(find.text(zh ? '设置' : 'Settings').first);
          await tester.pumpAndSettle();
          expect(
            find.text(zh ? '版本 1.2.3-preview.4' : 'Version 1.2.3-preview.4'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('language')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(zh ? 'English' : '中文').last);
          await tester.pumpAndSettle();
          expect(find.text(zh ? 'Preferences' : '偏好设置'), findsOneWidget);
          expect(
            find.text(zh ? 'Version 1.2.3-preview.4' : '版本 1.2.3-preview.4'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('startup and runtime failure remain visible', (tester) async {
    final c = DesktopController(
      starter: () async => throw const BackendFailure('runtime'),
    );
    addTearDown(c.dispose);
    c.starting = true;
    await tester.pumpWidget(PhoneBridgeApp(controller: c));
    expect(find.text('Getting ready'), findsOneWidget);
    c.starting = false;
    await c.start();
    await tester.pump();
    expect(find.text('Unable to connect'), findsOneWidget);
    expect(find.text('Retry connection'), findsOneWidget);
  });
}
