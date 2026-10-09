/// Untrusted QR data. Parsing never opens a URL, connects, or grants consent.
class PairingData {
  const PairingData._(this.endpoint, this.token);

  final String endpoint;
  final String token;

  static PairingData parse(String raw) {
    const invalid = FormatException('这不是有效的 PhoneBridge 配对二维码，请重新打开电脑端配对页面。');
    try {
      if (raw.isEmpty ||
          raw.length > 4096 ||
          !raw.startsWith('phonebridge://pair?') ||
          RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(raw) ||
          raw.codeUnits.any((c) => c < 0x21 || c > 0x7e)) {
        throw invalid;
      }
      final uri = Uri.parse(raw);
      if (uri.scheme != 'phonebridge' ||
          uri.authority != 'pair' ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.path.isNotEmpty ||
          uri.hasFragment ||
          !uri.hasQuery) {
        throw invalid;
      }
      final values = <String, String>{};
      for (final part in uri.query.split('&')) {
        final equals = part.indexOf('=');
        if (equals <= 0) throw invalid;
        final key = Uri.decodeQueryComponent(part.substring(0, equals));
        final value = Uri.decodeQueryComponent(part.substring(equals + 1));
        if (!{'v', 'endpoint', 'token'}.contains(key) ||
            values.containsKey(key)) {
          throw invalid;
        }
        values[key] = value;
      }
      if (values.length != 3 || values['v'] != '1') throw invalid;
      final endpoint = values['endpoint']!;
      final token = values['token']!;
      final targetMatch = RegExp(
        r'^wss?://([^/?#]+)/device$',
      ).firstMatch(endpoint);
      if (!RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(token) ||
          endpoint.length > 2048 ||
          endpoint.codeUnits.any((c) => c < 0x21 || c > 0x7e) ||
          targetMatch == null) {
        throw invalid;
      }
      // Inspect raw authority as Uri normalizes empty user-info and default ports.
      final authority = targetMatch.group(1)!;
      final portMatch = RegExp(r':([0-9]+)$').firstMatch(authority);
      final explicitPort = portMatch == null
          ? null
          : int.tryParse(portMatch.group(1)!);
      if (authority.contains('@') ||
          authority.endsWith(':') ||
          (portMatch != null &&
              (explicitPort == null ||
                  explicitPort < 1 ||
                  explicitPort > 65535))) {
        throw invalid;
      }
      final target = Uri.parse(endpoint);
      if ((target.scheme != 'ws' && target.scheme != 'wss') ||
          target.host.isEmpty ||
          target.userInfo.isNotEmpty ||
          target.authority.contains('@') ||
          target.authority.endsWith(':') ||
          target.path != '/device' ||
          target.hasQuery ||
          target.hasFragment ||
          (target.hasPort && (target.port < 1 || target.port > 65535))) {
        throw invalid;
      }
      // Native EndpointPolicy remains authoritative for transport/IP restrictions.
      return PairingData._(endpoint, token);
    } on FormatException {
      // Never include the raw QR or token in an exception's source/message.
      throw invalid;
    }
  }

  @override
  String toString() => 'PairingData(redacted)';
}
