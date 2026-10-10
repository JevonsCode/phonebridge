import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/operation_trails.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.phonebridge/control');
  bool? saved;
  bool readFails = false, writeFails = false;
  Completer<void>? pending;
  final calls = <MethodCall>[];
  setUp(() {
    saved = null;
    readFails = writeFails = false;
    pending = null;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'getShowOperationTrails':
          if (readFails) throw PlatformException(code: 'UNAVAILABLE');
          return saved ?? true;
        case 'setShowOperationTrails':
          if (pending != null) await pending!.future;
          if (writeFails) throw PlatformException(code: 'UNAVAILABLE');
          saved = (call.arguments as Map)['enabled'] as bool;
          return null;
        default:
          throw PlatformException(code: 'UNEXPECTED_METHOD');
      }
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  Future<void> mount(WidgetTester tester, [String locale = 'en']) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const Scaffold(body: OperationTrailSetting()),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool value(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const Key('show-operation-trails')))
      .value;

  testWidgets(
    'default is on, off persists after remount, only preference methods run',
    (tester) async {
      await mount(tester);
      expect(value(tester), isTrue);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(value(tester), isFalse);
      expect(saved, isFalse);
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(value(tester), isFalse);
      expect(calls.map((e) => e.method), [
        'getShowOperationTrails',
        'setShowOperationTrails',
        'getShowOperationTrails',
      ]);
    },
  );

  testWidgets(
    'failed write retains saved off value and offers localized feedback',
    (tester) async {
      saved = false;
      writeFails = true;
      await mount(tester);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(value(tester), isFalse);
      expect(saved, isFalse);
      expect(
        find.text('Could not save operation trail setting. Try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('read failure retains default and can recover by saving', (
    tester,
  ) async {
    readFails = true;
    await mount(tester);
    expect(value(tester), isTrue);
    expect(
      find.text('Could not load operation trail setting. Try again.'),
      findsOneWidget,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(value(tester), isFalse);
    expect(find.text('Show where AI taps and swipes'), findsOneWidget);
  });

  testWidgets('pending save disables duplicate writes and keeps prior value', (
    tester,
  ) async {
    pending = Completer<void>();
    await mount(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(value(tester), isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    pending!.complete();
    await tester.pumpAndSettle();
    expect(value(tester), isFalse);
    expect(
      calls.where((e) => e.method == 'setShowOperationTrails'),
      hasLength(1),
    );
  });

  testWidgets('Chinese copy translates the toggle and failed save feedback', (
    tester,
  ) async {
    writeFails = true;
    await mount(tester, 'zh');
    expect(find.text('显示操作轨迹'), findsOneWidget);
    expect(find.text('显示 AI 点击与滑动的位置'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.text('无法保存操作轨迹设置，请重试'), findsOneWidget);
    expect(value(tester), isTrue);
  });
}
