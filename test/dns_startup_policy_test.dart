import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/encrypted_dns_policy.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/providers/dns_settings_provider.dart';

import 'dart:convert';

void main() {
  test('preferred encryption preserves private routes and local recursion', () {
    final dns =
        jsonDecode(
              ConfigConverter.convertClashYamlToJson(
                '''
dns:
  nameserver: [119.29.29.29, 223.5.5.5]
  default-nameserver: [114.114.114.114]
  nameserver-policy:
    '+.private.example': tcp://private.example:8080
rules: ['MATCH,DIRECT']
''',
                dnsSettings: DnsSettings(
                  preferEncryptedDns: true,
                  useRecursiveResolver: true,
                ),
                recursiveDnsAddress: '127.0.0.1:5353',
                requireCompleteRules: true,
              ),
            )['dns']
            as Map;
    expect(dns['nameservers'], [
      '127.0.0.1:5353',
      'tls://1.12.12.12#dot.pub',
      'https://223.5.5.5/dns-query',
    ]);
    expect(dns['default_nameserver'], ['114.114.114.114']);
    expect(dns['nameserver_policy']['+.private.example'], [
      'tcp://private.example:8080',
    ]);
  });

  test(
    'preference and strict switches persist distinct privacy choices',
    () async {
      final writes = <DnsSettings>[];
      final provider = DnsSettingsProvider(
        read: () async => DnsSettings(useRecursiveResolver: true),
        write: (settings) async => writes.add(settings),
      );
      addTearDown(provider.dispose);
      await provider.setPreferEncryptedDns(true);
      expect(provider.useRecursiveResolver, true);
      expect(provider.requireEncryptedDns, false);
      await provider.setRequireEncryptedDns(true);
      expect(provider.requireEncryptedDns, true);
      expect(provider.useRecursiveResolver, false);
      await provider.setRequireEncryptedDns(false);
      expect(provider.preferEncryptedDns, true);
      expect(provider.useRecursiveResolver, false);
      final restored = DnsSettings.fromJson(writes.last.toJson());
      expect(restored.preferEncryptedDns, true);
      expect(restored.requireEncryptedDns, false);
    },
  );
  test('fresh and legacy preferences honor subscriptions; explicit protection survives', () {
    expect(DnsSettings().requireEncryptedDns, false);
    expect(DnsSettings.fromJson({}).requireEncryptedDns, false);
    for (final selected in [true, false]) {
      expect(
        DnsSettings.fromJson(
          DnsSettings(requireEncryptedDns: selected).toJson(),
        ).requireEncryptedDns,
        selected,
      );
    }
  });

  test(
    'public DNSPod upgrades primary and bootstrap with a verified TLS identity',
    () {
      final dns = EncryptedDnsPolicy.apply({
        'nameservers': ['119.29.29.29'],
        'default_nameserver': ['119.29.29.29'],
        'nameserver_policy': <String, List<String>>{},
      });
      expect(dns['nameservers'], ['tls://1.12.12.12#dot.pub']);
      expect(dns['default_nameserver'], dns['nameservers']);
    },
  );

  test(
    'preflight reports all incompatible paths and never leaks URI credentials',
    () {
      const profile = '''
dns:
  nameserver: [119.29.29.29]
  default-nameserver: [114.114.114.114]
  nameserver-policy:
    '+.private.example': tcp://private.example:8080
    '+.auth.example': tcp://user:secret@private.example:53
''';
      expect(
        () => ConfigConverter.validateDns(
          profile,
          DnsSettings(requireEncryptedDns: true),
        ),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('default-nameserver') &&
                e.toString().contains('nameserver-policy') &&
                !e.toString().contains('secret'),
          ),
        ),
      );
      ConfigConverter.validateDns(profile, DnsSettings());
    },
  );
}
