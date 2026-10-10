import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/app_language.dart';
import 'package:phonebridge/main.dart';
import 'package:phonebridge/pairing_scanner.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.phonebridge/control');
  const events = EventChannel('dev.phonebridge/updates');
  final calls = <MethodCall>[];
  var preference = 'system';
  var connected = true;
  var updateError = false;
  PlatformException? languageWriteFailure;
  Map<String, dynamic> updateStatus() => {
    'phase': updateError ? 'error' : 'current',
    'currentVersion': '0.2.4',
    'errorCode': updateError ? 'APK_SIGNATURE_MISMATCH' : null,
    // Deliberately in the opposite locale: the error code is authoritative.
    'errorMessage': updateError ? 'APK 签名不符，无法安装' : null,
  };

  setUp(() {
    preference = 'system';
    connected = true;
    updateError = false;
    languageWriteFailure = null;
    calls.clear();
    binding.platformDispatcher.localeTestValue = const Locale('en');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'getLanguagePreference':
          return preference;
        case 'setLanguagePreference':
          if (languageWriteFailure != null) throw languageWriteFailure!;
          preference = (call.arguments as Map)['language'] as String;
          return null;
        case 'status':
          return {
            'connected': connected,
            'connecting': false,
            'accessibilityEnabled': true,
            'hasSavedPairing': connected,
            'actionsEnabled': true,
            'rememberedActions': true,
            'lastError': '',
            'savedEndpoint': 'ws://192.168.1.10:8765/device',
          };
        case 'getUpdateStatus':
        case 'checkUpdate':
          return updateStatus();
      }
      throw PlatformException(code: 'UNEXPECTED_METHOD');
    });
  });
  tearDown(() {
    binding.platformDispatcher.clearLocaleTestValue();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockStreamHandler(events, null);
  });

  Future<void> mount(WidgetTester tester) async {
    binding.defaultBinaryMessenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, sink) => sink.success(updateStatus()),
      ),
    );
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String value) async {
    final row = find.text('Language').evaluate().isNotEmpty
        ? find.text('Language')
        : find.text('语言');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('language-$value')));
    await tester.pumpAndSettle();
  }

  test('system zh variants use Chinese; every other language uses English', () {
    for (final locale in [
      const Locale('zh'),
      const Locale('zh', 'TW'),
      const Locale('zh', 'CN'),
    ]) {
      expect(AppLanguage.resolve('system', locale), const Locale('zh'));
    }
    for (final locale in [
      const Locale('en'),
      const Locale('fr'),
      const Locale('ja'),
    ]) {
      expect(AppLanguage.resolve('system', locale), const Locale('en'));
    }
    expect(AppLanguage.resolve('en', const Locale('zh')), const Locale('en'));
  });

  testWidgets('system change updates display and preserves connected page', (
    tester,
  ) async {
    await mount(tester);
    final state = tester.state(find.byType(ConnectionPage));
    expect(find.text('Connected'), findsWidgets);
    binding.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsWidgets);
    expect(tester.state(find.byType(ConnectionPage)), same(state));
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('actions'))).value,
      isTrue,
    );
  });

  testWidgets(
    'manual choices persist, change immediately, and retain session and actions',
    (tester) async {
      await mount(tester);
      final state = tester.state(find.byType(ConnectionPage));
      await settings(tester);
      await choose(tester, 'zh');
      expect(preference, 'zh');
      expect(find.text('设置'), findsWidgets);
      expect(tester.state(find.byType(ConnectionPage)), same(state));
      binding.platformDispatcher.localeTestValue = const Locale('fr');
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsWidgets);
      await choose(tester, 'en');
      expect(preference, 'en');
      await tester.tap(find.byKey(const Key('nav-connection')));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsWidgets);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('actions'))).value,
        isTrue,
      );
      expect(
        calls.where(
          (call) => !{
            'status',
            'getLanguagePreference',
            'setLanguagePreference',
            'getUpdateStatus',
            'checkUpdate',
          }.contains(call.method),
        ),
        isEmpty,
      );
      // Remount simulates a new process reading Android's persisted preference.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      binding.platformDispatcher.localeTestValue = const Locale('zh');
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsWidgets);
      await settings(tester);
      await choose(tester, 'system');
      expect(preference, 'system');
      expect(find.text('设置'), findsWidgets);
    },
  );

  testWidgets('stored manual Chinese preference wins over English system', (
    tester,
  ) async {
    preference = 'zh';
    await mount(tester);
    expect(find.text('已连接'), findsWidgets);
  });

  testWidgets(
    'language save failure is handled without changing language or session',
    (tester) async {
      await mount(tester);
      final state = tester.state(find.byType(ConnectionPage));
      await settings(tester);
      languageWriteFailure = PlatformException(
        code: 'UNAVAILABLE',
        message: 'Could not save preference',
      );
      await choose(tester, 'zh');
      expect(preference, 'system');
      expect(find.text('Settings'), findsWidgets);
      expect(
        find.text('Could not save language preference. Retry.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(tester.state(find.byType(ConnectionPage)), same(state));
      await tester.tap(find.byKey(const Key('nav-connection')));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsWidgets);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('actions'))).value,
        isTrue,
      );
      expect(
        calls.where(
          (call) => {
            'disconnect',
            'connect',
            'setActionsEnabled',
            'forgetSavedConnection',
          }.contains(call.method),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'update errors translate by code and switch with the selected language',
    (tester) async {
      updateError = true;
      await mount(tester);
      await settings(tester);
      final description = find.byKey(const Key('update-description'));
      await tester.ensureVisible(description);
      expect(
        tester.widget<Text>(description).data,
        'The APK signature does not match. Installation is blocked.',
      );
      await choose(tester, 'zh');
      await tester.ensureVisible(description);
      expect(tester.widget<Text>(description).data, 'APK 签名不符，无法安装');
    },
  );

  testWidgets('English home, About and manual consent fit a 320px screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    expect(tester.takeException(), isNull);
    await settings(tester);
    await tester.ensureVisible(find.byKey(const Key('check-update')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    connected = false;
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-pairing')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
    expect(find.text('Allow sharing app screens'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('English camera permission guidance fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingCameraError(
            permissionDenied: true,
            onRetry: () {},
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Camera permission is needed to scan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
