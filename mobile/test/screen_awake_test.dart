import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/screen_awake.dart';
import 'package:phonebridge/design.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.phonebridge/control');
  var saved = 'controlling';
  var writeFails = false;
  var readFails = false;
  final calls = <MethodCall>[];
  setUp(() {
    saved = 'controlling';
    writeFails = readFails = false;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'getScreenAwakeMode') {
        if (readFails) throw PlatformException(code: 'FAILED');
        return saved;
      }
      if (call.method == 'setScreenAwakeMode') {
        if (writeFails) throw PlatformException(code: 'FAILED');
        saved = call.arguments['mode'] as String;
        return {'screenAwakeMode': saved};
      }
      throw PlatformException(code: 'UNEXPECTED');
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: phoneTheme(),
        home: const Scaffold(body: ScreenAwakeSetting()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'default controlling, explicit selection persists without connection methods',
    (tester) async {
      await mount(tester);
      expect(find.text('While controlling'), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-awake-setting')));
      await tester.pumpAndSettle();
      expect(find.textContaining('never wakes or unlocks'), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-awake-always')));
      await tester.pumpAndSettle();
      expect(saved, 'always');
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(find.text('Always'), findsOneWidget);
      expect(calls.map((c) => c.method).toSet(), {
        'getScreenAwakeMode',
        'setScreenAwakeMode',
      });
    },
  );
  testWidgets('failed writes preserve saved choice and expose a retry', (
    tester,
  ) async {
    await mount(tester);
    writeFails = true;
    await tester.tap(find.byKey(const Key('screen-awake-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screen-awake-off')));
    await tester.pumpAndSettle();
    expect(saved, 'controlling');
    expect(
      find.text('Could not save the screen awake setting. Try again.'),
      findsOneWidget,
    );
    writeFails = false;
    await tester.tap(find.byKey(const Key('screen-awake-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screen-awake-off')));
    await tester.pumpAndSettle();
    expect(saved, 'off');
  });
  testWidgets('read failure remains retryable', (tester) async {
    readFails = true;
    await mount(tester);
    expect(
      find.text('Could not read the screen awake setting. Try again.'),
      findsOneWidget,
    );
    readFails = false;
    await tester.tap(find.byKey(const Key('screen-awake-setting')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen-awake-controlling')), findsOneWidget);
  });
}
