import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/backend.dart';
import 'backend_test.dart' show statusData;

void main() {
  test('old status remains valid; device identity and state validated', () {
    expect(DesktopStatus(statusData()).devices, isEmpty);
    final device = {
      'id': 'stable',
      'name': 'Phone',
      'connected': false,
      'busy': false,
      'readOnly': true,
    };
    final status = DesktopStatus({
      ...statusData(),
      'devices': [device],
    });
    expect(status.devices.single.id, 'stable');
    expect(status.devices.single.connected, isFalse);
    expect(status.devices.single.readOnly, isTrue);
    expect(status.devices.single.waitingCount, 0);
    expect(DesktopDevice({...device, 'waitingCount': 64}).waitingCount, 64);
    for (final invalid in [
      null,
      {...device, 'id': ''},
      {...device, 'connected': 'yes'},
      {...device, 'busy': null},
      {...device, 'connectionId': 42},
      {...device, 'controlling': 'yes'},
      {...device, 'controlOwnerName': 42},
      {...device, 'waitingCount': 65},
      {...device, 'waitingCount': -1},
      {...device, 'waitingCount': '2'},
      {
        ...device,
        'transfer': {'name': 42, 'state': 'pending'},
      },
    ]) {
      expect(
        () => DesktopStatus({
          ...statusData(),
          'devices': [invalid],
        }),
        throwsA(isA<BackendFailure>()),
      );
    }
    expect(
      () => DesktopStatus({
        ...statusData(),
        'devices': [device, device],
      }),
      throwsA(isA<BackendFailure>()),
    );
  });
}
