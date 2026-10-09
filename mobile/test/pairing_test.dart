import 'package:flutter_test/flutter_test.dart';
import 'package:phonebridge/pairing.dart';

void main() {
  final token = 'Ab_9-' * 8;
  String qr({String? endpoint, String? secret}) => Uri(
    scheme: 'phonebridge',
    host: 'pair',
    queryParameters: {
      'v': '1',
      'endpoint': endpoint ?? 'ws://192.168.1.23:8765/device',
      'token': secret ?? token,
    },
  ).toString();

  test('parses version 1 pairing without exposing token in diagnostics', () {
    final data = PairingData.parse(qr());
    expect(data.endpoint, 'ws://192.168.1.23:8765/device');
    expect(data.token, token);
    expect(data.toString(), isNot(contains(token)));
  });

  test('supports WSS and literal IPv6 endpoints', () {
    for (final endpoint in [
      'wss://bridge.example/device',
      'ws://[::1]:8765/device',
    ]) {
      expect(PairingData.parse(qr(endpoint: endpoint)).endpoint, endpoint);
    }
  });

  test('rejects duplicate, encoded duplicate, unknown and missing fields', () {
    for (final value in [
      '${qr()}&token=$token',
      '${qr()}&%74oken=$token',
      '${qr()}&v=1',
      '${qr()}&actions=true',
      '${qr()}&allowInsecureLocal=true',
      '${qr()}&',
      'phonebridge://pair?v=1&token=$token',
    ]) {
      expect(() => PairingData.parse(value), throwsFormatException);
    }
  });

  test('rejects wrong version, path, authority, scheme and fragments', () {
    for (final value in [
      qr().replaceFirst('v=1', 'v=2'),
      qr().replaceFirst('pair?', 'pair/?'),
      qr().replaceFirst('pair?', 'pair/other?'),
      qr().replaceFirst('pair?', 'other?'),
      qr().replaceFirst('pair?', 'user@pair?'),
      qr().replaceFirst('pair?', '@pair?'),
      qr().replaceFirst('pair?', 'pair:123?'),
      qr().replaceFirst('phonebridge:', 'https:'),
      '${qr()}#',
      '${qr()}#payload',
    ]) {
      expect(() => PairingData.parse(value), throwsFormatException);
    }
  });

  test('rejects endpoint credentials, query, fragment, path and bad port', () {
    for (final endpoint in [
      'https://bridge.example/device',
      'wss://user:password@bridge.example/device',
      'wss://@bridge.example/device',
      'wss://bridge.example/device?token=secret',
      'wss://bridge.example/device#',
      'wss://bridge.example/other',
      'wss://bridge.example/%64evice',
      'wss://bridge.example/device/',
      'wss://bridge.example:0/device',
      'wss://bridge.example:65536/device',
      'wss://bridge.example:abc/device',
      'wss://bridge.example:/device',
      'ws:///device',
    ]) {
      expect(
        () => PairingData.parse(qr(endpoint: endpoint)),
        throwsFormatException,
        reason: endpoint,
      );
    }
  });

  test(
    'bounds payload and token and rejects malformed encoding/control text',
    () {
      for (final secret in [
        'a' * 31,
        'a' * 257,
        'a' * 31 + '=',
        'a' * 31 + '+',
        'a' * 31 + ' ',
        'a' * 31 + '\n',
      ]) {
        expect(
          () => PairingData.parse(qr(secret: secret)),
          throwsFormatException,
        );
      }
      expect(PairingData.parse(qr(secret: 'a' * 256)).token.length, 256);
      for (final value in [
        '',
        'x' * 4097,
        '${qr()} ',
        '${qr()}\n',
        '${qr()}%',
        '${qr()}%ZZ',
        '${qr()}%0',
      ]) {
        expect(() => PairingData.parse(value), throwsFormatException);
      }
    },
  );

  test('invalid QR error does not retain original payload or credentials', () {
    final raw = '${qr()}&unexpected=$token';
    try {
      PairingData.parse(raw);
      fail('Invalid data was accepted.');
    } on FormatException catch (error) {
      expect(error.source, isNull);
      expect(error.message, isNot(contains(token)));
      expect(error.toString(), isNot(contains(raw)));
    }
  });
}
