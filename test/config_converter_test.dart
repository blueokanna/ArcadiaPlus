import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:veloguard/src/services/config_converter.dart';

/// Decodes the converter output into the JSON map corduit will see.
Map<String, dynamic> convert(
  String yaml, {
  void Function(String)? onWarning,
  String? recursiveDnsAddress,
  Map<String, String>? ruleProviderPaths,
}) {
  return jsonDecode(
        ConfigConverter.convertClashYamlToJson(
          yaml,
          onWarning: onWarning,
          recursiveDnsAddress: recursiveDnsAddress,
          ruleProviderPaths: ruleProviderPaths,
        ),
      )
      as Map<String, dynamic>;
}

/// The FFI contract carries protocol options as a JSON string.
Map<String, dynamic> optionsOf(Object? raw) =>
    jsonDecode(raw! as String) as Map<String, dynamic>;

void main() {
  test(
    'a provider with a local copy becomes a file provider for the engine',
    () {
      const yaml = '''
port: 7890
proxies: []
proxy-groups: []
rule-providers:
  proxy:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/proxy.txt
    path: ./ruleset/proxy.yaml
    interval: 86400
rules:
  - RULE-SET,proxy,DIRECT
  - MATCH,DIRECT
''';

      final warnings = <String>[];
      final converted = convert(
        yaml,
        onWarning: warnings.add,
        ruleProviderPaths: const {
          'proxy': '/data/rule-providers/p1/proxy.abcd.rules',
        },
      );
      final providers = converted['rule_providers'] as List<dynamic>;
      final rules = converted['rules'] as List<dynamic>;

      expect(providers, hasLength(1));
      expect(providers.single, {
        'name': 'proxy',
        'type': 'file',
        'behavior': 'domain',
        'path': '/data/rule-providers/p1/proxy.abcd.rules',
        'interval': 86400,
      });
      expect(rules.first, {
        'rule_type': 'rule_set',
        'payload': 'proxy',
        'outbound': 'DIRECT',
        'process_name': null,
      });
      expect(warnings, isEmpty);
    },
  );

  test('a provider without a local copy takes its RULE-SET rules with it', () {
    const yaml = '''
proxies: []
proxy-groups: []
rule-providers:
  proxy:
    type: http
    behavior: domain
    url: https://example.com/proxy.txt
rules:
  - RULE-SET,proxy,REJECT
  - DOMAIN,example.org,DIRECT
  - MATCH,DIRECT
''';

    final warnings = <String>[];
    final converted = convert(yaml, onWarning: warnings.add);
    final providers = converted['rule_providers'] as List<dynamic>;
    final rules = converted['rules'] as List<dynamic>;

    expect(providers, isEmpty);
    expect(rules, hasLength(2));
    expect(
      rules.map((rule) => (rule as Map)['rule_type']),
      isNot(contains('rule_set')),
    );
    expect(warnings.join('\n'), contains('proxy'));
  });

  test('Clash rule modifiers do not corrupt payload or outbound', () {
    const yaml = '''
proxies: []
proxy-groups: []
rules:
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - MATCH,DIRECT
''';

    final rules = convert(yaml)['rules'] as List<dynamic>;

    expect(rules.first, {
      'rule_type': 'ip_cidr',
      'payload': '10.0.0.0/8',
      'outbound': 'DIRECT',
      'process_name': null,
    });
  });

  test('missing MATCH falls back to the first proxy group', () {
    const yaml = '''
proxies:
  - name: node-1
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: PROXY
    type: select
    proxies: [node-1]
rules:
  - DOMAIN-SUFFIX,cn,DIRECT
''';

    final rules = convert(yaml)['rules'] as List<dynamic>;

    expect(rules.last, {
      'rule_type': 'match',
      'payload': '',
      'outbound': 'PROXY',
      'process_name': null,
    });
  });

  test('missing MATCH falls back to the first proxy when no group exists', () {
    const yaml = '''
proxies:
  - name: node-1
    type: socks5
    server: 127.0.0.1
    port: 1080
rules: []
''';

    final rules = convert(yaml)['rules'] as List<dynamic>;

    expect(rules.single['outbound'], 'node-1');
  });

  test('inbounds and outbounds follow the corduit FFI contract', () {
    const yaml = '''
mixed-port: 7897
proxies:
  - name: ss-1
    type: ss
    server: example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: PROXY
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies: [ss-1]
rules:
  - MATCH,PROXY
''';

    final converted = convert(yaml);
    final inbounds = converted['inbounds'] as List<dynamic>;
    final outbounds = converted['outbounds'] as List<dynamic>;

    // Inbounds name their type explicitly and carry an options document.
    expect((inbounds.single as Map)['inbound_type'], 'mixed');
    expect(optionsOf((inbounds.single as Map)['options']), isEmpty);

    final ss = outbounds.firstWhere((o) => (o as Map)['tag'] == 'ss-1') as Map;
    expect(ss['outbound_type'], 'shadowsocks');
    expect(ss['server'], 'example.com');
    expect(ss['port'], 8388);

    final group =
        outbounds.firstWhere((o) => (o as Map)['tag'] == 'PROXY') as Map;
    expect(group['outbound_type'], 'urltest');
    expect(group['server'], isNull);
    expect(optionsOf(group['options']), {
      'outbounds': ['ss-1'],
      'url': 'http://www.gstatic.com/generate_204',
      'interval': 300,
    });
  });

  test('protocol options travel as a JSON string with Clash keys', () {
    const yaml = '''
proxies:
  - name: ss-1
    type: ss
    server: example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret
    udp: true
rules: []
''';

    final outbounds = convert(yaml)['outbounds'] as List<dynamic>;
    final ss = outbounds.firstWhere((o) => (o as Map)['tag'] == 'ss-1') as Map;

    expect(optionsOf(ss['options']), {
      'cipher': 'aes-256-gcm',
      'password': 'secret',
      'udp': true,
    });
  });

  test(
    'protocols corduit cannot build are dropped and references rewritten',
    () {
      const yaml = '''
proxies:
  - name: quic-node
    type: quic
    server: example.com
    port: 443
    password: secret
  - name: ok-node
    type: trojan
    server: example.com
    port: 443
    password: secret
proxy-groups:
  - name: PROXY
    type: select
    proxies: [quic-node, ok-node]
rules:
  - DOMAIN-SUFFIX,example.com,quic-node
  - MATCH,PROXY
''';

      final warnings = <String>[];
      final converted = convert(yaml, onWarning: warnings.add);
      final outbounds = converted['outbounds'] as List<dynamic>;
      final rules = converted['rules'] as List<dynamic>;

      expect(outbounds.where((o) => (o as Map)['tag'] == 'quic-node'), isEmpty);

      final group =
          outbounds.firstWhere((o) => (o as Map)['tag'] == 'PROXY') as Map;
      expect(optionsOf(group['options'])['outbounds'], ['ok-node']);

      expect((rules.first as Map)['outbound'], 'DIRECT');
      expect(warnings, isNotEmpty);
    },
  );

  test('rule types corduit has no rule for are skipped', () {
    const yaml = '''
proxies: []
proxy-groups: []
rules:
  - GEOSITE,category-ads-all,DIRECT
  - MATCH,DIRECT
''';

    final warnings = <String>[];
    final rules =
        convert(yaml, onWarning: warnings.add)['rules'] as List<dynamic>;

    expect(rules, hasLength(1));
    expect((rules.single as Map)['rule_type'], 'match');
    expect(warnings, isNotEmpty);
  });

  test('a running recursive resolver leads the nameserver list', () {
    const yaml = '''
dns:
  nameserver: [1.1.1.1]
proxies: []
proxy-groups: []
rules: []
''';

    final dns =
        convert(yaml, recursiveDnsAddress: '127.0.0.1:5353')['dns'] as Map;

    expect(dns['nameservers'], ['127.0.0.1:5353', '1.1.1.1']);
  });

  test('scalar dns entries survive as single-element lists', () {
    const yaml = '''
dns:
  nameserver: 223.5.5.5
  fallback: 8.8.4.4
  nameserver-policy:
    +.example.com: tcp://10.0.0.1:8080
proxies: []
proxy-groups: []
rules: []
''';

    final dns = convert(yaml)['dns'] as Map;

    expect(dns['nameservers'], ['223.5.5.5']);
    expect(dns['fallback'], ['8.8.4.4']);
    expect(dns['nameserver_policy'], {
      '+.example.com': ['tcp://10.0.0.1:8080'],
    });
  });
}
