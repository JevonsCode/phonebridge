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
      final files = ValueNotifier<List<Map<String, dynamic>>>([]);
      addTearDown(files.dispose);
      void show(String state) => files.value = [
        {
          'id': 'file-1',
          'name': 'a-long-image-file-name-that-keeps-going-and-going.png',
          'size': 4200,
          'sourceName': 'My Mac',
          'state': state,
        },
      ];
      show('pending');
      await tester.pumpWidget(
        MaterialApp(
          home: FileInboxPage(
            files: files,
            onAction: (method, id) async => actions.add('$method:$id'),
          ),
        ),
      );
      expect(find.byKey(const Key('share-file-1')), findsNothing);
      await tester.tap(find.text('Receive'));
      await tester.pump();
      expect(actions, ['receiveFile:file-1']);
      show('received');
      await tester.pump();
      expect(find.text('Receive'), findsNothing);
      await tester.tap(find.byKey(const Key('share-file-1')));
      await tester.pump();
      expect(actions.last, 'shareFile:file-1');
      await tester.tap(find.byKey(const Key('more-file-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(actions.last, 'removeReceivedFile:file-1');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('long file lists page and keep waiting files on top', (
    tester,
  ) async {
    final files = ValueNotifier<List<Map<String, dynamic>>>([
      for (var i = 0; i < 45; i++)
        {
          'id': 'f$i',
          'name': 'photo-$i.jpg',
          'size': 1000 + i,
          'sourceName': 'My PC',
          'state': 'received',
        },
      {
        'id': 'waiting',
        'name': 'new.pdf',
        'size': 10,
        'sourceName': 'My PC',
        'state': 'pending',
      },
    ]);
    addTearDown(files.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FileInboxPage(files: files, onAction: (_, _) async {}),
      ),
    );
    // The file still waiting for an answer is listed before received ones.
    expect(
      tester.getTopLeft(find.byKey(const Key('file-waiting'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('file-f0'))).dy),
    );
    final more = find.byKey(const Key('file-inbox-more'));
    await tester.scrollUntilVisible(more, 300);
    expect(find.text('Show more (26)'), findsOneWidget);
    expect(find.byKey(const Key('file-f19')), findsNothing);
    await tester.tap(more);
    await tester.pump();
    await tester.scrollUntilVisible(more, 300);
    expect(find.text('Show more (6)'), findsOneWidget);
    await tester.tap(more);
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('file-f44')), 300);
    expect(more, findsNothing);
  });
  testWidgets('cleanup asks for an age and opens the shared folder', (
    tester,
  ) async {
    final files = ValueNotifier<List<Map<String, dynamic>>>([
      {'id': 'a', 'name': 'a.png', 'size': 1, 'state': 'received'},
    ]);
    addTearDown(files.dispose);
    final cleaned = <int?>[];
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FileInboxPage(
          files: files,
          onAction: (_, _) async {},
          onOpenFolder: () => opened++,
          onCleanup: (days) async {
            cleaned.add(days);
            return days == null ? 1 : 0;
          },
        ),
      ),
    );
    expect(find.textContaining('Downloads/PhoneBridge'), findsWidgets);
    await tester.tap(find.byKey(const Key('file-inbox-folder')));
    expect(opened, 1);
    await tester.tap(find.byKey(const Key('file-inbox-cleanup')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Older than 7 days'));
    await tester.pumpAndSettle();
    expect(find.text('No files to clean up'), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-inbox-cleanup')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All files'));
    await tester.pumpAndSettle();
    expect(cleaned, [7, null]);
    expect(find.text('Removed 1 files'), findsOneWidget);
  });
  testWidgets('home shows one compact file row instead of the list', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileInboxEntry(
            files: const [
              {'id': 'a', 'name': 'a.png', 'size': 1, 'state': 'received'},
              {'id': 'b', 'name': 'b.png', 'size': 1, 'state': 'received'},
            ],
            onOpen: () => opened++,
          ),
        ),
      ),
    );
    expect(find.text('2 files'), findsOneWidget);
    expect(find.text('Share'), findsNothing);
    await tester.tap(find.byKey(const Key('file-inbox-entry')));
    expect(opened, 1);
  });
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
