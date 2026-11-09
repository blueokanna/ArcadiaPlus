import 'dart:io';

/// RecurseX 0.2.4 pins HTTP DNS to an IP certificate identity. DoT/DoQ still
/// support a separate dial address and hostname. Never disable verification
/// or replace an unknown private resolver with a public service to work around it.
abstract final class DnsTransportCompatibility {
  static const replacements = {
    'https://dns.cloudflare.com/dns-query': 'https://1.1.1.1/dns-query',
    'https://cloudflare-dns.com/dns-query': 'https://1.1.1.1/dns-query',
    'https://dns.google/dns-query': 'https://8.8.8.8/dns-query',
    'https://dns.alidns.com/dns-query': 'https://223.5.5.5/dns-query',
    'https://223.5.5.5/dns-query#dns.alidns.com': 'https://223.5.5.5/dns-query',
    'https://223.6.6.6/dns-query#dns.alidns.com': 'https://223.6.6.6/dns-query',
    'https://doh.pub/dns-query': 'tls://dot.pub',
    'https://dns.quad9.net/dns-query': 'tls://dns.quad9.net',
    'https://dns.adguard-dns.com/dns-query': 'tls://dns.adguard-dns.com',
  };

  static String upstream(String value, {void Function(String)? onWarning}) {
    final original = value.trim();
    final compatible = replacements[original];
    if (compatible != null) {
      onWarning?.call(
        'DNS compatibility: $original → $compatible (same operator, certificate verification enabled).',
      );
      return compatible;
    }
    final uri = Uri.tryParse(original);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'h3')) {
      final host = InternetAddress.tryParse(
        uri.host.replaceAll(RegExp(r'[\[\]]'), ''),
      );
      final identity = uri.fragment.isEmpty
          ? host
          : InternetAddress.tryParse(uri.fragment);
      if (host == null ||
          identity == null ||
          host.address != identity.address) {
        throw const FormatException(
          'RecurseX 0.2.4 requires DoH/DoH3 to use an IP address with a matching IP certificate. '
          'Use a verified IP endpoint or this resolver\'s DoT/DoQ endpoint; custom resolvers are not replaced automatically.',
        );
      }
    }
    return original;
  }

  static Map<String, dynamic> apply(
    Map<String, dynamic> config, {
    void Function(String)? onWarning,
  }) {
    List<String> convert(Object? value) => {
      for (final server in (value as List? ?? const []))
        upstream(server as String, onWarning: onWarning),
    }.toList(growable: false);
    return {
      ...config,
      for (final key in const ['nameservers', 'fallback', 'default_nameserver'])
        key: convert(config[key]),
      'nameserver_policy': {
        for (final entry in (config['nameserver_policy'] as Map).entries)
          entry.key: convert(entry.value),
      },
    };
  }
}
