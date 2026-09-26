import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';

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
  ) as Map<String, dynamic>;
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

  test('Clash rule modifiers keep no-resolve and never corrupt payload', () {
    const yaml = '''
proxies: []
proxy-groups: []
rules:
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - DOMAIN-SUFFIX,example.com,DIRECT,some-future-flag
  - MATCH,DIRECT
''';

    final rules = convert(yaml)['rules'] as List<dynamic>;

    // `no-resolve` is part of the rule's meaning — an IP rule carrying it may
    // only see an address the client supplied, and it is what lets the router
    // skip the lookup entirely — so it travels with the rule.
    expect(rules[0], {
      'rule_type': 'ip_cidr',
      'payload': '10.0.0.0/8',
      'outbound': 'DIRECT',
      'process_name': null,
      'no_resolve': true,
    });
    // A modifier this layer does not know must not leak into payload or
    // outbound: it is dropped, and the rule still means what it said.
    expect(rules[1], {
      'rule_type': 'domain_suffix',
      'payload': 'example.com',
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

  test('hysteria v1 nodes reach the engine in its own option spelling', () {
    const yaml = '''
proxies:
  - name: hy1
    type: hysteria
    server: example.com
    port: 8443
    auth_str: s3cret
    up: "50 Mbps"
    down: "200 Mbps"
    obfs: xplus
    obfs-password: hunter2
    sni: cdn.example.com
    skip-cert-verify: true
rules: []
''';

    final outbounds = convert(yaml)['outbounds'] as List<dynamic>;
    final node = outbounds.firstWhere((o) => (o as Map)['tag'] == 'hy1') as Map;

    expect(node['outbound_type'], 'hysteria');
    expect(node['server'], 'example.com');
    expect(node['port'], 8443);
    expect(optionsOf(node['options']), {
      'auth-str': 's3cret',
      'up': 50,
      'down': 200,
      'obfs': 'hunter2',
      'sni': 'cdn.example.com',
      'skip-cert-verify': true,
    });
  });

  test("SSR nodes move obfs-param onto the engine's obfs-host", () {
    const yaml = '''
proxies:
  - name: ssr1
    type: ssr
    server: example.com
    port: 8388
    cipher: aes-256-cfb
    password: secret
    protocol: auth_sha1_v4
    protocol-param: "user:pass"
    obfs: http_simple
    obfs-param: bing.com
rules: []
''';

    final outbounds = convert(yaml)['outbounds'] as List<dynamic>;
    final node =
        outbounds.firstWhere((o) => (o as Map)['tag'] == 'ssr1') as Map;

    expect(node['outbound_type'], 'ssr');
    expect(optionsOf(node['options']), {
      'cipher': 'aes-256-cfb',
      'password': 'secret',
      'protocol': 'auth_sha1_v4',
      'protocol-param': 'user:pass',
      'obfs': 'http_simple',
      'obfs-host': 'bing.com',
    });
  });

  test('snell nodes unwrap obfs-opts into mode and host', () {
    const yaml = '''
proxies:
  - name: snell1
    type: snell
    server: example.com
    port: 443
    psk: secret
    version: 4
    obfs-opts:
      mode: http
      host: bing.com
rules: []
''';

    final outbounds = convert(yaml)['outbounds'] as List<dynamic>;
    final node =
        outbounds.firstWhere((o) => (o as Map)['tag'] == 'snell1') as Map;

    expect(node['outbound_type'], 'snell');
    expect(optionsOf(node['options']), {
      'psk': 'secret',
      'version': 4,
      'obfs': 'http',
      'obfs-host': 'bing.com',
    });
  });

  test('a Shadowsocks node carrying a plugin is refused, plugin named', () {
    const yaml = '''
proxies:
  - name: st-node
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: secret
    plugin: shadow-tls
    plugin-opts:
      host: www.bing.com
      password: tls-secret
      version: 3
  - name: ok-node
    type: ss
    server: example.com
    port: 8389
    cipher: aes-128-gcm
    password: secret
proxy-groups:
  - name: PROXY
    type: select
    proxies: [st-node, ok-node]
rules: []
''';

    final warnings = <String>[];
    final converted = convert(yaml, onWarning: warnings.add);
    final outbounds = converted['outbounds'] as List<dynamic>;

    expect(outbounds.where((o) => (o as Map)['tag'] == 'st-node'), isEmpty);
    expect(warnings.any((w) => w.contains('shadow-tls')), isTrue);

    final group =
        outbounds.firstWhere((o) => (o as Map)['tag'] == 'PROXY') as Map;
    expect(optionsOf(group['options'])['outbounds'], ['ok-node']);
  });

  test('the advertised protocol list covers every mapped outbound', () {
    expect(
      ConfigConverter.supportedProtocols,
      containsAll(<String>[
        'Shadowsocks',
        'ShadowsocksR',
        'VMess',
        'VLESS',
        'Trojan',
        'Hysteria',
        'Hysteria2',
        'TUIC',
        'Snell',
        'WireGuard',
        'HTTP / HTTPS',
        'SOCKS5',
      ]),
    );
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

  test('appended platform resolvers follow the configured ones, once each', () {
    const yaml = '''
dns:
  nameserver: [1.1.1.1]
proxies: []
proxy-groups: []
rules: []
''';

    final dns =
        jsonDecode(
              ConfigConverter.convertClashYamlToJson(
                yaml,
                // `append system DNS` has no key of its own in the engine's
                // config, so the setting is expressed by adding the platform's
                // resolvers to this list. Order is the point: what the user
                // configured is asked first.
                systemDnsServers: const ['192.168.1.1', '1.1.1.1'],
              ),
            )['dns']
            as Map;

    expect(dns['nameservers'], ['1.1.1.1', '192.168.1.1']);
  });

  test('platform resolvers stay behind a local recursive resolver', () {
    const yaml = '''
dns:
  nameserver: [1.1.1.1]
proxies: []
proxy-groups: []
rules: []
''';

    final dns =
        jsonDecode(
              ConfigConverter.convertClashYamlToJson(
                yaml,
                recursiveDnsAddress: '127.0.0.1:5353',
                systemDnsServers: const ['192.168.1.1'],
              ),
            )['dns']
            as Map;

    expect(dns['nameservers'], ['127.0.0.1:5353', '1.1.1.1', '192.168.1.1']);
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

  test('fake-ip range, filter, cache size and hosts reach the engine', () {
    const yaml = '''
dns:
  enhanced-mode: fake-ip
  fake-ip-range: 198.19.0.0/16
  fake-ip-filter: ['+.lan', 'time.example']
  cache-size: 4096
  hosts:
    static.example: 203.0.113.9
    listed.example: ['203.0.113.10', '203.0.113.11']
proxies: []
proxy-groups: []
rules: []
''';

    final dns = convert(yaml)['dns'] as Map;

    expect(dns['fake_ip_range'], '198.19.0.0/16');
    expect(dns['fake_ip_filter'], ['+.lan', 'time.example']);
    expect(dns['cache_size'], 4096);
    expect(dns['hosts'], {
      'static.example': '203.0.113.9',
      'listed.example': '203.0.113.10',
    });
  });

  test('a profile without these keys leaves them to the engine defaults', () {
    const yaml = '''
dns:
  nameserver: [1.1.1.1]
proxies: []
proxy-groups: []
rules: []
''';

    final dns = convert(yaml)['dns'] as Map;

    // Absent rather than sent as a zero value: an empty range or a cache size of
    // zero would replace the engine's own defaults with something unusable.
    expect(dns.containsKey('fake_ip_range'), isFalse);
    expect(dns.containsKey('fake_ip_filter'), isFalse);
    expect(dns.containsKey('cache_size'), isFalse);
    expect(dns.containsKey('hosts'), isFalse);
  });

  test('the general section carries only what the engine reads', () {
    const yaml = '''
port: 7890
socks-port: 7891
mixed-port: 7892
redir-port: 7893
tproxy-port: 7894
bind-address: 127.0.0.1
proxies: []
proxy-groups: []
rules: []
''';

    final general = convert(yaml)['general'] as Map;
    expect(general.containsKey('port'), isFalse);
    expect(general.containsKey('redir_port'), isFalse);
    expect(general.containsKey('tproxy_port'), isFalse);
    expect(general['socks_port'], 7891);
    expect(general['mixed_port'], 7892);
    expect(general['bind_address'], '127.0.0.1');
  });

  test('a transparent-proxy port says it is unsupported', () {
    const yaml = '''
redir-port: 7893
proxies: []
proxy-groups: []
rules: []
''';

    final warnings = <String>[];
    convert(yaml, onWarning: warnings.add);

    expect(
      warnings.any((w) => w.contains('redir-port') && w.contains('no effect')),
      isTrue,
      reason: 'a setting with no implementation must say so: $warnings',
    );
  });

  test('a cache size of zero counts as absent', () {
    const yaml = '''
dns:
  cache-size: 0
proxies: []
proxy-groups: []
rules: []
''';

    expect((convert(yaml)['dns'] as Map).containsKey('cache_size'), isFalse);
  });

  test('a nonsense fake-ip range is still forwarded for the engine to judge', () {
    const yaml = '''
dns:
  fake-ip-range: not-a-cidr
proxies: []
proxy-groups: []
rules: []
''';

    // This layer does not decide CIDR validity: the engine validates the pool
    // and reports the offending value, and duplicating that rule here would let
    // the two drift apart.
    expect((convert(yaml)['dns'] as Map)['fake_ip_range'], 'not-a-cidr');
  });

  test("a profile that names no mode gets mihomo's default, not fake-ip", () {
    const yaml = '''
dns:
  nameserver: [1.1.1.1]
proxies: []
proxy-groups: []
rules: []
''';

    // mihomo's default behaviour is real answers, which this engine spells
    // `normal`. The engine knows nothing of `redir-host`, and a value it cannot
    // read fails the whole config — so the vocabulary is translated here.
    expect((convert(yaml)['dns'] as Map)['enhanced_mode'], 'normal');
  });

  test('every spelling of the DNS mode lands on the engine word', () {
    Map<String, dynamic> dnsOf(String mode) {
      final yaml =
          '''
dns:
  enhanced-mode: $mode
proxies: []
proxy-groups: []
rules: []
''';
      return convert(yaml)['dns'] as Map<String, dynamic>;
    }

    for (final mode in ['redir-host', 'REDIR-HOST', 'redir_host', 'redir']) {
      expect(dnsOf(mode)['enhanced_mode'], 'normal', reason: mode);
    }
    for (final mode in ['fake-ip', 'fakeip', 'FAKE-IP']) {
      expect(dnsOf(mode)['enhanced_mode'], 'fake-ip', reason: mode);
    }

    final warnings = <String>[];
    const unknown = '''
dns:
  enhanced-mode: host-redirect
proxies: []
proxy-groups: []
rules: []
''';
    final dns =
        convert(unknown, onWarning: warnings.add)['dns']
            as Map<String, dynamic>;
    expect(dns['enhanced_mode'], 'normal');
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('host-redirect'));
  });

  test('the routing mode is folded to the engine vocabulary', () {
    Map<String, dynamic> generalOf(String mode) {
      final yaml =
          '''
mode: $mode
proxies: []
proxy-groups: []
rules: []
''';
      return convert(yaml)['general'] as Map<String, dynamic>;
    }

    // Subscriptions write `Rule`, `GLOBAL`, and the like; the engine's
    // vocabulary is exact and it rejects the whole document over one word.
    expect(generalOf('Rule')['mode'], 'rule');
    expect(generalOf('GLOBAL')['mode'], 'global');
    expect(generalOf('direct')['mode'], 'direct');

    final warnings = <String>[];
    final general =
        convert('''
mode: script
proxies: []
proxy-groups: []
rules: []
''', onWarning: warnings.add)['general']
            as Map<String, dynamic>;
    expect(general['mode'], 'rule');
    expect(warnings.any((w) => w.contains('script')), isTrue);
  });

  test('the log level is folded to the engine vocabulary', () {
    Map<String, dynamic> generalOf(String level) {
      final yaml =
          '''
log-level: $level
proxies: []
proxy-groups: []
rules: []
''';
      return convert(yaml)['general'] as Map<String, dynamic>;
    }

    expect(generalOf('INFO')['log_level'], 'info');
    expect(generalOf('warn')['log_level'], 'warning');
    expect(generalOf('Debug')['log_level'], 'debug');
  });

  test('an explicit mode still wins over the default', () {
    const yaml = '''
dns:
  enhanced-mode: fake-ip
proxies: []
proxy-groups: []
rules: []
''';

    expect((convert(yaml)['dns'] as Map)['enhanced_mode'], 'fake-ip');
  });

  test('fake-ip-ttl is forwarded, and zero counts as absent', () {
    const withTtl = '''
dns:
  fake-ip-ttl: 1
proxies: []
proxy-groups: []
rules: []
''';
    expect((convert(withTtl)['dns'] as Map)['fake_ip_ttl'], 1);

    const zeroTtl = '''
dns:
  fake-ip-ttl: 0
proxies: []
proxy-groups: []
rules: []
''';
    expect(
      (convert(zeroTtl)['dns'] as Map).containsKey('fake_ip_ttl'),
      isFalse,
    );
  });

  test('default-nameserver and fallback-filter travel with the profile', () {
    const yaml = '''
dns:
  default-nameserver: [223.5.5.5]
  fallback:
    - tls://1.1.1.1
  fallback-filter:
    geoip: true
    geoip-code: US
    ipcidr: [240.0.0.0/4]
    domain: [example.com]
proxies: []
proxy-groups: []
rules: []
''';

    final dns = convert(yaml)['dns'] as Map;

    // `default-nameserver` bootstraps an upstream named by hostname, and the
    // filter decides when an answer is suspect; both are profile knowledge the
    // app's own DNS screen cannot express, so both pass through unchanged.
    expect(dns['default_nameserver'], ['223.5.5.5']);
    expect(dns['fallback'], ['tls://1.1.1.1']);
    expect(dns['fallback_filter'], {
      'geoip': true,
      'geoip_code': 'US',
      'ipcidr': ['240.0.0.0/4'],
      'domain': ['example.com'],
    });
  });

  test('use-hosts: false keeps the hosts table out of the config', () {
    const yaml = '''
dns:
  use-hosts: false
  hosts:
    static.example: 203.0.113.9
proxies: []
proxy-groups: []
rules: []
''';

    final dns = convert(yaml)['dns'] as Map;
    expect(dns['use_hosts'], false);
    expect(dns.containsKey('hosts'), isFalse);
  });

  test(
    'GEOSITE works through a provider of that name, and is skipped without one',
    () {
      const yaml = '''
proxies: []
proxy-groups: []
rule-providers:
  cn:
    type: http
    behavior: domain
    url: https://example.com/cn.txt
rules:
  - GEOSITE,cn,DIRECT
  - GEOSITE,geolocation-!cn,REJECT
  - MATCH,DIRECT
''';

      final warnings = <String>[];
      final rules =
          convert(
                yaml,
                onWarning: warnings.add,
                ruleProviderPaths: const {'cn': '/data/rules/cn.txt'},
              )['rules']
              as List<dynamic>;

      // The engine reads a geosite category as a rule-provider name: the entry
      // is usable when the profile itself defines a provider under that name...
      expect(rules[0], {
        'rule_type': 'geosite',
        'payload': 'cn',
        'outbound': 'DIRECT',
        'process_name': null,
      });
      // ...and must be skipped, loudly, when nothing can answer for it.
      expect(
        rules.where((rule) => (rule as Map)['rule_type'] == 'geosite'),
        hasLength(1),
      );
      expect(warnings.join('\n'), contains('geolocation-!cn'));
    },
  );

  test('inbound rules carry their payload and target through', () {
    const yaml = '''
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
rules:
  - IN-PORT,7897,PROXY
  - IN-TYPE,SOCKS5,PROXY
  - IN-USER,alice,PROXY
  - IN-NAME,mixed,PROXY
  - MATCH,DIRECT
''';

    final rules = convert(yaml)['rules'] as List<dynamic>;

    // The engine matches these case-insensitively and against the inbound's
    // own identity, so the payload travels as written and the target is the
    // group the profile named.
    expect((rules[0] as Map)['rule_type'], 'in_port');
    expect((rules[0] as Map)['payload'], '7897');
    expect((rules[0] as Map)['outbound'], 'PROXY');
    expect((rules[1] as Map)['rule_type'], 'in_type');
    expect((rules[1] as Map)['payload'], 'SOCKS5');
    expect((rules[2] as Map)['rule_type'], 'in_user');
    expect((rules[2] as Map)['payload'], 'alice');
    expect((rules[3] as Map)['rule_type'], 'in_name');
    expect((rules[3] as Map)['payload'], 'mixed');
  });

  test('logical rules become nested conditions instead of being dropped', () {
    const yaml = '''
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
rules:
  - AND,((DOMAIN-SUFFIX,google.com),(NETWORK,tcp)),PROXY
  - OR,((DST-PORT,80,443),(NOT,((DOMAIN-KEYWORD,ads)))),PROXY
  - MATCH,DIRECT
''';

    final warnings = <String>[];
    final rules =
        convert(yaml, onWarning: warnings.add)['rules'] as List<dynamic>;

    expect(warnings, isEmpty);

    // The condition keeps its bracket structure: an AND of a domain and a
    // network child, each with the type the engine knows and the target the
    // profile named.
    final logical = rules[0] as Map;
    expect(logical['rule_type'], 'and');
    expect(logical['payload'], '');
    expect(logical['outbound'], 'PROXY');
    final children = (logical['rules'] as List).cast<Map>();
    expect(children, hasLength(2));
    expect(children[0]['type'], 'domain_suffix');
    expect(children[0]['payload'], 'google.com');
    expect(children[1]['type'], 'network');
    expect(children[1]['payload'], 'tcp');
    expect(children.every((child) => child['outbound'] == 'PROXY'), isTrue);

    // A port list inside one condition stays in that condition, and a nested
    // NOT is converted in place.
    final or = rules[1] as Map;
    expect(or['rule_type'], 'or');
    final orChildren = (or['rules'] as List).cast<Map>();
    expect(orChildren[0]['type'], 'dst_port');
    expect(orChildren[0]['payload'], '80,443');
    final negated = orChildren[1];
    expect(negated['type'], 'not');
    expect((negated['rules'] as List).single['payload'], 'ads');
  });

  test(
    'a logical rule with an unreadable condition is skipped, not half-kept',
    () {
      const yaml = '''
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
rules:
  - AND,((DOMAIN-SUFFIX,google.com),(SCRIPT,whatever)),PROXY
  - AND,((DOMAIN-SUFFIX,google.com),(NETWORK,tcp),PROXY
  - NOT,((DOMAIN-SUFFIX,a.com),(DOMAIN-SUFFIX,b.com)),PROXY
  - MATCH,DIRECT
''';

      final warnings = <String>[];
      final rules =
          convert(yaml, onWarning: warnings.add)['rules'] as List<dynamic>;

      // Only the catch-all survives: a condition with an unknown sub-rule, one
      // whose brackets do not close, and a NOT over two conditions would all
      // match traffic the profile meant to protect.
      expect(rules, hasLength(1));
      expect((rules.single as Map)['rule_type'], 'match');
      expect(warnings, hasLength(3));
    },
  );

  test('nesting past the engine limit is refused, not walked', () {
    // Nine nested AND conditions: the engine compiles at most eight, so the
    // converter stops on the same line instead of recursing through a
    // profile-written recursion.
    var condition = '(DOMAIN-SUFFIX,a.com)';
    for (var i = 0; i < 9; i++) {
      condition = '((AND,$condition))';
    }
    final yaml =
        '''
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
rules:
  - AND,$condition,PROXY
  - MATCH,DIRECT
''';

    final warnings = <String>[];
    final rules =
        convert(yaml, onWarning: warnings.add)['rules'] as List<dynamic>;

    expect(rules, hasLength(1));
    expect((rules.single as Map)['rule_type'], 'match');
    expect(warnings, hasLength(1));
  });
}
