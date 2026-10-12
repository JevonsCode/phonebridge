import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/main.dart';
import 'package:phonebridge/pairing.dart';
import 'package:phonebridge/pairing_scanner.dart';

void main() {
  const channel = MethodChannel('dev.phonebridge/control');
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var connected = false, saved = false, reconnecting = false;
  PlatformException? disconnectFailure;
  final token = 'a' * 40;
  final pairing = PairingData.parse(
    Uri(
      scheme: 'phonebridge',
      host: 'pair',
      queryParameters: {
        'v': '1',
        'endpoint': 'ws://192.168.2.3:8765/device',
        'token': token,
      },
    ).toString(),
  );

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('zh');
    calls.clear();
    connected = saved = reconnecting = false;
    disconnectFailure = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'status') {
            return {
              'accessibilityEnabled': true,
              'connected': connected,
              'connecting': false,
              'hasSavedPairing': saved,
              'autoReconnectEnabled': reconnecting,
              'actionsEnabled': false,
              'lastError': '',
            };
          }
          if (call.method == 'disconnect') {
            if (disconnectFailure != null) throw disconnectFailure!;
            connected = reconnecting = false;
          }
          return null;
        });
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearLocaleTestValue(),
  );
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget app({bool cancel = false}) => MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: ConnectionPage(
      pairingScannerBuilder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const Key('scanner-result'),
            onPressed: () => Navigator.of(context).pop(cancel ? null : pairing),
            child: const Text('返回扫码结果'),
          ),
        ),
      ),
    ),
  );

  for (final paired in [false, true]) {
    testWidgets('home scan is directly accessible with saved pairing $paired', (
      tester,
    ) async {
      saved = paired;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final entry = find.byKey(const Key('home-scan-pairing'));
      expect(entry.hitTestable(), findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scanner-result')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-prefilled')), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byKey(const Key('consent'))).value,
        isFalse,
      );
      expect(calls.where((c) => c.method != 'status'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final language in ['zh', 'en']) {
    testWidgets(
      'home scan remains visible at 200% text on a narrow $language screen',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.platformDispatcher.localeTestValue = Locale(language);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const PhoneBridgeApp());
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('home-scan-pairing')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text(language == 'zh' ? '扫一扫' : 'Scan'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'cancelling home scan confirmation preserves the active connection',
    (tester) async {
      connected = saved = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-scan-pairing')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(connected, isTrue);
      expect(find.byKey(const Key('scanner-result')), findsNothing);
      expect(calls.where((c) => c.method != 'status'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final active in ['connected', 'reconnecting']) {
    testWidgets('home scan pauses $active but retains saved pairing', (
      tester,
    ) async {
      saved = true;
      connected = active == 'connected';
      reconnecting = active == 'reconnecting';
      await tester.pumpWidget(app(cancel: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-scan-pairing')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂停并扫码'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scanner-result')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'disconnect'), hasLength(1));
      expect(calls.where((c) => c.method == 'forgetSavedConnection'), isEmpty);
      expect(saved, isTrue);
      expect(find.byKey(const Key('consent')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('failed pause does not open the camera or erase pairing', (
    tester,
  ) async {
    connected = saved = true;
    disconnectFailure = PlatformException(code: 'DISCONNECT_FAILED');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-scan-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停并扫码'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanner-result')), findsNothing);
    expect(saved, isTrue);
    expect(connected, isTrue);
    expect(find.byKey(const Key('error')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scanning prefills only and resets prior acknowledgements', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-pairing')));
    await tester.pumpAndSettle();
    for (final key in ['insecure-local', 'consent']) {
      final toggle = find.byKey(Key(key));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(toggle).value, isTrue);
    }
    final scan = find.byKey(const Key('scan-pairing'));
    await tester.ensureVisible(scan);
    await tester.pumpAndSettle();
    await tester.tap(scan);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scanner-result')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '设备连接地址'))
          .controller!
          .text,
      pairing.endpoint,
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '配对密钥'))
          .controller!
          .text,
      token,
    );
    for (final key in ['insecure-local', 'consent']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      expect(
        tester.widget<CheckboxListTile>(find.byKey(Key(key))).value,
        isFalse,
      );
    }
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('connect'))).onPressed,
      isNull,
    );
    expect(calls.where((c) => c.method != 'status'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling scanner keeps manual input and grants nothing', (
    tester,
  ) async {
    await tester.pumpWidget(app(cancel: true));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-pairing')));
    await tester.pumpAndSettle();
    final tokenField = find.widgetWithText(TextField, '配对密钥');
    await tester.ensureVisible(tokenField);
    await tester.pumpAndSettle();
    await tester.enterText(tokenField, token);
    final scan = find.byKey(const Key('scan-pairing'));
    await tester.ensureVisible(scan);
    await tester.pumpAndSettle();
    await tester.tap(scan);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scanner-result')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(tokenField).controller!.text, token);
    expect(calls.where((c) => c.method != 'status'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'camera denial offers retry and manual entry without granting access',
    (tester) async {
      var retries = 0, backs = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: PairingCameraError(
              permissionDenied: true,
              onRetry: () => retries++,
              onBack: () => backs++,
            ),
          ),
        ),
      );
      expect(find.text('需要相机权限才能扫码'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.tap(find.text('返回手动填写'));
      expect(retries, 1);
      expect(backs, 1);
      expect(calls, isEmpty);
    },
  );
}
