import 'dart:convert';

import 'package:arcadiaplus/src/providers/dns_settings_provider.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/encrypted_dns_policy.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> convert(String dns) =>
      jsonDecode(
            ConfigConverter.convertClashYamlToJson(
              'dns:\n$dns\nrules: ["MATCH,DIRECT"]',
              dnsSettings: DnsSettings(),
              requireCompleteRules: true,
              systemDnsServers: ['192.168.1.1'],
              recursiveDnsAddress: '127.0.0.1:5353',
            ),
          )['dns']
          as Map<String, dynamic>;

  test('all roles reject plaintext private servers instead of redirecting', () {
    for (final role in ['nameserver', 'fallback', 'default-nameserver']) {
      expect(() => convert('  $role: [192.168.1.1]'), throwsException);
    }
    expect(
      () => convert('''
  nameserver: [https://1.1.1.1/dns-query]
  nameserver-policy:
    '+.private.test': [tcp://192.168.1.1]
'''),
      throwsException,
    );
  });

  test(
    'bootstrap stays with the selected resolver and no routes are added',
    () {
      final dns = convert('  nameserver: [https://dns.google/dns-query]');
      expect(dns['nameservers'], ['https://8.8.8.8/dns-query']);
      expect(dns['default_nameserver'], dns['nameservers']);
      expect(dns['nameserver_policy'], isEmpty);
      expect(dns['fallback'], isEmpty);
      expect(jsonEncode(dns), isNot(contains('192.168.1.1')));
      expect(jsonEncode(dns), isNot(contains('127.0.0.1:5353')));
    },
  );

  test(
    'hostname-only private resolver requires explicit encrypted bootstrap',
    () {
      expect(
        () => convert('  nameserver: [tls://private.test]'),
        throwsException,
      );
      final dns = convert('''
  nameserver: [tls://private.test]
  default-nameserver: [https://1.1.1.1/dns-query]
  fallback-filter:
    domain: ['+.fallback.test']
  fallback: [tls://other.private.test]
''');
      expect(dns['nameservers'], ['tls://private.test']);
      expect(dns['fallback_filter']['domain'], ['+.fallback.test']);
    },
  );

  test(
    'endpoint syntax cannot be accepted here and silently lost by the core',
    () {
      for (final endpoint in [
        'tls://1.1.1.1/path',
        'quic://1.1.1.1?query',
        'tls://1.1.1.1:0',
        'tls://1.1.1.1:65536',
        'tls://1.1.1.1#',
        'https://user:password@1.1.1.1/dns-query',
        'https://1.1.1.1?without-path',
        'tls://.invalid',
        'tls://invalid.',
        'https://1.1.1.1/\u0000',
      ]) {
        expect(EncryptedDnsPolicy.accepts(endpoint), false, reason: endpoint);
      }
      expect(
        EncryptedDnsPolicy.accepts(
          'tls://[2606:4700:4700::1111]#cloudflare-dns.com',
          literal: true,
        ),
        true,
      );
    },
  );

  test(
    'privacy selection cannot silently reactivate previous root recursion',
    () async {
      final saved = <DnsSettings>[];
      final provider = DnsSettingsProvider(
        read: () async =>
            DnsSettings(requireEncryptedDns: false, useRecursiveResolver: true),
        write: (s) async => saved.add(s),
      );
      addTearDown(provider.dispose);
      await provider.setRequireEncryptedDns(true);
      await provider.setRequireEncryptedDns(false);
      expect(provider.useRecursiveResolver, false);
      expect(saved.every((s) => !s.useRecursiveResolver), true);
      await provider.setRequireEncryptedDns(true);
      await provider.setUseRecursiveResolver(true);
      expect(provider.settings.useRecursiveResolver, false);
      expect(provider.saveError, contains('Disable encrypted'));
    },
  );
}
