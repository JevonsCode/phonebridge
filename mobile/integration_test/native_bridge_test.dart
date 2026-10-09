import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:phonebridge/main.dart';
import 'package:phonebridge/playground.dart';

// Run only on an isolated emulator, with AccessibilityService enabled by the
// test operator and a local hub reachable via adb reverse. No production hooks.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Native accessibility gestures must reach Flutter instead of the test
  // framework's default interactive finder/debug interception.
  binding.shouldPropagateDevicePointerEvents = true;
  const channel = MethodChannel('dev.phonebridge/control');
  const token = String.fromEnvironment('PHONEBRIDGE_TEST_TOKEN');
  const port = String.fromEnvironment(
    'PHONEBRIDGE_TEST_PORT',
    defaultValue: '8765',
  );
  final http = HttpClient();
  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final request = await http.postUrl(Uri.parse('http://127.0.0.1:$port/rpc'));
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'method': method, 'params': params}));
    final response = await request.close().timeout(const Duration(seconds: 20));
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  }

  testWidgets(
    'real Android: read-only, tree, screenshot, tap, text, allowlist, stop',
    (tester) async {
      expect(
        token.length,
        greaterThanOrEqualTo(32),
        reason: 'Pass a private test token using --dart-define.',
      );
      await tester.pumpWidget(const PhoneBridgeApp());
      await tester.pumpAndSettle();
      Map<String, dynamic>? status;
      for (var i = 0; i < 150; i++) {
        status = await channel.invokeMapMethod<String, dynamic>('status');
        if (status?['accessibilityEnabled'] == true) break;
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        status?['accessibilityEnabled'],
        true,
        reason: 'Enable service on the isolated emulator first.',
      );
      await channel.invokeMethod<void>('connect', {
        'endpoint': 'ws://127.0.0.1:$port/device',
        'token': token,
        'allowInsecureLocal': true,
        'packages': ['dev.phonebridge.phonebridge'],
      });
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if ((await channel.invokeMapMethod<String, dynamic>(
              'status',
            ))?['connected'] ==
            true) {
          break;
        }
      }
      expect(
        (await channel.invokeMapMethod<String, dynamic>(
          'status',
        ))?['connected'],
        true,
      );
      await tester.pumpWidget(const MaterialApp(home: PlaygroundPage()));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));

      final denied = await rpc('tap', {'x': 100, 'y': 100});
      expect(denied['error']?['code'], 'READ_ONLY');
      final state = await rpc('state');
      expect(state['error'], isNull, reason: jsonEncode(state));
      final nodes = (state['result']['nodes'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        nodes.any((n) => '${n['text']} ${n['description']}'.contains('加一')),
        true,
      );
      final screenshot = await rpc('screenshot');
      expect(
        screenshot['error'],
        isNull,
        reason: jsonEncode(screenshot['error']),
      );
      final shot = screenshot['result'] as Map<String, dynamic>;
      final codec = await ui.instantiateImageCodec(
        base64Decode(shot['data'] as String),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, shot['width']);
      expect(frame.image.height, shot['height']);
      frame.image.dispose();
      codec.dispose();

      await channel.invokeMethod<void>('setActionsEnabled', {'enabled': true});
      final button = nodes.firstWhere(
        (n) => n['text'] == '加一' || n['description'] == '加一',
      );
      final bounds = button['bounds'] as Map<String, dynamic>;
      final tapped = await rpc('tap', {
        'x': ((bounds['left'] + bounds['right']) / 2).round(),
        'y': ((bounds['top'] + bounds['bottom']) / 2).round(),
      });
      expect(tapped['error'], isNull, reason: jsonEncode(tapped));
      await tester.pumpAndSettle();
      expect(find.text('当前计数：1'), findsOneWidget);

      final nextState = await rpc('state');
      final beforeFocus = (nextState['result']['nodes'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((n) => n['editable'] == true);
      final unfocused = await rpc('set_text', {
        'nodeId': beforeFocus['id'],
        'text': 'must not apply',
      });
      expect(unfocused['error']?['code'], 'FOCUS_REQUIRED');
      final inputBounds = beforeFocus['bounds'] as Map<String, dynamic>;
      final focusTap = await rpc('tap', {
        'x': ((inputBounds['left'] + inputBounds['right']) / 2).round(),
        'y': ((inputBounds['top'] + inputBounds['bottom']) / 2).round(),
      });
      expect(focusTap['error'], isNull, reason: jsonEncode(focusTap));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      final focusedState = await rpc('state');
      expect(focusedState['error'], isNull, reason: jsonEncode(focusedState));
      final editable = (focusedState['result']['nodes'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((n) => n['editable'] == true);
      final typed = await rpc('set_text', {
        'nodeId': editable['id'],
        'text': '你好 PhoneBridge',
      });
      expect(typed['error'], isNull, reason: jsonEncode(typed));
      // ACTION_SET_TEXT acknowledges dispatch before Flutter's platform event
      // updates its editing controller. Observe the real effect, with a bound.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (tester.widget<TextField>(find.byType(TextField)).controller!.text ==
            '你好 PhoneBridge') {
          break;
        }
      }
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '你好 PhoneBridge',
      );
      final stale = await rpc('set_text', {
        'nodeId': editable['id'],
        'text': 'stale',
      });
      expect(stale['error'], isNotNull);
      final blocked = await rpc('launch_app', {
        'packageName': 'com.android.settings',
      });
      expect(blocked['error'], isNotNull);
      await channel.invokeMethod<void>('disconnect');
      final stopped = await rpc('state');
      expect(stopped['error'], isNotNull);
      http.close(force: true);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
