import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/dns_transport_compatibility.dart';
import 'package:arcadiaplus/src/services/dns_upstreams.dart';
import 'package:arcadiaplus/src/services/encrypted_dns_policy.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults and presets are supported without transport substitution', () {
    for (final address in [
      ...DnsSettings.defaultNameservers,
      ...EncryptedDnsPolicy.defaults,
      ...dnsPresets.map((preset) => preset.address),
    ]) {
      expect(DnsTransportCompatibility.upstream(address), address);
    }
  });

  test(
    'previous untouched defaults migrate while private choices are preserved',
    () {
      final migrated = DnsSettings(
        nameserversRevision: 3,
        nameservers: [
          'https://223.5.5.5/dns-query#dns.alidns.com',
          'https://223.6.6.6/dns-query#dns.alidns.com',
          'https://doh.pub/dns-query',
        ],
      ).withCurrentNameserverDefaults();
      expect(migrated.nameservers, DnsSettings.defaultNameservers);
      final custom = DnsSettings(
        nameserversRevision: 3,
        nameservers: ['https://private.example/dns-query'],
      );
      expect(
        custom.withCurrentNameserverDefaults().nameservers,
        custom.nameservers,
      );
    },
  );

  test('all DNS roles receive compatibility handling with warnings', () {
    final warnings = <String>[];
    final result = DnsTransportCompatibility.apply({
      'nameservers': ['https://dns.google/dns-query'],
      'fallback': ['https://doh.pub/dns-query'],
      'default_nameserver': ['https://223.5.5.5/dns-query#dns.alidns.com'],
      'nameserver_policy': {
        '+.example': ['https://dns.quad9.net/dns-query'],
      },
    }, onWarning: warnings.add);
    expect(result['nameservers'], ['https://8.8.8.8/dns-query']);
    expect(result['fallback'], ['tls://dot.pub']);
    expect(result['default_nameserver'], [EncryptedDnsPolicy.defaults.first]);
    expect(result['nameserver_policy']['+.example'], ['tls://dns.quad9.net']);
    expect(warnings, hasLength(4));
  });

  test(
    'runtime refuses unknown DoH identities without replacing private DNS',
    () {
      for (final address in [
        'https://private.example/dns-query',
        'https://1.1.1.1/dns-query#wrong.example',
        'h3://private.example/dns-query',
      ]) {
        expect(
          () => ConfigConverter.convertClashYamlToJson('''
dns:
  nameserver: [$address]
rules: ['MATCH,DIRECT']
''', requireCompleteRules: true),
          throwsException,
        );
      }
      expect(
        DnsTransportCompatibility.upstream('tls://private.example'),
        'tls://private.example',
      );
    },
  );
}
