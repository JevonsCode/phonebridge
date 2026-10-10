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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'status') {
            return {
              'accessibilityEnabled': true,
              'connected': false,
              'connecting': false,
              'actionsEnabled': false,
              'lastError': '',
            };
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
