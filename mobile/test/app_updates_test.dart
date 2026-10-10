import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/app_updates.dart';
import 'package:phonebridge/design.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.phonebridge/control');
  const eventChannel = EventChannel('dev.phonebridge/updates');
  final calls = <MethodCall>[];
  MockStreamHandlerEventSink? events;
  var cancelCount = 0;
  late Map<String, dynamic> status;
  Completer<Map<String, dynamic>>? check;
  Completer<Map<String, dynamic>>? install;
  Completer<Map<String, dynamic>>? read;
  PlatformException? checkError;
  var checkPhase = 'available';

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('zh');
    calls.clear();
    check = null;
    install = null;
    read = null;
    events = null;
    cancelCount = 0;
    checkError = null;
    checkPhase = 'available';
    status = {
      'phase': 'idle',
      'currentVersion': '0.2.3',
      'currentVersionCode': 2007,
      'versionName': '0.2.4',
      'versionCode': 2008,
      'updateAvailable': true,
      'downloadedBytes': 0,
      'totalBytes': 10 * 1024 * 1024,
      'progress': 0.0,
      'errorMessage': null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getUpdateStatus':
              if (read != null) return read!.future;
              return Map<String, dynamic>.from(status);
            case 'checkUpdate':
              if (checkError != null) throw checkError!;
              if (check != null) return check!.future;
              status['phase'] = checkPhase;
              return Map<String, dynamic>.from(status);
            case 'downloadUpdate':
              status['phase'] = 'downloading';
              return Map<String, dynamic>.from(status);
            case 'installUpdate':
              if (install != null) return install!.future;
              status['phase'] = 'installerOpened';
              return Map<String, dynamic>.from(status);
          }
          throw PlatformException(code: 'UNEXPECTED_METHOD');
        });
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearLocaleTestValue(),
  );
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
  });

  void mockEvents() {
    // Create the mock stream in the widget test's fake async zone so emitted
    // events are delivered by pump, just like MethodChannel responses.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          eventChannel,
          MockStreamHandler.inline(
            onListen: (_, sink) {
              events = sink;
              sink.success(Map<String, dynamic>.from(status));
            },
            onCancel: (_) => cancelCount++,
          ),
        );
  }

  Future<void> show(WidgetTester tester) async {
    mockEvents();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: phoneTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: AppUpdateCard(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets(
    'entry checks once, reads actual version, and permits manual check',
    (tester) async {
      await show(tester);
      expect(find.text('当前版本 0.2.3'), findsOneWidget);
      expect(find.text('最新版本 0.2.4'), findsOneWidget);
      expect(find.text('下载更新'), findsOneWidget);
      expect(calls.where((c) => c.method == 'checkUpdate'), hasLength(1));
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(SurfaceGroup),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.clipBehavior, Clip.antiAlias);
      await tester.pump(const Duration(seconds: 3));
      expect(calls.where((c) => c.method == 'getUpdateStatus'), hasLength(1));
      await tester.tap(find.byKey(const Key('check-update')));
      await tester.pump();
      expect(calls.where((c) => c.method == 'checkUpdate'), hasLength(2));
      expect(calls.every((c) => c.arguments == null), true);
    },
  );

  testWidgets('current release still offers the latest APK', (tester) async {
    checkPhase = 'current';
    status['currentVersion'] = '0.2.4';
    status['currentVersionCode'] = 2008;
    status['updateAvailable'] = false;
    await show(tester);
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('下载 APK'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-update')));
    await tester.pump();
    expect(calls.where((c) => c.method == 'downloadUpdate'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('check failure is retryable and never claims current', (
    tester,
  ) async {
    status.remove('versionName');
    checkError = PlatformException(code: 'NETWORK', message: '无法连接更新服务器');
    await show(tester);
    expect(find.text('无法连接更新服务器'), findsOneWidget);
    expect(find.text('已是最新版本'), findsNothing);
    expect(find.text('重试检查'), findsOneWidget);
    checkError = null;
    status['versionName'] = '0.2.4';
    await tester.tap(find.byKey(const Key('check-update')));
    await tester.pump();
    expect(find.text('下载更新'), findsOneWidget);
  });

  testWidgets('pending check disables duplicate actions and survives dispose', (
    tester,
  ) async {
    check = Completer<Map<String, dynamic>>();
    await show(tester);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('check-update')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    check!.complete({...status, 'phase': 'available'});
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'download polls, displays progress, and never installs automatically',
    (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const Key('download-update')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('check-update')))
            .onPressed,
        isNull,
      );
      status['downloadedBytes'] = 5 * 1024 * 1024;
      status['progress'] = 0.5;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('5.0 MB / 10.0 MB'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('update-progress')),
            )
            .value,
        0.5,
      );
      status['phase'] = 'ready';
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const Key('install-update')), findsOneWidget);
      expect(calls.where((c) => c.method == 'installUpdate'), isEmpty);
      final readCount = calls
          .where((c) => c.method == 'getUpdateStatus')
          .length;
      await tester.pump(const Duration(seconds: 3));
      expect(
        calls.where((c) => c.method == 'getUpdateStatus'),
        hasLength(readCount),
      );
    },
  );

  testWidgets(
    'installer cancellation and permission return refresh for explicit retry',
    (tester) async {
      await show(tester);
      status['phase'] = 'permissionRequired';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('允许并安装'), findsOneWidget);
      expect(calls.where((c) => c.method == 'installUpdate'), isEmpty);
      await tester.tap(find.byKey(const Key('install-update')));
      await tester.pump();
      expect(calls.where((c) => c.method == 'installUpdate'), hasLength(1));
      status['phase'] = 'ready';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('安装更新'), findsOneWidget);
      expect(calls.where((c) => c.method == 'installUpdate'), hasLength(1));
      await tester.tap(find.byKey(const Key('install-update')));
      await tester.pump();
      expect(calls.where((c) => c.method == 'installUpdate'), hasLength(2));
    },
  );

  testWidgets(
    're-entry observes native download and dispose stops UI polling only',
    (tester) async {
      status['phase'] = 'downloading';
      await show(tester);
      expect(calls.where((c) => c.method == 'checkUpdate'), isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(calls.where((c) => c.method == 'getUpdateStatus'), hasLength(2));
      await tester.pumpWidget(const SizedBox());
      final count = calls.length;
      await tester.pump(const Duration(seconds: 4));
      expect(calls, hasLength(count));
      expect(status['phase'], 'downloading');
      expect(calls.any((c) => c.method == 'disconnect'), false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed download exposes native error and retry', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('download-update')));
    await tester.pump();
    status['phase'] = 'error';
    status['errorMessage'] = 'APK 校验失败，请重新下载';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('APK 校验失败，请重新下载'), findsOneWidget);
    expect(find.text('重试下载'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-update')));
    await tester.pump();
    expect(calls.where((c) => c.method == 'downloadUpdate'), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  for (final phase in ['ready', 'permissionRequired', 'installerOpened']) {
    testWidgets('entry preserves $phase without replacing install retry', (
      tester,
    ) async {
      status['phase'] = phase;
      await show(tester);
      expect(calls.where((c) => c.method == 'checkUpdate'), isEmpty);
      expect(calls.where((c) => c.method == 'installUpdate'), isEmpty);
      expect(
        find.byKey(const Key('install-update')),
        phase == 'installerOpened' ? findsNothing : findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(calls.where((c) => c.method == 'getUpdateStatus'), hasLength(1));
    });
  }

  testWidgets(
    'narrow screen with enlarged text retains usable update actions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      mockEvents();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: phoneTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: AppUpdateCard(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final download = find.byKey(const Key('download-update'));
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pump();
      expect(calls.where((c) => c.method == 'downloadUpdate'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final terminal in ['current', 'available', 'error']) {
    testWidgets('re-entry inherits checking then observes $terminal event', (
      tester,
    ) async {
      check = Completer<Map<String, dynamic>>();
      await show(tester);
      expect(calls.where((c) => c.method == 'checkUpdate'), hasLength(1));
      status['phase'] = 'checking';
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(cancelCount, 1);
      await show(tester);
      expect(find.text('正在检查更新…'), findsOneWidget);
      expect(calls.where((c) => c.method == 'checkUpdate'), hasLength(1));
      final reads = calls.where((c) => c.method == 'getUpdateStatus').length;
      await tester.pump(const Duration(seconds: 3));
      expect(
        calls.where((c) => c.method == 'getUpdateStatus'),
        hasLength(reads),
      );
      status['phase'] = terminal;
      if (terminal == 'error') status['errorMessage'] = '检查失败，请重试';
      events!.success(Map<String, dynamic>.from(status));
      check!.complete(Map<String, dynamic>.from(status));
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('check-update')))
            .onPressed,
        isNotNull,
      );
      expect(
        find.text(switch (terminal) {
          'current' => '已是最新版本',
          'available' => '新版本已就绪，下载后按提示安装',
          _ => '检查失败，请重试',
        }),
        findsOneWidget,
      );
      expect(calls.where((c) => c.method == 'installUpdate'), isEmpty);
    });
  }

  for (final phase in ['error', 'ready']) {
    testWidgets(
      'async install $phase failure enables explicit retry without resume',
      (tester) async {
        status['phase'] = 'ready';
        install = Completer<Map<String, dynamic>>();
        await show(tester);
        await tester.tap(find.byKey(const Key('install-update')));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('install-update')))
              .onPressed,
          isNull,
        );
        status['phase'] = phase;
        status['errorMessage'] = phase == 'error'
            ? 'APK 校验失败，请重新下载'
            : '无法打开系统安装界面';
        events!.success(Map<String, dynamic>.from(status));
        await tester.pump();
        await tester.pump();
        final retry = find.byKey(
          Key(phase == 'error' ? 'download-update' : 'install-update'),
        );
        // An event changes status, but only the terminal method result ends the action.
        expect(tester.widget<FilledButton>(retry).onPressed, isNull);
        install!.complete(Map<String, dynamic>.from(status));
        await tester.pump();
        expect(find.text(status['errorMessage']), findsOneWidget);
        expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
        expect(calls.where((c) => c.method == 'installUpdate'), hasLength(1));
      },
    );
  }

  testWidgets('new native event wins over stale action result', (tester) async {
    check = Completer<Map<String, dynamic>>();
    await show(tester);
    status['phase'] = 'available';
    events!.success(Map<String, dynamic>.from(status));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('check-update')))
          .onPressed,
      isNull,
    );
    check!.complete({...status, 'phase': 'checking'});
    await tester.pump();
    await tester.pump();
    expect(find.text('新版本已就绪，下载后按提示安装'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('check-update')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('new event wins over stale resume snapshot', (tester) async {
    await show(tester);
    read = Completer<Map<String, dynamic>>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    status['phase'] = 'ready';
    events!.success(Map<String, dynamic>.from(status));
    await tester.pump();
    await tester.pump();
    read!.complete({...status, 'phase': 'downloading'});
    await tester.pump();
    expect(find.text('安装更新'), findsOneWidget);
    expect(find.byKey(const Key('update-progress')), findsNothing);
  });

  testWidgets(
    'dispose cancels events and ignores late events and action callback',
    (tester) async {
      check = Completer<Map<String, dynamic>>();
      await show(tester);
      final oldEvents = events!;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(cancelCount, 1);
      oldEvents.success({...status, 'phase': 'downloading'});
      check!.complete({...status, 'phase': 'available'});
      await tester.pump(const Duration(seconds: 3));
      expect(calls.where((c) => c.method == 'getUpdateStatus'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
