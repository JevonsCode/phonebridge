import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.phonebridge/control');
  final calls = <MethodCall>[];
  late List<Map<String, dynamic>> entries;
  String? active;
  var connected = true;

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('zh');
    calls.clear();
    connected = true;
    active = 'first';
    entries = [
      {
        'id': 'first',
        'name': '工作电脑',
        'endpoint': 'ws://192.168.1.10:8765/device',
        'actionsEnabled': true,
      },
      {
        'id': 'second',
        'name': '家里的电脑',
        'endpoint': 'ws://192.168.1.20:8765/device',
        'actionsEnabled': false,
      },
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getLanguagePreference') return 'system';
          if (call.method == 'getShowOperationTrails') return false;
          if (call.method == 'selectComputer') {
            active = call.arguments['id'] as String;
            connected = true;
          }
          if (call.method == 'renameComputer') {
            entries.firstWhere((e) => e['id'] == call.arguments['id'])['name'] =
                call.arguments['name'];
          }
          if (call.method == 'disconnect') connected = false;
          if (call.method == 'forgetSavedConnection') {
            entries.removeWhere((e) => e['id'] == active);
            active = null;
            connected = false;
          }
          if (call.method == 'status') {
            final selected = entries
                .where((e) => e['id'] == active)
                .firstOrNull;
            return {
              'accessibilityEnabled': true,
              'connected': connected,
              'connecting': false,
              'actionsEnabled':
                  selected?['actionsEnabled'] == true && connected,
              'rememberedActions': selected?['actionsEnabled'] == true,
              'hasSavedPairing': selected != null,
              'savedEndpoint': selected?['endpoint'] ?? '',
              'computerName': selected?['name'] ?? '',
              'activeComputerId': active ?? '',
              'autoReconnectEnabled': false,
              'lastError': '',
              'computers': entries
                  .map(
                    (e) => {
                      ...e,
                      'active': e['id'] == active,
                      'state': e['id'] == active
                          ? connected
                                ? 'connected'
                                : 'paused'
                          : 'saved',
                    },
                  )
                  .toList(),
            };
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearLocaleTestValue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作电脑'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'saved selection connects in one tap without scanning or another consent flow',
    (tester) async {
      await open(tester);
      expect(find.text('家里的电脑'), findsOneWidget);
      await tester.tap(find.byKey(const Key('computer-second')));
      await tester.pumpAndSettle();
      expect(active, 'second');
      expect(
        calls.where((c) => c.method == 'selectComputer').single.arguments,
        {'id': 'second'},
      );
      expect(
        calls.where(
          (c) => {
            'connect',
            'requestNotificationPermission',
            'forgetSavedConnection',
          }.contains(c.method),
        ),
        isEmpty,
      );
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('actions'))).value,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'forget selected leaves the other computer accessible and does not connect it',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('forget-saved')));
      await tester.pumpAndSettle();
      expect(entries.single['id'], 'second');
      expect(active, isNull);
      expect(find.byKey(const Key('consent')), findsNothing);
      await tester.tap(find.text('我的电脑'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('computer-second')), findsOneWidget);
      expect(calls.where((c) => c.method == 'selectComputer'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('rename sends only selected identifier and friendly name', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('rename-first')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('computer-name')), '我的笔记本');
    await tester.tap(find.byKey(const Key('save-computer-name')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'renameComputer').single.arguments, {
      'id': 'first',
      'name': '我的笔记本',
    });
    expect(find.text('我的笔记本'), findsOneWidget);
    expect(connected, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pairing another pauses the current computer while retaining every entry',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('pair-another-computer')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'disconnect'), hasLength(1));
      expect(calls.where((c) => c.method == 'forgetSavedConnection'), isEmpty);
      expect(entries, hasLength(2));
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      expect(find.byKey(const Key('consent')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'English computer list fits a narrow display with a long editable name',
    (tester) async {
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
          const Locale('en');
      entries.first['name'] =
          'My trusted workstation with a long friendly name';
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(entries.first['name'] as String));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entries.first['name'] as String));
      await tester.pumpAndSettle();
      expect(find.text('Saved computers'), findsOneWidget);
      expect(find.text('Pair another computer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
