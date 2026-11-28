import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/app.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'backend_test.dart' show statusData;

class UsbController extends DesktopController {
  final routes = <String>[];
  final bodies = <Map<String, dynamic>>[];
  @override
  bool get ready => true;
  @override
  Future<void> mutate(
    String route, [
    Map<String, dynamic> body = const {},
  ]) async {
    routes.add(route);
    bodies.add(body);
  }
}

void main() {
  test('USB status rejects malformed phones and keeps valid ones', () {
    final usb = UsbSummary({
      'available': true,
      'adbFound': true,
      'phones': [
        {'serial': '0123abcd', 'state': 'unknown', 'model': 'Pixel 9'},
        {'serial': 'bad;serial', 'state': 'unknown'},
        {'serial': 'x', 'state': 3},
        'junk',
      ],
    });
    expect(usb.phones.map((p) => p.serial), ['0123abcd']);
    expect(usb.phones.single.displayName, 'Pixel 9');
    expect(usb.phones.single.canRequestPairing, isTrue);
    expect(UsbSummary(const {}).adbFound, isFalse);
  });

  testWidgets('a plugged-in unpaired phone can be asked to confirm pairing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1120, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UsbController()
      ..status = DesktopStatus({
        ...statusData(),
        'usb': {
          'available': true,
          'adbFound': true,
          'phones': [
            {'serial': 'SER1', 'state': 'unknown', 'model': 'Pixel 9'},
            {'serial': 'SER2', 'state': 'unauthorized'},
            {'serial': 'SER3', 'state': 'connected_usb', 'model': 'Mi 13'},
          ],
        },
      });
    addTearDown(c.dispose);
    await tester.pumpWidget(PhoneBridgeApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usb-quick-connect')), findsOneWidget);
    expect(find.text('Not paired yet. Confirm on the phone'), findsOneWidget);
    expect(
      find.text('Allow USB debugging in the phone dialog and tick "Always allow"'),
      findsOneWidget,
    );
    expect(find.text('Connected over USB'), findsOneWidget);
    expect(find.byKey(const Key('usb-pair-SER2')), findsNothing);
    expect(find.byKey(const Key('usb-pair-SER3')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('usb-pair-SER1')));
    await tester.tap(find.byKey(const Key('usb-pair-SER1')));
    expect(c.routes, ['usb-pair']);
    expect(c.bodies.single, {'serial': 'SER1'});
  });

  testWidgets('missing adb explains the platform-tools install', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1120, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UsbController()
      ..status = DesktopStatus({
        ...statusData(),
        'connected': false,
        'usb': {'adbFound': false},
      });
    addTearDown(c.dispose);
    await tester.pumpWidget(PhoneBridgeApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.textContaining('adb was not found'), findsOneWidget);
    expect(
      find.text('https://developer.android.com/tools/releases/platform-tools'),
      findsOneWidget,
    );
  });
}
