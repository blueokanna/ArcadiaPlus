import 'dart:io';

/// One transport boundary for primary, fallback, domain and bootstrap queries.
/// Encryption does not grant permission to send a private name to a new operator.
abstract final class EncryptedDnsPolicy {
  static const defaults = [
    'https://223.5.5.5/dns-query',
    'https://223.6.6.6/dns-query',
  ];

  // Same-operator upgrades only. DNSPod documents dot.pub as its TLS identity:
  // https://cloud.tencent.com/document/product/302/110784
  // The literal dial address avoids an unencrypted hostname bootstrap.
  static const _upgrades = {
    '119.29.29.29': 'tls://1.12.12.12#dot.pub',
    '223.5.5.5': 'https://223.5.5.5/dns-query',
    '223.6.6.6': 'https://223.6.6.6/dns-query',
    '1.1.1.1': 'https://1.1.1.1/dns-query',
    '8.8.8.8': 'https://8.8.8.8/dns-query',
  };

  static bool accepts(String value, {bool literal = false}) {
    try {
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
    bool strict = true,
    void Function(String)? onWarning,
  }) {
    final unsupported = <String>{};
    List<String> encrypted(Object? raw, String role, {bool literal = false}) {
      final source = (raw as List?)?.cast<String>() ?? const <String>[];
      final accepted = <String>{};
      for (final entry in source) {
        final value = entry.trim();
        final upgraded = _upgrades[value] ?? value;
        if (!accepts(upgraded, literal: literal)) {
          if (!strict) {
            accepted.add(value);
            onWarning?.call(
              'DNS preference kept a subscription endpoint in $role; this path may be plaintext.',
            );
            continue;
          }
          // Collect every incompatible role in one pass. Never return a
          // partially filtered configuration or include URI credentials in logs.
          final uri = Uri.tryParse(value);
          final label = uri != null && uri.userInfo.isNotEmpty
              ? '${uri.scheme}://${uri.host}'
              : value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
          unsupported.add(
            '$role: ${label.length > 160 ? label.substring(0, 160) : label}',
          );
          continue;
        }
        if (upgraded != value) {
          onWarning?.call(
            'Encrypted DNS upgraded $role using the same operator with certificate verification.',
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
    final policy = <String, List<String>>{
      for (final entry in (config['nameserver_policy'] as Map).entries)
        entry.key as String: encrypted(entry.value, 'nameserver-policy'),
    };
    if (!strict) {
      return {
        ...config,
        'nameservers': selected,
        'fallback': fallback,
        'default_nameserver': bootstrap,
        'nameserver_policy': policy,
      };
    }
    if (unsupported.isNotEmpty) {
      throw FormatException(
        'Encrypted DNS requires verified DoH/DoT/DoQ on every path. '
        'Incompatible endpoints: ${unsupported.take(12).join('; ')}'
        '${unsupported.length > 12 ? '; …' : ''}. '
        'Keep private DNS rules intact: configure their encrypted endpoints '
        'or turn off encrypted DNS protection to use subscription DNS.',
      );
    }
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
      'nameserver_policy': policy,
    };
  }
}
