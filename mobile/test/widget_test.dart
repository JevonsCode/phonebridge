import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/main.dart';
import 'package:phonebridge/playground.dart';

void main() {
  const channel = MethodChannel('dev.phonebridge/control');
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var connected = false;
  var saved = false;
  var autoReconnect = false;
  var rememberedActions = false, connecting = false;
  setUp(() {
    calls.clear();
    connected = false;
    saved = false;
    autoReconnect = false;
    rememberedActions = false;
    connecting = false;
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
          if (call.method == 'disconnect') {
            connected = false;
            autoReconnect = false;
          }
          if (call.method == 'forgetSavedConnection') saved = false;
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
