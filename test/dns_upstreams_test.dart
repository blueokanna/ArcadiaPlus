import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/dns_upstreams.dart';

void main() {
  group('upstream classification', () {
    test('reads the scheme, not the host name', () {
      expect(
        classifyUpstream('https://dns.google/dns-query'),
        DnsUpstreamKind.doh,
      );
      expect(
        classifyUpstream('h3://dns.google/dns-query'),
        DnsUpstreamKind.doh3,
      );
      expect(classifyUpstream('tls://1.1.1.1'), DnsUpstreamKind.dot);
      expect(classifyUpstream('quic://dns.adguard.com'), DnsUpstreamKind.quic);
      expect(classifyUpstream('system://'), DnsUpstreamKind.system);
      expect(classifyUpstream('dhcp://eth0'), DnsUpstreamKind.dhcp);
    });

    test('scheme matching ignores case and surrounding space', () {
      expect(
        classifyUpstream('  HTTPS://dns.example/x  '),
        DnsUpstreamKind.doh,
      );
      expect(classifyUpstream('TLS://1.1.1.1'), DnsUpstreamKind.dot);
    });

    test('a bare literal is plain UDP, a bare host name is not an upstream', () {
      expect(classifyUpstream('1.1.1.1'), DnsUpstreamKind.plain);
      expect(classifyUpstream('1.1.1.1:5353'), DnsUpstreamKind.plain);
      expect(classifyUpstream('[::1]:53'), DnsUpstreamKind.plain);
      expect(classifyUpstream('fe80::1'), DnsUpstreamKind.plain);

      // Resolving this would be the very problem the list exists to avoid.
      expect(classifyUpstream('dns.example.com'), DnsUpstreamKind.unknown);
      expect(classifyUpstream(''), DnsUpstreamKind.unknown);
      // An unknown scheme is reported as unknown rather than guessed at, and is
      // still stored: the engine decides what it accepts.
      expect(classifyUpstream('sdns://AQcAAAAA'), DnsUpstreamKind.unknown);
    });

    test('an octet above 255 is not an address', () {
      expect(isAddressLiteral('256.1.1.1'), isFalse);
      expect(isAddressLiteral('1.1.1.1'), isTrue);
      expect(isAddressLiteral('abcd'), isFalse);
    });
  });

  group('loopback detection', () {
    test('covers the whole 127/8 block and IPv6 loopback', () {
      expect(isLoopbackLiteral('127.0.0.1'), isTrue);
      expect(isLoopbackLiteral('127.0.0.53'), isTrue);
      expect(isLoopbackLiteral('127.1.2.3:53'), isTrue);
      expect(isLoopbackLiteral('[::1]:53'), isTrue);
      expect(isLoopbackLiteral('::1'), isTrue);
      expect(isLoopbackLiteral('192.168.1.1'), isFalse);
      expect(isLoopbackLiteral('1.1.1.1'), isFalse);
      // 1270.0.0.1 is not an address at all, so it cannot be loopback either.
      expect(isLoopbackLiteral('1270.0.0.1'), isFalse);
    });
  });

  group('preset catalogue', () {
    test('every entry is a usable address, listed once', () {
      final addresses = dnsPresets.map((preset) => preset.address).toList();
      expect(addresses.toSet(), hasLength(addresses.length));

      for (final preset in dnsPresets) {
        expect(
          preset.kind,
          isNot(DnsUpstreamKind.unknown),
          reason: '${preset.address} is not a form this app can name',
        );
        expect(preset.label, isNotEmpty);
      }
    });

    test('each group has something to offer', () {
      for (final tag in DnsPresetTag.values) {
        expect(
          dnsPresets.where((preset) => preset.tag == tag),
          isNotEmpty,
          reason: '$tag has no preset, so its row would render empty',
        );
      }
    });
  });
}
