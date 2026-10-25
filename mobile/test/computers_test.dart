import 'dart:async';
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
  var connecting = false, completeNewPairing = false;
  String? temporaryEndpoint;
  var temporaryConnected = false, temporaryConnecting = false;
  bool? rpcActionsEnabled;
  PlatformException? connectFailure;
  Completer<void>? connectReply;
  var queuedTasks = 0;

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('zh');
    calls.clear();
    connected = true;
    connecting = completeNewPairing = false;
    temporaryEndpoint = null;
    temporaryConnected = temporaryConnecting = false;
    rpcActionsEnabled = null;
    connectFailure = null;
    connectReply = null;
    queuedTasks = 0;
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
    Map<String, dynamic> snapshot() {
      final selected = entries.where((e) => e['id'] == active).firstOrNull;
      final selectedConnected = selected == null
          ? temporaryConnected
          : selected['connected'] ??
                (selected['state'] == null
                    ? connected
                    : ['connected', 'controlling'].contains(selected['state']));
      final selectedConnecting = selected == null
          ? temporaryConnecting
          : selected['connecting'] ??
                (selected['state'] == 'connecting' ||
                    (selected['state'] == null && connecting));
      return {
        'accessibilityEnabled': true,
        'connected': connected,
        'connecting': connecting,
        'actionsEnabled':
            rpcActionsEnabled ??
            (selected?['actionsEnabled'] == true && connected),
        'selectedConnected': selectedConnected,
        'selectedConnecting': selectedConnecting,
        'selectedActionsEnabled': selected?['actionsEnabled'] == true,
        'rememberedActions': selected?['actionsEnabled'] == true,
        'hasSavedPairing': selected != null,
        'endpoint': selected?['endpoint'] ?? temporaryEndpoint ?? '',
        'savedEndpoint': selected?['endpoint'] ?? '',
        'computerName': selected?['name'] ?? '',
        'activeComputerId': active ?? '',
        'autoReconnectEnabled': false,
        'lastError': '',
        'waitingCount': queuedTasks,
        'controlOwnerName': entries.any((e) => e['controlling'] == true)
            ? '工作电脑'
            : '',
        'computers': entries
            .map(
              (e) => {
                ...e,
                'active': e['id'] == active,
                'state':
                    e['state'] ??
                    (e['id'] == active
                        ? connected
                              ? 'connected'
                              : 'paused'
                        : 'saved'),
              },
            )
            .toList(),
      };
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getLanguagePreference') return 'system';
          if (call.method == 'getShowOperationTrails') return false;
          if (call.method == 'connect') {
            if (connectReply != null) await connectReply!.future;
            if (connectFailure != null) throw connectFailure!;
            final endpoint = Uri.parse(
              call.arguments['endpoint'] as String,
            ).replace(path: '/device').toString();
            if (call.arguments['remember'] == false) {
              active = null;
              temporaryEndpoint = endpoint;
              temporaryConnected = completeNewPairing;
              temporaryConnecting = !completeNewPairing;
            } else {
              entries.add({
                'id': 'third',
                'name': '新电脑',
                'endpoint': endpoint,
                'actionsEnabled': false,
                'resumeAllowed': true,
                'connected': completeNewPairing,
                'state': completeNewPairing ? 'connected' : 'connecting',
              });
              active = 'third';
            }
            connected = connected || completeNewPairing;
            connecting = connecting || !completeNewPairing;
            return snapshot();
          }
          if (call.method == 'selectComputer') {
            active = call.arguments['id'] as String;
            connected = true;
          }
          if (call.method == 'renameComputer') {
            entries.firstWhere((e) => e['id'] == call.arguments['id'])['name'] =
                call.arguments['name'];
          }
          if (call.method == 'disconnect') connected = false;
          if (call.method == 'setComputerResumeAllowed') {
            final entry = entries.firstWhere(
              (e) => e['id'] == call.arguments['id'],
            );
            entry['resumeAllowed'] = call.arguments['enabled'];
          }
          if (call.method == 'setActionsEnabled') {
            final id = call.arguments['id'] ?? active;
            entries.firstWhere((e) => e['id'] == id)['actionsEnabled'] =
                call.arguments['enabled'];
          }
          if (call.method == 'forgetComputer') {
            final id = call.arguments['id'];
            entries.removeWhere((e) => e['id'] == id);
            if (active == id) {
              active = null;
              connected = false;
            }
          }
          if (call.method == 'status') return snapshot();
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

  Future<void> pairAnother(WidgetTester tester) async {
    await open(tester);
    await tester.ensureVisible(find.byKey(const Key('pair-another-computer')));
    await tester.tap(find.byKey(const Key('pair-another-computer')));
    await tester.pumpAndSettle();
  }

  Future<void> fillNewPairing(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('manual-pairing')));
    await tester.pumpAndSettle();
    final endpoint = find.widgetWithText(TextField, '设备连接地址');
    await tester.ensureVisible(endpoint);
    await tester.pumpAndSettle();
    await tester.enterText(endpoint, 'ws://192.168.1.30:8765/device');
    final token = find.widgetWithText(TextField, '配对密钥');
    await tester.ensureVisible(token);
    await tester.pumpAndSettle();
    await tester.enterText(token, 'c' * 40);
    for (final key in ['insecure-local', 'consent']) {
      final toggle = find.byKey(Key(key));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
    }
    await tester.ensureVisible(find.byKey(const Key('connect')));
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
    'selecting an offline computer keeps its grant and recovery while another is online',
    (tester) async {
      entries.first.addAll({'connected': true, 'state': 'connected'});
      entries.last.addAll({
        'connected': false,
        'connecting': false,
        'state': 'paused',
        'actionsEnabled': true,
        'resumeAllowed': false,
      });
      await open(tester);
      await tester.tap(find.byKey(const Key('computer-second')));
      await tester.pumpAndSettle();
      expect(active, 'second');
      expect(connected, isTrue);
      expect(entries.first['connected'], isTrue);
      expect(find.text('连接已暂停'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
      final actions = tester.widget<SwitchListTile>(
        find.byKey(const Key('actions')),
      );
      expect(actions.value, isTrue);
      expect(actions.onChanged, isNull);
      expect(find.text('操作授权已保留，重连后恢复'), findsOneWidget);
      expect(find.byKey(const Key('stop')), findsOneWidget);
      final recovery = find.byKey(const Key('start-desktop-service'));
      await tester.ensureVisible(recovery);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(recovery).onPressed, isNotNull);
      await tester.tap(recovery);
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'startDesktopService'),
        hasLength(1),
      );
      expect(entries.last['actionsEnabled'], isTrue);
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('selected actions ignore a different RPC computers grant', (
    tester,
  ) async {
    rpcActionsEnabled = false;
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pumpAndSettle();
    final actions = tester.widget<SwitchListTile>(
      find.byKey(const Key('actions')),
    );
    expect(actions.value, isTrue);
    expect(actions.onChanged, isNotNull);
    expect(calls.where((call) => call.method == 'setActionsEnabled'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'forget selected leaves the other computer accessible and does not connect it',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('forget-first')));
      await tester.pumpAndSettle();
      expect(find.text('工作电脑'), findsWidgets);
      expect(entries, hasLength(2));
      await tester.tap(find.byKey(const Key('confirm-forget-computer')));
      await tester.pumpAndSettle();
      expect(entries.single['id'], 'second');
      expect(active, isNull);
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(find.byKey(const Key('computer-second')), findsOneWidget);
      expect(find.byKey(const Key('computer-first')), findsNothing);
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
    expect(find.byKey(const Key('computer-first')), findsOneWidget);
    expect(find.text('我的笔记本').hitTestable(), findsOneWidget);
    expect(connected, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancel rename preserves the computer sheet and connection', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('rename-first')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const Key('computer-second')).hitTestable(),
      findsOneWidget,
    );
    expect(calls.where((c) => c.method == 'renameComputer'), isEmpty);
    expect(connected, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancel deletion keeps all computers and the sheet', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(const Key('forget-saved')), findsNothing);
    await tester.tap(find.byKey(const Key('forget-second')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('ws://192.168.1.20:8765/device'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(entries, hasLength(2));
    expect(
      find.byKey(const Key('computer-first')).hitTestable(),
      findsOneWidget,
    );
    expect(calls.where((c) => c.method == 'forgetComputer'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('deleting another computer preserves the current connection', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('forget-second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-forget-computer')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'forgetComputer').single.arguments, {
      'id': 'second',
    });
    expect(entries.single['id'], 'first');
    expect(active, 'first');
    expect(connected, isTrue);
    expect(find.byKey(const Key('computer-second')), findsNothing);
    expect(find.byKey(const Key('computer-first')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pairing another retains current connections and grants while polling',
    (tester) async {
      entries.first['resumeAllowed'] = true;
      entries.last['resumeAllowed'] = false;
      final before = entries
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      await pairAnother(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'disconnect'), isEmpty);
      expect(calls.where((c) => c.method == 'forgetSavedConnection'), isEmpty);
      expect(entries, hasLength(2));
      expect(entries, before);
      expect(connected, isTrue);
      expect(active, 'first');
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('scan-pairing')))
            .onPressed,
        isNotNull,
      );
      expect(find.byKey(const Key('consent')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'canceling another pairing preserves the old connection and remembered grants',
    (tester) async {
      entries.first['resumeAllowed'] = true;
      final before = entries
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      await pairAnother(tester);
      await fillNewPairing(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-pairing')), findsNothing);
      expect(connected, isTrue);
      expect(entries, before);
      expect(
        calls.where(
          (call) => call.method == 'connect' || call.method == 'disconnect',
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new pairing remains editable during another computers connection attempt',
    (tester) async {
      connecting = true;
      await pairAnother(tester);
      await fillNewPairing(tester);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '设备连接地址'))
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '配对密钥'))
            .enabled,
        isTrue,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('connect'))).onPressed,
        isNotNull,
      );
      final address = find.widgetWithText(TextField, '设备连接地址');
      await tester.ensureVisible(address);
      await tester.pumpAndSettle();
      await tester.enterText(address, 'ws://192.168.1.40:8765/device');
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byKey(const Key('consent'))).value,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('insecure-local')))
            .value,
        isFalse,
      );
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'only the submitted new computer connection closes the pairing form',
    (tester) async {
      entries.first['resumeAllowed'] = true;
      final before = entries
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      await pairAnother(tester);
      await fillNewPairing(tester);
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pumpAndSettle();
      expect(entries.take(2), before);
      expect(active, 'third');
      expect(connected, isTrue);
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      entries.last['connected'] = true;
      entries.last['state'] = 'connected';
      connecting = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-pairing')), findsNothing);
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
      expect(calls.where((call) => call.method == 'connect').single.arguments, {
        'endpoint': 'ws://192.168.1.30:8765/device',
        'token': 'c' * 40,
        'allowInsecureLocal': true,
        'remember': true,
        'replaceAllowedPackages': false,
        'packages': ['dev.phonebridge.phonebridge', 'com.tencent.mm'],
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'temporary pairing waits for its selected endpoint while old computers stay online',
    (tester) async {
      entries.first['resumeAllowed'] = true;
      final before = entries
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      await pairAnother(tester);
      await fillNewPairing(tester);
      final remember = find.byKey(const Key('remember-pairing'));
      await tester.ensureVisible(remember);
      await tester.pumpAndSettle();
      await tester.tap(remember);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pumpAndSettle();
      expect(active, isNull);
      expect(entries, before);
      expect(connected, isTrue);
      expect(temporaryConnected, isFalse);
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      temporaryConnected = true;
      temporaryConnecting = false;
      temporaryEndpoint = 'ws://192.168.1.10:8765/device';
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      temporaryEndpoint = 'ws://192.168.1.30:8765/device';
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-pairing')), findsNothing);
      expect(entries, before);
      expect(connected, isTrue);
      expect(
        calls
            .where((call) => call.method == 'connect')
            .single
            .arguments['remember'],
        isFalse,
      );
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('accepted normalized manual endpoint closes the pairing form', (
    tester,
  ) async {
    completeNewPairing = true;
    await pairAnother(tester);
    await fillNewPairing(tester);
    final address = find.widgetWithText(TextField, '设备连接地址');
    await tester.ensureVisible(address);
    await tester.pumpAndSettle();
    await tester.enterText(address, 'ws://192.168.1.30:8765');
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
    expect(entries.last['endpoint'], 'ws://192.168.1.30:8765/device');
    expect(find.byKey(const Key('scan-pairing')), findsNothing);
    expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new pairing failure keeps the existing computer online and retains the form',
    (tester) async {
      connectFailure = PlatformException(code: 'INVALID_ARGUMENT');
      final before = entries
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      await pairAnother(tester);
      await fillNewPairing(tester);
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pumpAndSettle();
      expect(entries, before);
      expect(connected, isTrue);
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      expect(find.byKey(const Key('error')), findsOneWidget);
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'another computer going offline does not erase the new pairing draft',
    (tester) async {
      await pairAnother(tester);
      await fillNewPairing(tester);
      connected = false;
      connecting = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '配对密钥'))
            .controller!
            .text,
        'c' * 40,
      );
      expect(find.byKey(const Key('scan-pairing')), findsOneWidget);
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending new pairing disables duplicate submission and keeps the old connection',
    (tester) async {
      connectReply = Completer<void>();
      await pairAnother(tester);
      await fillNewPairing(tester);
      final connect = tester
          .widget<FilledButton>(find.byKey(const Key('connect')))
          .onPressed!;
      connect();
      connect();
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('connect'))).onPressed,
        isNull,
      );
      expect(calls.where((call) => call.method == 'connect'), hasLength(1));
      expect(connected, isTrue);
      connectReply!.complete();
      await tester.pumpAndSettle();
      expect(entries, hasLength(3));
      expect(calls.where((call) => call.method == 'disconnect'), isEmpty);
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

  testWidgets(
    'simultaneous computers show owner and targeted pause and consent',
    (tester) async {
      for (final entry in entries) {
        entry['connected'] = true;
        entry['state'] = 'connected';
        entry['resumeAllowed'] = true;
      }
      entries.first['controlling'] = true;
      await open(tester);
      expect(find.text('2 台电脑在线'), findsOneWidget);
      expect(find.text('当前控制方 · 工作电脑'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('resume-second')));
      await tester.tap(find.byKey(const Key('resume-second')));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((c) => c.method == 'setComputerResumeAllowed')
            .single
            .arguments,
        {'id': 'second', 'enabled': false},
      );
      expect(active, 'first');
      expect(entries.first['resumeAllowed'], isTrue);
      await tester.ensureVisible(find.byKey(const Key('actions-second')));
      await tester.tap(find.byKey(const Key('actions-second')));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'setActionsEnabled').single.arguments,
        {'id': 'second', 'enabled': true},
      );
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(calls.where((c) => c.method == 'disconnect'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final locale in ['zh', 'en']) {
    testWidgets(
      'waiting queue count updates without switching or new buttons in $locale',
      (tester) async {
        TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
            Locale(locale);
        queuedTasks = 2;
        await tester.pumpWidget(const PhoneBridgeApp());
        await tester.pumpAndSettle();
        final label = locale == 'zh' ? '等待控制' : 'Waiting for control';
        expect(find.text('$label · 2'), findsOneWidget);
        await tester.tap(find.text('工作电脑'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('computer-sheet-waiting-count')),
          findsOneWidget,
        );
        queuedTasks = 1;
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('$label · 1'), findsWidgets);
        expect(
          calls.where(
            (c) => c.method == 'selectComputer' || c.method == 'connect',
          ),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
