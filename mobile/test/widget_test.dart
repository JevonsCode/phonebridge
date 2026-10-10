import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/main.dart';
import 'support/playground.dart';

void main() {
  const channel = MethodChannel('dev.phonebridge/control');
  const updates = EventChannel('dev.phonebridge/updates');
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var connected = false;
  var saved = false;
  var autoReconnect = false;
  var rememberedActions = false, connecting = false;
  Completer<void>? desktopStart;
  PlatformException? desktopFailure;
  setUp(() {
    calls.clear();
    connected = false;
    saved = false;
    autoReconnect = false;
    rememberedActions = false;
    connecting = false;
    desktopStart = null;
    desktopFailure = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(updates.name), (call) async {
          if (call.method == 'listen') {
            TestWidgetsFlutterBinding.instance.channelBuffers.push(
              updates.name,
              const StandardMethodCodec().encodeSuccessEnvelope({
                'phase': 'downloading',
                'currentVersion': '0.2.3',
                'versionName': '0.2.4',
                'updateAvailable': true,
                'downloadedBytes': 0,
                'totalBytes': 100,
                'progress': 0.0,
              }),
              (_) {},
            );
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'status') {
            return {
              'accessibilityEnabled': true,
              'connected': connected,
              'connecting': connecting,
              'rememberedActions': rememberedActions,
              'actionsEnabled': false,
              'lastError': '',
              'hasSavedPairing': saved,
              'savedEndpoint': saved ? 'ws://192.168.1.10:8765/device' : '',
              'autoReconnectEnabled': autoReconnect,
            };
          }
          if (call.method == 'getUpdateStatus' ||
              call.method == 'checkUpdate') {
            return {
              'phase': 'downloading',
              'currentVersion': '0.2.3',
              'versionName': '0.2.4',
              'updateAvailable': true,
              'downloadedBytes': 0,
              'totalBytes': 100,
              'progress': 0.0,
            };
          }
          if (call.method == 'disconnect') {
            connected = false;
            autoReconnect = false;
          }
          if (call.method == 'forgetSavedConnection') saved = false;
          if (call.method == 'startDesktopService') {
            if (desktopStart != null) await desktopStart!.future;
            if (desktopFailure != null) throw desktopFailure!;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  Future<void> openManual(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-pairing')));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop start only appears for paired disconnected phones', (
    tester,
  ) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    expect(find.byKey(const Key('start-desktop-service')), findsNothing);
    saved = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('start-desktop-service')), findsOneWidget);
    autoReconnect = true;
    connecting = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('start-desktop-service')), findsOneWidget);
    connected = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('start-desktop-service')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop start sends no credentials, disables duplicates and keeps Stop usable',
    (tester) async {
      saved = true;
      autoReconnect = true;
      desktopStart = Completer<void>();
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pump();
      final start = find.byKey(const Key('start-desktop-service'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      final startCall = calls.singleWhere(
        (c) => c.method == 'startDesktopService',
      );
      expect(startCall.arguments, isNull);
      expect(tester.widget<OutlinedButton>(start).onPressed, isNull);
      expect(find.text('正在启动电脑服务…'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(const Key('stop'))).onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pump();
      expect(calls.any((c) => c.method == 'disconnect'), true);
      desktopStart!.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final failure in {
    'DESKTOP_UNREACHABLE': '无法联系电脑，请确认电脑已开机并连接同一网络',
    'DESKTOP_UPDATE_REQUIRED': '电脑端尚不支持一键启动，请更新并安装电脑端后台服务',
    'DESKTOP_AUTH_FAILED': '电脑拒绝了配对身份，请检查电脑端配对设置',
    'DESKTOP_START_FAILED': '电脑服务启动失败，请检查电脑端后台服务',
  }.entries) {
    testWidgets(
      'desktop start explains ${failure.key} without resuming from Flutter',
      (tester) async {
        saved = true;
        desktopFailure = PlatformException(
          code: failure.key,
          message: failure.value,
        );
        await tester.pumpWidget(const PhoneBridgeApp());
        await tester.pump();
        final start = find.byKey(const Key('start-desktop-service'));
        await tester.ensureVisible(start);
        await tester.tap(start);
        await tester.pump();
        await tester.pump();
        expect(find.text(failure.value), findsOneWidget);
        expect(tester.widget<OutlinedButton>(start).onPressed, isNotNull);
        expect(calls.any((c) => c.method == 'resumeSavedConnection'), false);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('home has no playground and About opens public project links', (
    tester,
  ) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    expect(find.text('试一试'), findsNothing);
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    for (final entry in {'GitHub': 'github', '官方网站': 'website'}.entries) {
      await tester.ensureVisible(find.text(entry.key));
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(
        calls.any(
          (c) =>
              c.method == 'openProjectLink' &&
              c.arguments['destination'] == entry.value,
        ),
        true,
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saved action consent remains clear while disconnected', (
    tester,
  ) async {
    saved = true;
    rememberedActions = true;
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('actions')),
    );
    expect(toggle.value, true);
    expect(toggle.onChanged, isNull);
    expect(find.text('操作授权已保留，重连后恢复'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native update download keeps phone Stop independently usable', (
    tester,
  ) async {
    saved = true;
    connected = true;
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('app-update-card')));
    await tester.pump();
    expect(find.text('正在下载，可继续使用手机控制'), findsOneWidget);
    // Leaving About only disposes the observing card; native keeps downloading.
    await tester.tap(find.byKey(const Key('nav-connection')));
    await tester.pump();
    final stop = find.byKey(const Key('stop'));
    await tester.ensureVisible(stop);
    expect(tester.widget<OutlinedButton>(stop).onPressed, isNotNull);
    await tester.tap(stop);
    await tester.pump();
    expect(calls.where((c) => c.method == 'disconnect'), hasLength(1));
    expect(calls.where((c) => c.method == 'installUpdate'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('pairing connection keeps stop above system navigation inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pumpAndSettle();
    connecting = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final rect = tester.getRect(find.byKey(const Key('stop')));
    expect(rect.bottom, lessThanOrEqualTo(576));
    expect(find.byKey(const Key('nav-settings')), findsNothing);
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(calls.any((c) => c.method == 'disconnect'), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('connection requires consent; actions default off', (
    tester,
  ) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await openManual(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('connect')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('connect'))).onPressed,
      isNull,
    );
    expect(calls.where((c) => c.method == 'connect'), isEmpty);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('actions')),
    );
    expect(toggle.value, false);
    expect(toggle.onChanged, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('stop invokes native disconnect', (tester) async {
    connected = true;
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(calls.any((c) => c.method == 'disconnect'), true);
    expect(connected, false);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'saved pairing resumes without exposing token or asking for QR again',
    (tester) async {
      saved = true;
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pump();
      expect(find.byKey(const Key('scan-pairing')), findsNothing);
      expect(find.widgetWithText(TextField, '配对密钥'), findsNothing);
      final resume = find.byKey(const Key('resume-saved'));
      await tester.ensureVisible(resume);
      await tester.pumpAndSettle();
      await tester.tap(resume);
      await tester.pump();
      expect(calls.any((c) => c.method == 'resumeSavedConnection'), true);
      expect(calls.any((c) => c.method == 'connect'), false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stop stays reachable during network reconnect and saved pairing remains',
    (tester) async {
      saved = true;
      autoReconnect = true;
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pump();
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pump();
      expect(autoReconnect, false);
      expect(saved, true);
      expect(find.byKey(const Key('resume-saved')), findsOneWidget);
      expect(find.byKey(const Key('stop')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'forgetting pairing returns to first-time consent without reconnecting',
    (tester) async {
      saved = true;
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已记住的电脑'));
      await tester.pumpAndSettle();
      final forget = find.byKey(const Key('forget-saved'));
      await tester.ensureVisible(forget);
      await tester.pumpAndSettle();
      await tester.tap(forget);
      await tester.pump();
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      await tester.tap(find.byKey(const Key('manual-pairing')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byKey(const Key('consent'))).value,
        false,
      );
      expect(
        calls.any(
          (c) => c.method == 'resumeSavedConnection' || c.method == 'connect',
        ),
        false,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('playground supports observable tap and Unicode text', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PlaygroundPage()));
    await tester.tap(find.text('加一'));
    await tester.pump();
    expect(find.text('当前计数：1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '你好 PhoneBridge');
    await tester.ensureVisible(find.text('保存练习文字'));
    await tester.tap(find.text('保存练习文字'));
    await tester.pump();
    expect(find.text('已保存：你好 PhoneBridge'), findsOneWidget);
  });

  testWidgets('native disconnect clears a retained pairing token', (
    tester,
  ) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await openManual(tester);
    final field = find.widgetWithText(TextField, '配对密钥');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'private-session-token-do-not-retain');
    connected = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    connected = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await openManual(tester);
    final tokenField = tester.widget<TextField>(
      find.widgetWithText(TextField, '配对密钥'),
    );
    expect(tokenField.controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
