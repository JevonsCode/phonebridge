import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/app.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'backend_test.dart' show statusData;

class PhoneManager extends DesktopController {
  final actions = <Map<String, dynamic>>[];
  @override
  bool get ready => true;
  @override
  Future<void> mutate(
    String route, [
    Map<String, dynamic> body = const {},
  ]) async {
    expect(route, 'device-management');
    actions.add(body);
    if (body['action'] == 'delete') {
      status = DesktopStatus({
        ...statusData(),
        'devices': [
          for (final d in status!.devices.where((d) => d.id != body['id']))
            {
              'id': d.id,
              'name': d.name,
              'connected': d.connected,
              'busy': d.busy,
              'readOnly': d.readOnly,
            },
        ],
      });
      changed();
    }
  }
}

void main() {
  for (final width in [440.0, 1120.0]) {
    testWidgets(
      'phone actions preserve the intended target and cancel keeps the list $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = PhoneManager()
          ..status = DesktopStatus({
            ...statusData(),
            'devices': [
              for (final id in ['one', 'two'])
                {
                  'id': id,
                  'name': 'Phone $id',
                  'connected': true,
                  'busy': false,
                  'readOnly': true,
                },
            ],
          });
        addTearDown(c.dispose);
        await tester.pumpWidget(
          PhoneBridgeApp(controller: c, chooseFile: () async => null),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('rename-phone-one')));
        await tester.tap(find.byKey(const Key('rename-phone-one')));
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('phone-name-input'));
        expect(tester.getSize(field).width, greaterThan(260));
        await tester.enterText(field, 'My phone');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(c.actions.single, {
          'id': 'one',
          'action': 'rename',
          'name': 'My phone',
        });
        await tester.ensureVisible(find.byKey(const Key('file-device-target')));
        await tester.tap(find.byKey(const Key('file-device-target')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Phone two · Read only').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('delete-phone-two')));
        await tester.tap(find.byKey(const Key('delete-phone-two')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Phone two'), findsWidgets);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(c.actions.length, 1);
        await tester.tap(find.byKey(const Key('disconnect-phone-two')));
        await tester.pumpAndSettle();
        expect(c.actions.last, {'id': 'two', 'action': 'disconnect'});
        await tester.tap(find.byKey(const Key('delete-phone-two')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-phone')));
        await tester.pumpAndSettle();
        expect(c.actions.last, {'id': 'two', 'action': 'delete'});
        final picker = find.byKey(const Key('file-device-target'));
        await tester.ensureVisible(picker);
        expect(tester.getSize(picker).width, lessThanOrEqualTo(440));
        expect(tester.state<FormFieldState<String>>(picker).value, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
