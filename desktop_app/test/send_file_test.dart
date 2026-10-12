import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/app.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'backend_test.dart' show statusData;

class FakeSender extends DesktopController {
  final sent = <String>[];
  @override
  bool get ready => true;
  @override
  Future<void> mutate(String route, [Map<String, dynamic>? body]) async {
    sent.add('$route:${body?['path']}');
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
        ..status = DesktopStatus({...statusData(), 'connected': true});
      addTearDown(c.dispose);
      String? path;
      await tester.pumpWidget(
        PhoneBridgeApp(controller: c, chooseFile: () async => path),
      );
      await tester.tap(find.byKey(const Key('send-file')));
      await tester.pumpAndSettle();
      expect(c.sent, isEmpty);
      path = '/tmp/chosen.png';
      await tester.tap(find.byKey(const Key('send-file')));
      await tester.pumpAndSettle();
      expect(c.sent, ['send-file:/tmp/chosen.png']);
      c.status = DesktopStatus({
        ...statusData(),
        'connected': true,
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
}
