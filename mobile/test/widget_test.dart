import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/main.dart';
import 'package:phonebridge/playground.dart';

void main() {
  const channel = MethodChannel('dev.phonebridge/control');
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var connected = false;
  setUp(() {
    calls.clear();
    connected = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'status') {
            return {
              'accessibilityEnabled': true,
              'connected': connected,
              'connecting': false,
              'actionsEnabled': false,
              'lastError': '',
            };
          }
          if (call.method == 'disconnect') connected = false;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  testWidgets('connection requires consent; actions default off', (
    tester,
  ) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('connect')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('connect'))).onPressed,
      isNull,
    );
    expect(calls.where((c) => c.method == 'connect'), isEmpty);
    await tester.scrollUntilVisible(
      find.byKey(const Key('actions')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('actions')),
    );
    expect(toggle.value, false);
    expect(toggle.onChanged, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('stop invokes native disconnect', (tester) async {
    connected = true;
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pump();
    expect(calls.any((c) => c.method == 'disconnect'), true);
    expect(connected, false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('playground supports observable tap and Unicode text', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PlaygroundPage()));
    await tester.tap(find.text('加一'));
    await tester.pump();
    expect(find.text('当前计数：1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '你好 PhoneBridge');
    await tester.ensureVisible(find.text('保存练习文字'));
    await tester.tap(find.text('保存练习文字'));
    await tester.pump();
    expect(find.text('已保存：你好 PhoneBridge'), findsOneWidget);
  });

  testWidgets('native disconnect clears a retained pairing token', (
    tester,
  ) async {
    await tester.pumpWidget(const PhoneBridgeApp());
    await tester.pump();
    final field = find.widgetWithText(TextField, '配对密钥');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'private-session-token-do-not-retain');
    connected = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    connected = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final tokenField = tester.widget<TextField>(
      find.widgetWithText(TextField, '配对密钥'),
    );
    expect(tokenField.controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
