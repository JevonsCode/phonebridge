import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/file_inbox.dart';
import 'package:phonebridge/operation_history.dart';

void main() {
  testWidgets(
    'pending file requires explicit receipt before sharing, works with large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final actions = <String>[];
      Future<void> show(String state) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FileInboxCard(
                files: [
                  {
                    'id': 'file-1',
                    'name': 'a-long-image-file-name.png',
                    'size': 4200,
                    'sourceName': 'My Mac',
                    'state': state,
                  },
                ],
                busy: false,
                onAction: (method, id) => actions.add('$method:$id'),
              ),
            ),
          ),
        ),
      );
      await show('pending');
      expect(find.text('Share'), findsNothing);
      await tester.tap(find.text('Receive'));
      expect(actions, ['receiveFile:file-1']);
      await show('received');
      await tester.tap(find.text('Share'));
      expect(actions.last, 'shareFile:file-1');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'timeline sorts newest first and never labels share chooser as sent',
    (tester) async {
      const channel = MethodChannel('dev.phonebridge/control');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {
              'operations': jsonEncode([
                {
                  'time': '2026-10-11T10:00:00Z',
                  'method': 'tap',
                  'status': 'uncertain',
                  'errorCode': 'TIMEOUT',
                },
              ]),
              'files': [
                {
                  'time': '2026-10-11T10:01:00Z',
                  'method': 'file_transfer',
                  'status': 'share_opened',
                },
              ],
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(home: OperationHistoryPage(computerName: 'My Mac')),
      );
      await tester.pumpAndSettle();
      final share = find.text(
        'Share sheet opened; check the target app for sending outcome',
      );
      final uncertain = find.text('Outcome unknown; check your phone');
      expect(share, findsOneWidget);
      expect(uncertain, findsOneWidget);
      expect(
        tester.getTopLeft(share).dy,
        lessThan(tester.getTopLeft(uncertain).dy),
      );
      expect(find.text('TIMEOUT'), findsOneWidget);
    },
  );
  testWidgets(
    'timeline compares actual time across precision and UTC offsets',
    (tester) async {
      const channel = MethodChannel('dev.phonebridge/control');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {
              'operations': jsonEncode([
                {
                  'time': '2026-10-11T10:00:00Z',
                  'method': 'tap',
                  'status': 'completed',
                },
                {
                  'time': '2026-10-11T18:00:00.250+08:00',
                  'method': 'screenshot',
                  'status': 'completed',
                },
              ]),
              'files': [
                {
                  'time': '2026-10-11T10:00:00.500123Z',
                  'method': 'file_transfer',
                  'status': 'received',
                },
              ],
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(home: OperationHistoryPage(computerName: 'My Mac')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Received')).dy,
        lessThan(tester.getTopLeft(find.text('View screenshot')).dy),
      );
      expect(
        tester.getTopLeft(find.text('View screenshot')).dy,
        lessThan(tester.getTopLeft(find.text('Tap')).dy),
      );
    },
  );
}
