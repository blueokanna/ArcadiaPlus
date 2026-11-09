import 'dart:io';

/// Transport policy for every DNS path, including upstream hostname bootstrap.
abstract final class EncryptedDnsPolicy {
  // Literal endpoints avoid asking the OS to resolve the resolver itself.
  // These endpoints have IP certificate identities; no hostname override is needed.
  static const defaults = [
    'https://223.5.5.5/dns-query',
    'https://223.6.6.6/dns-query',
  ];

  // Keep domestic CDN answers close to the direct exit. Explicit profile
  // policies, including more-specific suffixes, remain authoritative.
  static const domesticDomains = [
    'cn',
    'bilibili.com',
    'biliapi.net',
    'biliapi.com',
    'bilivideo.com',
    'bilivideo.cn',
    'hdslb.com',
    'b23.tv',
    'qq.com',
    'weixin.com',
    'wechat.com',
    'qpic.cn',
    'qlogo.cn',
    'gtimg.com',
  ];

  static bool accepts(String value, {bool literal = false}) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        const {'https', 'tls', 'quic', 'h3'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !RegExp(r'\s').hasMatch(value) &&
        (!literal ||
            InternetAddress.tryParse(
                  uri.host.replaceAll(RegExp(r'[\[\]]'), ''),
                ) !=
                null);
  }

  static Map<String, dynamic> apply(
    Map<String, dynamic> config, {
    void Function(String)? onWarning,
  }) {
    List<String> encrypted(Object? raw, {bool literal = false}) {
      final source = (raw as List?)?.cast<String>() ?? const <String>[];
      final accepted = source
          .where((s) => accepts(s, literal: literal))
          .toList();
      if (accepted.length != source.length) {
        onWarning?.call(
          'Encrypted DNS protection excluded unencrypted or unsuitable upstreams.',
        );
      }
      return accepted;
    }

    final nameservers = encrypted(config['nameservers']);
    final selected = nameservers.isEmpty ? defaults : nameservers;
    final bootstrap = encrypted(config['default_nameserver'], literal: true);
    final policies = <String, List<String>>{};
    final declaredPolicies = config['nameserver_policy'] as Map;
    for (final domain in domesticDomains) {
      final covered = declaredPolicies.keys.any((key) {
        final suffix = key
            .toString()
            .toLowerCase()
            .replaceFirst(RegExp(r'^(\+\.|\*\.|\.|=)'), '')
            .replaceFirst(RegExp(r'\.$'), '');
        return domain == suffix || domain.endsWith('.$suffix');
      });
      if (!covered) policies['+.$domain'] = defaults;
    }
    for (final entry in declaredPolicies.entries) {
      final servers = encrypted(entry.value);
      policies[entry.key as String] = servers.isEmpty ? selected : servers;
    }
    return {
      ...config,
      'enable': true,
      'nameservers': selected,
      'fallback': encrypted(config['fallback']),
      'default_nameserver': bootstrap.isEmpty ? defaults : bootstrap,
      'nameserver_policy': policies,
      'fallback_filter': {'geoip': false},
    };
  }
}
