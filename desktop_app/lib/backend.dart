import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// A capability is accepted only in its canonical loopback representation.
class DashboardSession {
  DashboardSession(String raw) {
    final match = RegExp(
      r'^http://127\.0\.0\.1:([1-9][0-9]{0,4})/session/([A-Za-z0-9_-]{32})$',
    ).firstMatch(raw);
    if (match == null ||
        match.end != raw.length ||
        int.parse(match[1]!) > 65535) {
      throw const FormatException('Invalid local dashboard session');
    }
    uri = Uri.parse(raw);
    secret = match[2]!;
  }
  late final Uri uri;
  late final String secret;
  String get origin => 'http://127.0.0.1:${uri.port}';
}

class BackendFailure implements Exception {
  const BackendFailure(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => code; // Never include capability URLs in diagnostics.
}

String? safeDetail(Object? value) {
  if (value is! String ||
      value.length > 1200 ||
      RegExp(r'/session/|bearer|token', caseSensitive: false).hasMatch(value)) {
    return null;
  }
  return value;
}

abstract class BackendProcess {
  Stream<List<int>> get output;
  Stream<List<int>> get errors;
  Future<int> get exitCode;
  void terminate();
  void kill();
}

class NativeBackendProcess implements BackendProcess {
  NativeBackendProcess(this.process);
  final Process process;
  @override
  Stream<List<int>> get output => process.stdout;
  @override
  Stream<List<int>> get errors => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void terminate() => process.kill();
  @override
  void kill() => process.kill(ProcessSignal.sigkill);
}

typedef ProcessStarter = Future<BackendProcess> Function();

String bundledRoot() {
  final executable = File(Platform.resolvedExecutable).parent;
  return Platform.isMacOS
      ? Directory('${executable.path}/../Resources').absolute.path
      : executable.path;
}

Future<String?> readInstalledVersion({String? root}) async {
  try {
    final text = await File(
      '${root ?? bundledRoot()}/package-manifest.json',
    ).readAsString();
    final manifest = jsonDecode(text.replaceFirst(RegExp(r'^\uFEFF'), ''));
    final version = manifest is Map ? manifest['version'] : null;
    return version is String &&
            RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)*$').hasMatch(version)
        ? version
        : null;
  } catch (_) {
    return null;
  }
}

Future<BackendProcess> startBundledBackend() async {
  final root = bundledRoot();
  final node = '$root/runtime/${Platform.isWindows ? 'node.exe' : 'node'}';
  final entry = '$root/desktop/${Platform.isMacOS ? 'macos/' : ''}server.mjs';
  if (!await File(node).exists() || !await File(entry).exists()) {
    throw const BackendFailure('runtime');
  }
  return NativeBackendProcess(
    await Process.start(node, [
      entry,
      '--native-window',
    ], workingDirectory: root),
  );
}

class DashboardApi {
  DashboardApi(this.session, {HttpClient? client, this.timeout})
    : _http = client ?? HttpClient();
  final DashboardSession session;
  final HttpClient _http;
  final Duration? timeout;
  Duration deadline(String route) =>
      timeout ??
      Duration(
        seconds: route == 'allow-lan'
            ? 90
            : route == 'status'
            ? 5
            : 30,
      );
  bool _closed = false;

  Future<Map<String, dynamic>> request(
    String route, {
    Map<String, dynamic>? body,
  }) async {
    if (_closed ||
        !['status', 'start', 'network', 'allow-lan'].contains(route)) {
      throw const BackendFailure('unavailable');
    }
    HttpClientRequest? active;
    Future<Map<String, dynamic>> perform() async {
      final request = await _http.openUrl(
        body == null ? 'GET' : 'POST',
        Uri.parse('${session.uri}/$route'),
      );
      active = request;
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.set('Origin', session.origin);
        request.headers.set('X-PhoneBridge-CSRF', session.secret);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const BackendFailure('redirect');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > 2000000) {
          request.abort();
          throw const BackendFailure('response');
        }
      }
      final data = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (data is! Map<String, dynamic>) throw const BackendFailure('response');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw BackendFailure('request', safeDetail(data['error']));
      }
      return data;
    }

    try {
      return await perform().timeout(
        deadline(route),
        onTimeout: () {
          active?.abort();
          throw const BackendFailure('timeout');
        },
      );
    } on BackendFailure {
      rethrow;
    } catch (_) {
      throw const BackendFailure('unavailable');
    }
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }
}

class DesktopStatus {
  DesktopStatus(Map<String, dynamic> data) {
    if (data['connected'] is! bool ||
        data['address'] is! String ||
        data['port'] is! int) {
      throw const BackendFailure('response');
    }
    connected = data['connected'];
    unavailable = data['unavailable'] == true;
    address = data['address'];
    port = data['port'];
    name = data['name'] is String ? data['name'] : 'PhoneBridge';
    error = safeDetail(data['error']);
    networks = (data['networks'] is List ? data['networks'] as List : [])
        .whereType<Map>()
        .where((n) => n['address'] is String && n['name'] is String)
        .map(
          (n) => (address: n['address'] as String, name: n['name'] as String),
        )
        .toList();
    mcpConfiguration = data['mcpConfiguration'] is Map<String, dynamic>
        ? data['mcpConfiguration']
        : null;
    final rawQr = data['qr'];
    if (rawQr is String &&
        rawQr.startsWith('data:image/png;base64,') &&
        rawQr.length < 1400000) {
      try {
        qr = base64Decode(rawQr.substring(22));
      } catch (_) {
        qr = null;
      }
    }
  }
  late final bool connected, unavailable;
  late final String address, name;
  late final int port;
  late final String? error;
  late final List<({String address, String name})> networks;
  late final Map<String, dynamic>? mcpConfiguration;
  Uint8List? qr;
}

class DesktopController extends ChangeNotifier {
  DesktopController({
    ProcessStarter? starter,
    this.installedVersion,
    this.startupTimeout = const Duration(seconds: 35),
    this.pollInterval = const Duration(seconds: 2),
  }) : _starter = starter ?? startBundledBackend;
  final ProcessStarter _starter;
  final Duration startupTimeout, pollInterval;
  BackendProcess? _process;
  DashboardApi? _api;
  Timer? _timer;
  StreamSubscription<List<int>>? _stdout, _stderr;
  bool _disposed = false, _polling = false, _owned = false;
  int _generation = 0;
  bool starting = false, mutating = false;
  final String? installedVersion;
  DesktopStatus? status;
  BackendFailure? failure;
  bool get ready => _api != null;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (starting || _disposed || mutating) return;
    starting = true;
    failure = null;
    status = null;
    changed();
    final generation = ++_generation;
    await _cleanup();
    try {
      final child = await _starter();
      if (_disposed || generation != _generation) {
        child.terminate();
        return;
      }
      _process = child;
      _owned = true;
      final ready = Completer<DashboardSession>();
      final buffer = <int>[];
      _stderr = child.errors.listen((_) {}, onError: (_) {});
      _stdout = child.output.listen(
        (chunk) {
          if (ready.isCompleted) return;
          buffer.addAll(chunk);
          if (buffer.length > 65536) {
            ready.completeError(const BackendFailure('session'));
            return;
          }
          final newline = buffer.indexOf(10);
          if (newline < 0) return;
          try {
            final data = jsonDecode(utf8.decode(buffer.sublist(0, newline)));
            if (data is! Map ||
                data['ready'] != true ||
                data['dashboardUrl'] is! String) {
              throw const BackendFailure('session');
            }
            final session = DashboardSession(data['dashboardUrl']);
            _owned = data['reusedClient'] != true;
            ready.complete(session);
          } catch (_) {
            ready.completeError(const BackendFailure('session'));
          }
        },
        onError: (_) {
          if (!ready.isCompleted) {
            ready.completeError(const BackendFailure('startup'));
          }
        },
        onDone: () {
          if (!ready.isCompleted) {
            ready.completeError(const BackendFailure('startup'));
          }
        },
      );
      // EOF owns startup failure; stdout can deliver its ready line after exitCode.
      unawaited(child.exitCode.then((_) {}));
      final session = await ready.future.timeout(
        startupTimeout,
        onTimeout: () => throw const BackendFailure('timeout'),
      );
      if (_disposed || generation != _generation) return;
      _api = DashboardApi(session);
      starting = false;
      await refresh();
      if (!_disposed && generation == _generation) {
        _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      }
    } catch (error) {
      if (!_disposed && generation == _generation) {
        failure = error is BackendFailure
            ? error
            : const BackendFailure('runtime');
        await _cleanup();
      }
    } finally {
      if (!_disposed && generation == _generation) {
        starting = false;
        changed();
      }
    }
  }

  Future<void> refresh() async {
    if (_disposed || _polling || mutating || _api == null) return;
    _polling = true;
    final generation = _generation;
    try {
      final next = DesktopStatus(await _api!.request('status'));
      if (!_disposed && generation == _generation) {
        status = next;
        failure = null;
      }
    } catch (e) {
      if (!_disposed && generation == _generation) {
        failure = e is BackendFailure ? e : const BackendFailure('response');
      }
    } finally {
      _polling = false;
      changed();
    }
  }

  Future<void> mutate(
    String route, [
    Map<String, dynamic> body = const {},
  ]) async {
    if (_disposed || mutating || _api == null) return;
    mutating = true;
    failure = null;
    changed();
    try {
      await _api!.request(route, body: body);
    } catch (e) {
      if (!_disposed) {
        failure = e is BackendFailure ? e : const BackendFailure('request');
      }
    } finally {
      mutating = false;
      changed();
    }
    if (failure == null) await refresh();
  }

  Future<void> _cleanup() async {
    _timer?.cancel();
    _timer = null;
    _api?.close();
    _api = null;
    final child = _process;
    _process = null;
    if (_owned && child != null) {
      child.terminate();
      try {
        await child.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        child.kill();
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    await _cleanup();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
