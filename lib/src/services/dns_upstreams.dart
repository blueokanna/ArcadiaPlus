/// How the engine reaches an upstream resolver.
///
/// The badges are protocol names (`DoH`, `DoT`, `DoQ`, `UDP`), which are the
/// same in every locale — translating them would make them harder to recognise,
/// not easier — so they are not part of the string catalogue on purpose.
enum DnsUpstreamKind {
  /// DNS over HTTPS: `https://dns.example/dns-query`.
  doh('DoH'),

  /// DNS over HTTP/3: `h3://dns.example/dns-query`.
  doh3('DoH3'),

  /// DNS over TLS: `tls://1.1.1.1`.
  dot('DoT'),

  /// DNS over QUIC: `quic://dns.example`.
  quic('DoQ'),

  /// Plain UDP/TCP to a literal address (`1.1.1.1`, `1.1.1.1:5353`).
  plain('UDP'),

  /// The platform's own resolver (`system://`).
  system('System'),

  /// A DHCP-advertised resolver (`dhcp://eth0`).
  dhcp('DHCP'),

  /// Neither a known scheme nor an address literal. Still stored and handed to
  /// the engine untouched: the engine is the authority on what it accepts, and
  /// refusing here would turn "this build does not recognise it" into "you may
  /// not use it".
  unknown('?');

  const DnsUpstreamKind(this.badge);

  /// Short label for the editor, e.g. `DoH`.
  final String badge;
}

final RegExp _ipv4Literal = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');
final RegExp _ipv6Literal = RegExp(r'^[0-9a-f:]+$');

/// Classifies an upstream address the way the engine would read it.
///
/// The scheme decides everything when there is one; without a scheme only an
/// address literal is a usable upstream, because a bare hostname would have to
/// be resolved before it could resolve anything.
DnsUpstreamKind classifyUpstream(String address) {
  final value = address.trim().toLowerCase();
  if (value.isEmpty) return DnsUpstreamKind.unknown;

  final schemeEnd = value.indexOf('://');
  if (schemeEnd > 0) {
    return switch (value.substring(0, schemeEnd)) {
      'http' || 'https' => DnsUpstreamKind.doh,
      'h3' => DnsUpstreamKind.doh3,
      'tls' => DnsUpstreamKind.dot,
      'quic' => DnsUpstreamKind.quic,
      'system' => DnsUpstreamKind.system,
      'dhcp' => DnsUpstreamKind.dhcp,
      _ => DnsUpstreamKind.unknown,
    };
  }

  return isAddressLiteral(value)
      ? DnsUpstreamKind.plain
      : DnsUpstreamKind.unknown;
}

/// Whether [value] is a bare IPv4/IPv6 literal, with or without a port.
bool isAddressLiteral(String value) {
  final host = _hostOf(value.trim().toLowerCase());
  if (host.isEmpty) return false;
  if (_ipv4Literal.hasMatch(host)) {
    return host.split('.').every((part) => (int.tryParse(part) ?? 256) <= 255);
  }
  // An IPv6 literal needs a colon, so a bare `abcd` is not mistaken for one.
  return host.contains(':') && _ipv6Literal.hasMatch(host);
}

/// Whether [address] points back at this machine.
///
/// Used to keep the platform's own resolver out of the upstream list: on
/// systems where the OS resolver is the proxy's own DNS listener (systemd's
/// `127.0.0.53` stub, or this app's `dns.listen`), appending it would make the
/// engine query itself.
bool isLoopbackLiteral(String address) {
  final host = _hostOf(address.trim().toLowerCase());
  if (host == '::1') return true;
  if (!_ipv4Literal.hasMatch(host)) return false;
  return host.startsWith('127.');
}

/// Strips a port (and the brackets around an IPv6 host) from [value].
String _hostOf(String value) {
  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end > 0) return value.substring(1, end);
  }
  final colon = value.indexOf(':');
  // More than one colon means an unbracketed IPv6 literal, not `host:port`.
  if (colon > 0 && value.indexOf(':', colon + 1) == -1) {
    return value.substring(0, colon);
  }
  return value;
}

/// What kind of resolver a preset is, for the badge shown on its chip.
enum DnsPresetTag {
  /// A resolver to reach for first: fast, well-run, widely reachable.
  recommended,

  /// Picked for a no-logging policy.
  privacy,

  /// Filters adult content, ads, or both at the resolver.
  family,

  /// Reachable from mainland China without a proxy in front of it.
  domestic,
}

/// One resolver the editor can add without making the user type it.
class DnsPreset {
  const DnsPreset(this.address, this.label, this.tag);

  /// Exactly what is written into `nameservers` / `fallback`.
  final String address;

  /// Brand name of the operator. A proper noun, so it stays untranslated.
  final String label;

  final DnsPresetTag tag;

  /// How the engine will reach this address.
  DnsUpstreamKind get kind => classifyUpstream(address);
}

/// The resolvers offered in the nameserver/fallback editor.
///
/// Every entry is a published endpoint of the operator named next to it. The
/// list is deliberately short: it is a starting point for people who do not
/// already know which resolver they want, not a directory.
const List<DnsPreset> dnsPresets = [
  DnsPreset(
    'https://dns.cloudflare.com/dns-query',
    'Cloudflare',
    DnsPresetTag.recommended,
  ),
  DnsPreset(
    'https://dns.google/dns-query',
    'Google Public DNS',
    DnsPresetTag.recommended,
  ),
  DnsPreset('tls://1.1.1.1', 'Cloudflare', DnsPresetTag.privacy),
  DnsPreset('https://dns.quad9.net/dns-query', 'Quad9', DnsPresetTag.privacy),
  DnsPreset(
    'https://dns.adguard-dns.com/dns-query',
    'AdGuard DNS',
    DnsPresetTag.family,
  ),
  DnsPreset(
    'https://doh.opendns.com/dns-query',
    'OpenDNS',
    DnsPresetTag.family,
  ),
  DnsPreset('https://doh.pub/dns-query', 'DNSPod', DnsPresetTag.domestic),
  DnsPreset(
    'https://dns.alidns.com/dns-query',
    'Alibaba Public DNS',
    DnsPresetTag.domestic,
  ),
  DnsPreset('119.29.29.29', 'DNSPod', DnsPresetTag.domestic),
  DnsPreset('223.5.5.5', 'Alibaba Public DNS', DnsPresetTag.domestic),
];
