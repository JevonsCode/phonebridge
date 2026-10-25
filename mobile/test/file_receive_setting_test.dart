import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/file_receive_setting.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.phonebridge/control');
  bool? saved;
  bool readFails = false, writeFails = false, writesBeforeFailure = false;
  bool ignoreWrite = false, failReadAfterWrite = false, readReturnsNull = false;
  bool missingPlugin = false;
  Completer<void>? pending;
  final calls = <MethodCall>[];

  setUp(() {
    saved = null;
    readFails = writeFails = writesBeforeFailure = false;
    ignoreWrite = failReadAfterWrite = readReturnsNull = false;
    missingPlugin = false;
    pending = null;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'getAutoReceiveFilesEnabled':
          if (missingPlugin) throw MissingPluginException();
          if (readFails) throw PlatformException(code: 'UNAVAILABLE');
          return readReturnsNull ? null : saved ?? true;
        case 'setAutoReceiveFilesEnabled':
          if (pending != null) await pending!.future;
          if (writeFails && !writesBeforeFailure) {
            throw PlatformException(code: 'UNAVAILABLE');
          }
          if (!ignoreWrite) saved = (call.arguments as Map)['enabled'] as bool;
          if (failReadAfterWrite) readFails = true;
          if (writeFails) throw PlatformException(code: 'UNAVAILABLE');
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
        home: const Scaffold(body: FileReceiveSetting()),
      ),
    );
    await tester.pumpAndSettle();
  }

  SwitchListTile toggle(WidgetTester tester) => tester.widget<SwitchListTile>(
    find.byKey(const Key('auto-receive-files')),
  );

  testWidgets(
    'default on persists off and reads the saved value after remount',
    (tester) async {
      await mount(tester);
      expect(toggle(tester).value, isTrue);
      expect(
        find.text('Save files from paired computers directly to your phone'),
        findsOneWidget,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isFalse);
      expect(saved, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(toggle(tester).value, isFalse);
      expect(calls.map((call) => call.method), [
        'getAutoReceiveFilesEnabled',
        'setAutoReceiveFilesEnabled',
        'getAutoReceiveFilesEnabled',
        'getAutoReceiveFilesEnabled',
      ]);
      expect(
        calls
            .where((call) => call.method == 'setAutoReceiveFilesEnabled')
            .single
            .arguments,
        {'enabled': false},
      );
    },
  );

  testWidgets('failed save keeps the persisted off value and shows an error', (
    tester,
  ) async {
    saved = false;
    writeFails = true;
    await mount(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(toggle(tester).value, isFalse);
    expect(toggle(tester).onChanged, isNotNull);
    expect(saved, isFalse);
    expect(
      find.text('Could not save automatic reception setting. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'lost save reply displays the actual saved value after readback',
    (tester) async {
      saved = false;
      writeFails = writesBeforeFailure = true;
      await mount(tester);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      expect(toggle(tester).value, isTrue);
      expect(
        find.text('Could not save automatic reception setting. Try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('successful reply cannot override a different persisted value', (
    tester,
  ) async {
    saved = false;
    ignoreWrite = true;
    await mount(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(saved, isFalse);
    expect(toggle(tester).value, isFalse);
    expect(
      find.text('Could not save automatic reception setting. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'read failure disables the switch until retry reads the saved value',
    (tester) async {
      saved = false;
      readFails = true;
      await mount(tester);
      expect(toggle(tester).onChanged, isNull);
      expect(
        find.text('Could not load automatic reception setting. Try again.'),
        findsOneWidget,
      );
      expect(
        calls.where((call) => call.method == 'setAutoReceiveFilesEnabled'),
        isEmpty,
      );
      readFails = false;
      await tester.tap(find.byKey(const Key('retry-auto-receive-files')));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isFalse);
      expect(toggle(tester).onChanged, isNotNull);
      expect(find.byKey(const Key('retry-auto-receive-files')), findsNothing);
    },
  );

  testWidgets(
    'missing or null native preference is not reported as confirmed on',
    (tester) async {
      missingPlugin = true;
      await mount(tester);
      expect(toggle(tester).onChanged, isNull);
      missingPlugin = false;
      readReturnsNull = true;
      await tester.tap(find.byKey(const Key('retry-auto-receive-files')));
      await tester.pumpAndSettle();
      expect(toggle(tester).onChanged, isNull);
      expect(
        find.text('Could not load automatic reception setting. Try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'readback failure never displays the requested value as confirmed',
    (tester) async {
      failReadAfterWrite = true;
      await mount(tester);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(saved, isFalse);
      expect(toggle(tester).value, isTrue);
      expect(toggle(tester).onChanged, isNull);
      expect(
        find.text('Could not load automatic reception setting. Try again.'),
        findsOneWidget,
      );
      readFails = false;
      await tester.tap(find.byKey(const Key('retry-auto-receive-files')));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isFalse);
      expect(toggle(tester).onChanged, isNotNull);
    },
  );

  testWidgets(
    'pending save retains the previous value and prevents duplicate writes',
    (tester) async {
      pending = Completer<void>();
      await mount(tester);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(toggle(tester).value, isTrue);
      expect(toggle(tester).onChanged, isNull);
      pending!.complete();
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isFalse);
      expect(
        calls.where((call) => call.method == 'setAutoReceiveFilesEnabled'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'Chinese toggle, explanation, and failure feedback are localized',
    (tester) async {
      writeFails = true;
      await mount(tester, 'zh');
      expect(find.text('自动接收电脑文件'), findsOneWidget);
      expect(find.text('已配对电脑发来的文件直接保存到手机'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('无法保存自动接收设置，请重试'), findsOneWidget);
      expect(toggle(tester).value, isTrue);
    },
  );
}
