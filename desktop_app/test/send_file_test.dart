import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/app.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'backend_test.dart' show statusData;

class FakeSender extends DesktopController {
  final sent = <String>[];
  final targets = <String?>[];
  final bodies = <Map<String, dynamic>?>[];
  @override
  bool get ready => true;
  @override
  Future<void> mutate(String route, [Map<String, dynamic>? body]) async {
    sent.add('$route:${body?['path']}');
    targets.add(body?['deviceId'] as String?);
    bodies.add(body);
  }
}

void main() {
  testWidgets(
    'native file choice sends once, cancellation sends nothing, pending receipt blocks repeat',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = FakeSender()
        ..status = DesktopStatus({
          ...statusData(),
          'connected': true,
          'devices': [device('one')],
        });
      addTearDown(c.dispose);
      String? path;
      await tester.pumpWidget(
        PhoneBridgeApp(controller: c, chooseFile: () async => path),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('send-file')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('file-device-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone one · Online').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('send-file')));
      await tester.pumpAndSettle();
      expect(c.sent, isEmpty);
      path = '/tmp/chosen.png';
      await tester.tap(find.byKey(const Key('send-file')));
      await tester.pumpAndSettle();
      expect(c.sent, ['send-file:/tmp/chosen.png']);
      expect(c.targets, ['one']);
      c.status = DesktopStatus({
        ...statusData(),
        'connected': true,
        'devices': [device('one')],
        'transfer': {'name': 'chosen.png', 'state': 'pending'},
      });
      c.changed();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('send-file')))
            .onPressed,
        isNull,
      );
      expect(
        find.text('Waiting for receipt · Open PhoneBridge on your phone'),
        findsOneWidget,
      );
    },
  );
  testWidgets('target stays fixed when offline and another phone connects', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1120, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = FakeSender()
      ..status = DesktopStatus({
        ...statusData(),
        'devices': [
          device('one'),
          device('two', busy: true),
          device('three', readOnly: true),
        ],
      });
    addTearDown(c.dispose);
    await tester.pumpWidget(
      PhoneBridgeApp(controller: c, chooseFile: () async => '/tmp/test.png'),
    );
    expect(find.text('Busy'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-device-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone one · Online').last);
    await tester.pumpAndSettle();
    c.status = DesktopStatus({
      ...statusData(),
      'devices': [device('one', online: false), device('two')],
    });
    c.changed();
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('send-file'))).onPressed,
      isNull,
    );
    expect(c.sent, isEmpty);
    expect(find.text('Phone one · Offline'), findsOneWidget);
    c.status = DesktopStatus({
      ...statusData(),
      'devices': [device('two')],
    });
    c.changed();
    await tester.pumpAndSettle();
    expect(find.text('one · Offline'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('send-file'))).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('file-device-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone two · Online').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-file')));
    await tester.pumpAndSettle();
    expect(c.targets, ['two']);
  });
  testWidgets(
    'transfer progress and repeat blocking follow the explicitly selected phone',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = FakeSender()
        ..status = DesktopStatus({
          ...statusData(),
          'devices': [
            {
              ...device('one'),
              'transfer': {'name': 'first.png', 'state': 'pending'},
            },
            {
              ...device('two'),
              'transfer': {'name': 'second.png', 'state': 'received'},
            },
          ],
        });
      addTearDown(c.dispose);
      await tester.pumpWidget(
        PhoneBridgeApp(controller: c, chooseFile: () async => '/tmp/test.png'),
      );
      await tester.tap(find.byKey(const Key('file-device-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone one · Online').last);
      await tester.pumpAndSettle();
      expect(find.text('first.png'), findsOneWidget);
      expect(find.text('second.png'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('send-file')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('file-device-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone two · Online').last);
      await tester.pumpAndSettle();
      expect(find.text('first.png'), findsNothing);
      expect(find.text('second.png'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('send-file')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'read-only action mode still permits owner file receipt and shows control owner',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const generation = 'c0a1e972-72b7-427e-963d-fc143de1f265';
      final c = FakeSender()
        ..status = DesktopStatus({
          ...statusData(),
          'devices': [
            {
              ...device('one', readOnly: true),
              'connectionId': generation,
              'controlling': true,
              'controlOwnerName': 'Work PC',
            },
          ],
        });
      addTearDown(c.dispose);
      await tester.pumpWidget(
        PhoneBridgeApp(controller: c, chooseFile: () async => '/tmp/test.png'),
      );
      expect(find.text('Read only'), findsOneWidget);
      expect(find.text('Controlled by Work PC'), findsOneWidget);
      await tester.tap(find.byKey(const Key('file-device-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone one · Read only').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('send-file')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('send-file')));
      await tester.pumpAndSettle();
      expect(c.bodies.single, {
        'path': '/tmp/test.png',
        'deviceId': 'one',
        'connectionId': generation,
      });
    },
  );

  testWidgets(
    'legacy slot generation changes while chooser is open never send to replacement phone',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chosen = Completer<String?>();
      final c = FakeSender()
        ..status = DesktopStatus({
          ...statusData(),
          'devices': [
            {
              ...device('legacy'),
              'connectionId': 'c0a1e972-72b7-427e-963d-fc143de1f265',
            },
          ],
        });
      addTearDown(c.dispose);
      await tester.pumpWidget(
        PhoneBridgeApp(controller: c, chooseFile: () => chosen.future),
      );
      await tester.tap(find.byKey(const Key('file-device-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone legacy · Online').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('send-file')));
      await tester.pump();
      c.status = DesktopStatus({
        ...statusData(),
        'devices': [
          {
            ...device('legacy'),
            'connectionId': '79d2bbd4-72c9-41a0-afee-303648c9a0ea',
          },
        ],
      });
      c.changed();
      chosen.complete('/tmp/test.png');
      await tester.pumpAndSettle();
      expect(c.sent, isEmpty);
      expect(
        find.text(
          'The phone connection changed. Check the receiving phone and try again.',
        ),
        findsOneWidget,
      );
    },
  );
  for (final chinese in [false, true]) {
    testWidgets(
      'device queue count follows status without new control actions $chinese',
      (tester) async {
        tester.view.physicalSize = const Size(1120, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = FakeSender()
          ..status = DesktopStatus({
            ...statusData(),
            'devices': [
              {
                ...device('one'),
                'waitingCount': 3,
                'controlOwnerName': 'Work PC',
                'controlling': true,
              },
            ],
          });
        addTearDown(c.dispose);
        await tester.pumpWidget(
          PhoneBridgeApp(controller: c, initialChinese: chinese),
        );
        expect(
          find.text('${chinese ? '等待控制' : 'Waiting for control'} · 3'),
          findsOneWidget,
        );
        c.status = DesktopStatus({
          ...statusData(),
          'devices': [device('one')],
        });
        c.changed();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('device-waiting-one')), findsNothing);
        expect(c.sent, isEmpty);
      },
    );
  }
}

Map<String, dynamic> device(
  String id, {
  bool online = true,
  bool busy = false,
  bool readOnly = false,
}) => {
  'id': id,
  'name': 'Phone $id',
  'connected': online,
  'busy': busy,
  'readOnly': readOnly,
};
