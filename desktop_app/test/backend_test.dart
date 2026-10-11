import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge_desktop/backend.dart';

const secret = 'abcdefghijklmnopqrstuvwxyz012345';
Map<String, dynamic> statusData() => {
  'connected': true,
  'unavailable': false,
  'address': '192.168.1.2',
  'port': 8767,
  'name': 'My computer',
  'networks': [
    {'name': 'Wi-Fi', 'address': '192.168.1.2'},
  ],
  'mcpConfiguration': {
    'mcpServers': {
      'phonebridge': {'command': 'PhoneBridgeMcp.exe'},
    },
  },
};

class FakeChild implements BackendProcess {
  final stdout = StreamController<List<int>>();
  final stderr = StreamController<List<int>>();
  final exit = Completer<int>();
  int terminations = 0;
  @override
  Stream<List<int>> get output => stdout.stream;
  @override
  Stream<List<int>> get errors => stderr.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void terminate() {
    terminations++;
    if (!exit.isCompleted) exit.complete(0);
    unawaited(stdout.close());
    unawaited(stderr.close());
  }

  @override
  void kill() => terminate();
  void ready(int port, {bool reused = false}) => stdout.add(
    utf8.encode(
      '${jsonEncode({'ready': true, 'dashboardUrl': 'http://127.0.0.1:$port/session/$secret', 'reusedClient': reused})}\n',
    ),
  );
}

void main() {
  test('request deadlines allow time for OS LAN approval', () {
    final api = DashboardApi(
      DashboardSession('http://127.0.0.1:8123/session/$secret'),
    );
    expect(api.deadline('status'), const Duration(seconds: 5));
    expect(api.deadline('start'), const Duration(seconds: 30));
    expect(api.deadline('network'), const Duration(seconds: 30));
    expect(api.deadline('allow-lan'), const Duration(seconds: 90));
    api.close();
  });
  test('accepts only canonical explicit loopback session URLs', () {
    expect(
      DashboardSession('http://127.0.0.1:8123/session/$secret').secret,
      secret,
    );
    for (final raw in [
      'https://127.0.0.1:8123/session/$secret',
      'http://localhost:8123/session/$secret',
      'http://127.1:8123/session/$secret',
      'http://127.0.0.1/session/$secret',
      'http://127.0.0.1:08123/session/$secret',
      'http://127.0.0.1:65536/session/$secret',
      'http://127.0.0.1:0/session/$secret',
      'http://user@127.0.0.1:8123/session/$secret',
      'http://127.0.0.1:8123/session/$secret?x=1',
      'http://127.0.0.1:8123/session/$secret#x',
      'http://127.0.0.1:8123/session/$secret\n',
      'http://127.0.0.1:8123/%73ession/$secret',
      'http://127.0.0.1:8123/../session/$secret',
    ]) {
      expect(() => DashboardSession(raw), throwsFormatException);
    }
  });

  test(
    'POST supplies exact Origin and CSRF; MCP remains JSON object',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((r) async {
        requests.add(r.method);
        expect(r.uri.path, startsWith('/session/$secret/'));
        if (r.method == 'POST') {
          expect(r.headers.value('origin'), 'http://127.0.0.1:${server.port}');
          expect(r.headers.value('x-phonebridge-csrf'), secret);
          expect(jsonDecode(await utf8.decoder.bind(r).join()), {
            'address': '192.168.1.3',
          });
        }
        r.response.write(jsonEncode(statusData()));
        await r.response.close();
      });
      final api = DashboardApi(
        DashboardSession('http://127.0.0.1:${server.port}/session/$secret'),
      );
      expect(
        DesktopStatus(await api.request('status')).mcpConfiguration,
        isA<Map<String, dynamic>>(),
      );
      await api.request('network', body: {'address': '192.168.1.3'});
      expect(requests, ['GET', 'POST']);
      api.close();
      await server.close(force: true);
    },
  );

  test(
    'redirects are never followed and error capabilities are redacted',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((r) async {
        calls++;
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/stolen',
        );
        await r.response.close();
      });
      final api = DashboardApi(
        DashboardSession('http://127.0.0.1:${server.port}/session/$secret'),
      );
      await expectLater(
        api.request('status'),
        throwsA(
          isA<BackendFailure>().having((e) => e.code, 'code', 'redirect'),
        ),
      );
      expect(calls, 1);
      expect(safeDetail('failed /session/$secret'), isNull);
      expect(safeDetail('Bearer secret'), isNull);
      api.close();
      await server.close(force: true);
    },
  );

  test('network requests have a bounded total timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((_) {});
    final api = DashboardApi(
      DashboardSession('http://127.0.0.1:${server.port}/session/$secret'),
      timeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      api.request('status'),
      throwsA(isA<BackendFailure>().having((e) => e.code, 'code', 'timeout')),
    );
    api.close();
    await server.close(force: true);
  });

  for (final reused in [false, true]) {
    test(
      'ready child reuse=$reused survives exit and cleanup respects ownership',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) async {
          r.response.write(jsonEncode(statusData()));
          await r.response.close();
        });
        final child = FakeChild();
        final controller = DesktopController(
          starter: () async {
            scheduleMicrotask(() {
              child.ready(server.port, reused: reused);
              if (reused) {
                child.exit.complete(0);
                unawaited(child.stdout.close());
                unawaited(child.stderr.close());
              }
            });
            return child;
          },
        );
        await controller.start();
        expect(controller.status?.connected, true);
        expect(controller.failure, isNull);
        await controller.shutdown();
        expect(child.terminations, reused ? 0 : 1);
        controller.dispose();
        await server.close(force: true);
      },
    );
  }

  test(
    'startup failure and oversized stdout fail visibly and clean own child',
    () async {
      final child = FakeChild();
      final controller = DesktopController(
        starter: () async {
          scheduleMicrotask(() => child.stdout.add(List.filled(65537, 65)));
          return child;
        },
      );
      await controller.start();
      expect(controller.failure?.code, 'session');
      expect(controller.starting, false);
      expect(child.terminations, 1);
      controller.dispose();
    },
  );

  test('closing during process creation terminates the late child', () async {
    final launch = Completer<BackendProcess>();
    final child = FakeChild();
    final controller = DesktopController(starter: () => launch.future);
    final starting = controller.start();
    await Future<void>.delayed(Duration.zero);
    await controller.shutdown();
    launch.complete(child);
    await starting;
    expect(child.terminations, 1);
    controller.dispose();
  });

  test('polling does not overlap; mutations are serialized', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var gets = 0, posts = 0;
    server.listen((r) async {
      if (r.method == 'POST') {
        posts++;
      } else {
        gets++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      r.response.write(jsonEncode(statusData()));
      await r.response.close();
    });
    final child = FakeChild();
    final controller = DesktopController(
      starter: () async {
        scheduleMicrotask(() => child.ready(server.port));
        return child;
      },
      pollInterval: const Duration(hours: 1),
    );
    await controller.start();
    await Future.wait([
      controller.refresh(),
      controller.refresh(),
      controller.refresh(),
    ]);
    expect(gets, 2);
    await Future.wait([controller.mutate('start'), controller.mutate('start')]);
    expect(posts, 1);
    await controller.shutdown();
    controller.dispose();
    await server.close(force: true);
  });
}
