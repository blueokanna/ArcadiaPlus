import 'dart:io';

/// One transport boundary for primary, fallback, domain and bootstrap queries.
/// Encryption does not grant permission to send a private name to a new operator.
abstract final class EncryptedDnsPolicy {
  static const defaults = [
    'https://223.5.5.5/dns-query',
    'https://223.6.6.6/dns-query',
  ];

  // These operators offer certificate-verified HTTPS on the same literal IP.
  static const _upgrades = {
    '223.5.5.5': 'https://223.5.5.5/dns-query',
    '223.6.6.6': 'https://223.6.6.6/dns-query',
    '1.1.1.1': 'https://1.1.1.1/dns-query',
    '8.8.8.8': 'https://8.8.8.8/dns-query',
  };

  static bool accepts(String value, {bool literal = false}) {
    try {
      // Uri normalizes an explicit :0 away for schemes without a registered
      // default port. Corduit rejects it, so inspect the original spelling.
      if (RegExp(r':0+(?:[/#?]|$)').hasMatch(value)) return false;
      final uri = Uri.tryParse(value);
      if (uri == null) return false;
      final http = uri.scheme == 'https' || uri.scheme == 'h3';
      final host = uri.host;
      final validHost =
          host.isNotEmpty &&
          host.length <= 253 &&
          !host.startsWith('.') &&
          !host.endsWith('.') &&
          RegExp(r'^[a-zA-Z0-9_.:\-]+$').hasMatch(host);
      return validHost &&
          uri.hasAuthority &&
          const {'https', 'tls', 'quic', 'h3'}.contains(uri.scheme) &&
          uri.userInfo.isEmpty &&
          !uri.authority.contains('%') &&
          (http
              ? (!uri.hasQuery || uri.path.startsWith('/'))
              : (uri.path.isEmpty && !uri.hasQuery)) &&
          (!uri.hasFragment ||
              (uri.fragment.isNotEmpty &&
                  RegExp(r'^[a-zA-Z0-9_.:\-]+$').hasMatch(uri.fragment))) &&
          (!uri.hasPort || (uri.port > 0 && uri.port <= 65535)) &&
          !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(value) &&
          (!literal || InternetAddress.tryParse(uri.host) != null);
    } on FormatException {
      return false;
    }
  }

  static Map<String, dynamic> apply(
    Map<String, dynamic> config, {
    void Function(String)? onWarning,
  }) {
    List<String> encrypted(Object? raw, String role, {bool literal = false}) {
      final source = (raw as List?)?.cast<String>() ?? const <String>[];
      final accepted = <String>{};
      for (final entry in source) {
        final value = entry.trim();
        final upgraded = _upgrades[value] ?? value;
        if (!accepts(upgraded, literal: literal)) {
          throw FormatException(
            'Encrypted DNS: $role contains an unsupported endpoint. '
            'Configure certificate-verified DoH/DoT/DoQ for this resolver'
            '${literal ? ' using a literal bootstrap address' : ''}, '
            'or explicitly disable encrypted DNS protection.',
          );
        }
        if (upgraded != value) {
          onWarning?.call(
            'Encrypted DNS upgraded $role to HTTPS on the same IP.',
          );
        }
        accepted.add(upgraded);
      }
      return accepted.toList(growable: false);
    }

    final nameservers = encrypted(config['nameservers'], 'nameservers');
    final selected = nameservers.isEmpty ? defaults : nameservers;
    final fallback = encrypted(config['fallback'], 'fallback');
    final bootstrap = encrypted(
      config['default_nameserver'],
      'default-nameserver',
      literal: true,
    );
    final ownLiterals = selected
        .where((s) => accepts(s, literal: true))
        .toList();
    if (bootstrap.isEmpty && ownLiterals.isEmpty) {
      throw const FormatException(
        'Encrypted DNS: hostname-only resolvers need an explicit encrypted '
        'IP-literal bootstrap endpoint. System DNS is not used.',
      );
    }
    return {
      ...config,
      'enable': true,
      'nameservers': selected,
      'fallback': fallback,
      'default_nameserver': bootstrap.isEmpty ? ownLiterals : bootstrap,
      'nameserver_policy': {
        for (final entry in (config['nameserver_policy'] as Map).entries)
          entry.key: encrypted(entry.value, 'nameserver-policy'),
      },
    };
  }
}
