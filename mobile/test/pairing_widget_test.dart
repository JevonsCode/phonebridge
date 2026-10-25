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
  var selectedStatus = <String, dynamic>{};
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
  var scannedPairing = pairing;

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('zh');
    calls.clear();
    connected = saved = reconnecting = false;
    selectedStatus = {};
    disconnectFailure = null;
    scannedPairing = pairing;
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
              ...selectedStatus,
            };
          }
          if (call.method == 'disconnect') {
            if (disconnectFailure != null) throw disconnectFailure!;
            connected = reconnecting = false;
          }
          if (call.method == 'getAppAccess') {
            return {
              'allowedPackages': [
                'dev.phonebridge.phonebridge',
                'com.tencent.mm',
              ],
              'apps': [
                {
                  'packageName': 'dev.phonebridge.phonebridge',
                  'name': 'PhoneBridge',
                  'protected': false,
                  'installed': true,
                },
                {
                  'packageName': 'com.tencent.mm',
                  'name': '微信',
                  'protected': false,
                  'installed': true,
                },
                {
                  'packageName': 'dev.fixture.only',
                  'name': '仅电脑 A 的应用',
                  'protected': false,
                  'installed': true,
                },
              ],
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
            onPressed: () =>
                Navigator.of(context).pop(cancel ? null : scannedPairing),
            child: const Text('返回扫码结果'),
          ),
        ),
      ),
    ),
  );

  Future<void> editFirstComputerDraft(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-pairing')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '设备连接地址'),
      'ws://192.168.2.10:8765/device',
    );
    await tester.enterText(find.widgetWithText(TextField, '配对密钥'), token);
    final access = find.byKey(const Key('pairing-app-access'));
    await tester.ensureVisible(access);
    await tester.pumpAndSettle();
    await tester.tap(access);
    await tester.pumpAndSettle();
    final onlyFirst = find.byKey(const Key('app-dev.fixture.only'));
    await tester.ensureVisible(onlyFirst);
    await tester.pumpAndSettle();
    await tester.tap(onlyFirst);
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-app-access')));
    await tester.pumpAndSettle();
    expect(find.text('3 个应用 · 点击修改'), findsOneWidget);
  }

  Future<Map<dynamic, dynamic>> connectSecondComputer(
    WidgetTester tester,
  ) async {
    for (final key in ['insecure-local', 'consent']) {
      final toggle = find.byKey(Key(key));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
    }
    final connect = find.byKey(const Key('connect'));
    await tester.ensureVisible(connect);
    await tester.pumpAndSettle();
    await tester.tap(connect);
    await tester.pumpAndSettle();
    return calls.singleWhere((call) => call.method == 'connect').arguments
        as Map;
  }

  testWidgets(
    'manually changing pairing credentials discards another computer app draft',
    (tester) async {
      await editFirstComputerDraft(tester);
      final endpoint = find.widgetWithText(TextField, '设备连接地址');
      await tester.ensureVisible(endpoint);
      await tester.pumpAndSettle();
      await tester.enterText(endpoint, 'ws://192.168.2.20:8765/device');
      await tester.enterText(find.widgetWithText(TextField, '配对密钥'), 'b' * 40);
      await tester.pumpAndSettle();
      final args = await connectSecondComputer(tester);
      expect(args['endpoint'], 'ws://192.168.2.20:8765/device');
      expect(args['packages'], [
        'dev.phonebridge.phonebridge',
        'com.tencent.mm',
      ]);
      expect(args['replaceAllowedPackages'], false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'scanning a new pairing target discards another computer app draft',
    (tester) async {
      await editFirstComputerDraft(tester);
      scannedPairing = PairingData.parse(
        Uri(
          scheme: 'phonebridge',
          host: 'pair',
          queryParameters: {
            'v': '1',
            'endpoint': 'ws://192.168.2.20:8765/device',
            'token': 'b' * 40,
          },
        ).toString(),
      );
      final scan = find.byKey(const Key('scan-pairing'));
      await tester.ensureVisible(scan);
      await tester.pumpAndSettle();
      await tester.tap(scan);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      final args = await connectSecondComputer(tester);
      expect(args['endpoint'], scannedPairing.endpoint);
      expect(args['packages'], [
        'dev.phonebridge.phonebridge',
        'com.tencent.mm',
      ]);
      expect(args['replaceAllowedPackages'], false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'global pause stays available when selected A is paused and B is in reconnect backoff',
    (tester) async {
      saved = true;
      selectedStatus = {
        'selectedConnected': false,
        'selectedConnecting': false,
        'selectedActionsEnabled': false,
        'activeComputerId': 'computer-a',
        'autoReconnectEnabled': false,
        'reconnecting': true,
        'computers': [
          {
            'id': 'computer-a',
            'name': 'Paused A',
            'connected': false,
            'connecting': false,
            'resumeAllowed': false,
          },
          {
            'id': 'computer-b',
            'name': 'Retrying B',
            'connected': false,
            'connecting': true,
            'resumeAllowed': true,
          },
        ],
      };
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final stop = find.byKey(const Key('stop'));
      expect(stop.hitTestable(), findsOneWidget);
      expect(tester.widget<OutlinedButton>(stop).onPressed, isNotNull);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'disconnect'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
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
    'canceling home scanner preserves the active connection without a pause confirmation',
    (tester) async {
      connected = saved = true;
      await tester.pumpWidget(app(cancel: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-scan-pairing')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      expect(connected, isTrue);
      expect(find.byKey(const Key('scanner-result')), findsNothing);
      expect(calls.where((c) => c.method != 'status'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final active in ['connected', 'reconnecting']) {
    testWidgets('home scan keeps $active running and retains saved pairing', (
      tester,
    ) async {
      saved = true;
      connected = active == 'connected';
      reconnecting = active == 'reconnecting';
      await tester.pumpWidget(app(cancel: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-scan-pairing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scanner-result')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'disconnect'), isEmpty);
      expect(calls.where((c) => c.method == 'forgetSavedConnection'), isEmpty);
      expect(saved, isTrue);
      expect(connected, active == 'connected');
      expect(reconnecting, active == 'reconnecting');
      expect(find.byKey(const Key('consent')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('home scanner never depends on a global pause operation', (
    tester,
  ) async {
    connected = saved = true;
    disconnectFailure = PlatformException(code: 'DISCONNECT_FAILED');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-scan-pairing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanner-result')), findsOneWidget);
    await tester.tap(find.byKey(const Key('scanner-result')));
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(connected, isTrue);
    expect(find.byKey(const Key('error')), findsNothing);
    expect(calls.where((call) => call.method != 'status'), isEmpty);
    expect(
      tester.widget<CheckboxListTile>(find.byKey(const Key('consent'))).value,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a connected computer does not disable scanning or reuse its consent',
    (tester) async {
      connected = saved = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-scan-pairing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      for (final key in ['insecure-local', 'consent']) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
        expect(
          tester.widget<CheckboxListTile>(find.byKey(Key(key))).value,
          isTrue,
        );
      }
      final scan = find.byKey(const Key('scan-pairing'));
      await tester.ensureVisible(scan);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(scan).onPressed, isNotNull);
      await tester.tap(scan);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      for (final key in ['insecure-local', 'consent']) {
        expect(
          tester.widget<CheckboxListTile>(find.byKey(Key(key))).value,
          isFalse,
        );
      }
      expect(connected, isTrue);
      expect(saved, isTrue);
      expect(calls.where((call) => call.method != 'status'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rapid home scan presses open only one scanner while the old computer stays online',
    (tester) async {
      connected = saved = true;
      await tester.pumpWidget(app(cancel: true));
      await tester.pumpAndSettle();
      final scan = tester
          .widget<TextButton>(find.byKey(const Key('home-scan-pairing')))
          .onPressed!;
      scan();
      scan();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scanner-result')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner-result')));
      await tester.pumpAndSettle();
      expect(connected, isTrue);
      expect(find.byKey(const Key('scanner-result')), findsNothing);
      expect(calls.where((call) => call.method != 'status'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an earlier connection finishing cannot close a new scan draft', (
    tester,
  ) async {
    connected = saved = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-scan-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scanner-result')));
    await tester.pumpAndSettle();
    for (final key in ['insecure-local', 'consent']) {
      final toggle = find.byKey(Key(key));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
    }
    await tester.ensureVisible(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'connect'), hasLength(1));
    final scan = find.byKey(const Key('scan-pairing'));
    await tester.ensureVisible(scan);
    await tester.pumpAndSettle();
    await tester.tap(scan);
    await tester.pumpAndSettle();
    selectedStatus = {
      'selectedConnected': true,
      'selectedConnecting': false,
      'endpoint': pairing.endpoint,
    };
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scanner-result')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pairing-prefilled')), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byKey(const Key('consent'))).value,
      isFalse,
    );
    expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
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
