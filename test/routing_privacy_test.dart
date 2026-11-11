import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/widgets/expressive_action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/providers/dns_settings_provider.dart';
import 'package:arcadiaplus/src/services/encrypted_dns_policy.dart';
import 'package:arcadiaplus/src/services/profile_selections.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/services/rule_catalog.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/services/update_service.dart';
import 'package:arcadiaplus/src/utils/release_version.dart';
import 'package:arcadiaplus/src/widgets/routing_mode_selector.dart';

import 'support/proxy_engine_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('encryption adds no unrequested public domain policies', () {
    final config = jsonDecode(
      ConfigConverter.convertClashYamlToJson('''
dns:
  nameserver: [https://1.1.1.1/dns-query]
  nameserver-policy:
    'bilibili.com': [https://9.9.9.9/dns-query]
rules: []
''', dnsSettings: DnsSettings(requireEncryptedDns: true)),
    ) as Map;
    final policies = config['dns']['nameserver_policy'] as Map;
    expect(policies.containsKey('+.qq.com'), false);
    expect(policies, hasLength(1));
    expect(policies['bilibili.com'], ['https://9.9.9.9/dns-query']);
    expect(policies.containsKey('+.bilibili.com'), false);
  });

  test(
    'legacy default DNS migrates without changing a custom resolver list',
    () {
      final migrated = DnsSettings.fromJson({
        'nameserversRevision': 2,
        'nameservers': [
          'https://dns.cloudflare.com/dns-query',
          'https://dns.google/dns-query',
          'https://doh.pub/dns-query',
          'https://dns.alidns.com/dns-query',
        ],
      }).withCurrentNameserverDefaults();
      expect(migrated.nameservers, DnsSettings.defaultNameservers);
      final custom = DnsSettings(
        nameservers: ['https://private.example/dns-query'],
        nameserversRevision: 2,
      ).withCurrentNameserverDefaults();
      expect(custom.nameservers, ['https://private.example/dns-query']);
    },
  );

  test('privacy controls publish only persisted settings and serialize rapid toggles', () async {
    final gate = Completer<void>();
    final written = <bool>[];
    final provider = DnsSettingsProvider(
      read: () async => DnsSettings(requireEncryptedDns: true),
      write: (settings) async {
        written.add(settings.requireEncryptedDns);
        if (written.length == 1) await gate.future;
      },
    );
    addTearDown(provider.dispose);
    final off = provider.setRequireEncryptedDns(false);
    final on = provider.setRequireEncryptedDns(true);
    await Future<void>.delayed(Duration.zero);
    expect(provider.requireEncryptedDns, true);
    gate.complete();
    await Future.wait([off, on]);
    expect(written, [false, true]);
    expect(provider.requireEncryptedDns, true);
  });

  test(
    'failed privacy save retains the previous value and reports an error',
    () async {
      final provider = DnsSettingsProvider(
        read: () async => DnsSettings(requireEncryptedDns: false),
        write: (_) async => throw StateError('disk unavailable'),
      );
      addTearDown(provider.dispose);
      await provider.setRequireEncryptedDns(true);
      expect(provider.requireEncryptedDns, false);
      expect(provider.saveError, contains('disk unavailable'));
    },
  );

  test(
    'queued DNS list edits merge with loaded and previously saved values',
    () async {
      final loaded = Completer<DnsSettings>();
      final provider = DnsSettingsProvider(
        read: () => loaded.future,
        write: (_) async {},
      );
      addTearDown(provider.dispose);
      final first = provider.addNameserver('https://one.test/dns-query');
      final second = provider.addNameserver('https://two.test/dns-query');
      final remove = provider.removeNameserver('https://old.test/dns-query');
      loaded.complete(DnsSettings(nameservers: ['https://old.test/dns-query']));
      await Future.wait([first, second, remove]);
      expect(provider.nameservers, [
        'https://one.test/dns-query',
        'https://two.test/dns-query',
      ]);
    },
  );

  test('runtime conversion rejects malformed and unsupported rules', () {
    for (final rule in [
      '42',
      'DOMAIN',
      'UNKNOWN,example.com,DIRECT',
      'DOMAIN,example.com,missing',
    ]) {
      expect(
        () => ConfigConverter.convertClashYamlToJson(
          'rules:\n  - $rule',
          requireCompleteRules: true,
        ),
        throwsException,
      );
    }
  });

  test(
    'encrypted policy covers primary, fallback, bootstrap and domain policy',
    () {
      final config = jsonDecode(
        ConfigConverter.convertClashYamlToJson(
          '''
dns:
  enable: false
  nameserver: [https://dns.example/dns-query]
  fallback: [8.8.8.8, tls://1.1.1.1]
  default-nameserver: [223.5.5.5]
  nameserver-policy:
    '+.example.com': [tls://private.example]
rules: [MATCH,DIRECT]
''',
          dnsSettings: DnsSettings(requireEncryptedDns: true),
          recursiveDnsAddress: '127.0.0.1:5353',
          systemDnsServers: ['192.168.1.1'],
        ),
      ) as Map;
      final dns = config['dns'] as Map;
      expect(dns['enable'], true);
      expect(dns['nameservers'], ['https://dns.example/dns-query']);
      expect(dns['fallback'], ['https://8.8.8.8/dns-query', 'tls://1.1.1.1']);
      expect(dns['default_nameserver'], [EncryptedDnsPolicy.defaults.first]);
      expect(dns['nameserver_policy']['+.example.com'], [
        'tls://private.example',
      ]);
      expect(jsonEncode(dns), isNot(contains('192.168.1.1')));
      expect(jsonEncode(dns), isNot(contains('127.0.0.1:5353')));
    },
  );

  test('no plaintext default is introduced when the profile has no DNS', () {
    final config = jsonDecode(
      ConfigConverter.convertClashYamlToJson(
        'rules: []',
        dnsSettings: DnsSettings(requireEncryptedDns: true),
      ),
    ) as Map;
    expect(config['dns']['nameservers'], EncryptedDnsPolicy.defaults);
    expect(DnsSettings.fromJson({}).requireEncryptedDns, false);
    expect(
      DnsSettings.fromJson(DnsSettings(requireEncryptedDns: false).toJson())
          .requireEncryptedDns,
      false,
    );
    expect(EncryptedDnsPolicy.accepts('http://1.1.1.1/dns-query'), false);
    expect(
      EncryptedDnsPolicy.accepts('https://dns.example/query', literal: true),
      false,
    );
  });

  test(
    'strict routing refuses to drop unavailable blocking or direct rules',
    () {
      for (final rule in [
        'RULE-SET,missing,REJECT',
        'GEOSITE,cn,DIRECT',
        'AND,((GEOSITE,cn),(NETWORK,TCP)),DIRECT',
      ]) {
        expect(
          () => ConfigConverter.convertClashYamlToJson(
            'rules:\n  - $rule\n  - MATCH,DIRECT',
            requireCompleteRules: true,
          ),
          throwsA(
            predicate(
              (e) => e.toString().contains('Required routing data unavailable'),
            ),
          ),
        );
      }
    },
  );

  test(
    'GEOSITE cn uses the downloaded domain provider in its original position',
    () {
      final config = jsonDecode(
        ConfigConverter.convertClashYamlToJson(
          '''
rules:
  - DOMAIN,blocked.example,REJECT
  - GEOSITE,cn,DIRECT
  - MATCH,REJECT
''',
          requireCompleteRules: true,
          ruleProviderPaths: {'cn': '/cache/cn.rules'},
        ),
      ) as Map;
      final rules = config['rules'] as List;
      expect(rules[0]['outbound'], 'REJECT');
      expect(rules[1]['rule_type'], 'geosite');
      expect(rules[1]['outbound'], 'DIRECT');
      expect(rules[2]['outbound'], 'REJECT');
      expect(config['rule_providers'][0]['path'], '/cache/cn.rules');
      final expanded = RuleCatalog.expand({
        'rules': ['GEOSITE,cn,DIRECT'],
        'rule-providers': {
          'cn': {'type': 'file', 'path': '/custom'},
        },
      });
      expect(expanded['rule-providers']['cn']['path'], '/custom');
    },
  );

  test('profiles cannot inherit another profile\'s selected proxy', () async {
    final engine = FakeEngine()..isReady = true;
    addTearDown(engine.dispose);
    final config = jsonEncode({
      'outbounds': [
        {
          'outbound_type': 'selector',
          'tag': 'Domestic',
          'options': jsonEncode({
            'outbounds': ['DIRECT', 'node'],
          }),
        },
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      ProfileSelections.key('profile-a', 'Domestic'),
      'node',
    );
    await ProfileSelections.restore('profile-a', config, engine);
    expect(engine.selections['Domestic'], 'node');
    await ProfileSelections.restore('profile-b', config, engine);
    expect(engine.selections['Domestic'], 'DIRECT');
    await ProfileSelections.restore('profile-a', config, engine);
    expect(engine.selections['Domestic'], 'node');
  });

  test(
    'build revisions compare numerically and decode Android versionCode',
    () {
      final installed = ReleaseVersion.installed(
        '1.0.8',
        '100080001',
        android: true,
      );
      expect(installed.toString(), '1.0.8+1');
      expect(
        ReleaseVersion.parse('1.0.8+2').compareTo(installed),
        greaterThan(0),
      );
      expect(
        ReleaseVersion.parse('1.0.8+10')
            .compareTo(ReleaseVersion.parse('1.0.8+2')),
        greaterThan(0),
      );
      expect(
        ReleaseVersion.parse('1.0.7+9999').compareTo(installed),
        lessThan(0),
      );
    },
  );

  test('updater discovers a new build of the same semantic version', () async {
    PackageInfo.setMockInitialValues(
      appName: 'ArcadiaPlus',
      packageName: 'test',
      version: '1.0.8',
      buildNumber: '1',
      buildSignature: '',
    );
    const tag = 'v1.0.8+2';
    const base =
        'https://github.com/blueokanna/ArcadiaPlus/releases/download/$tag';
    const date = '2026-11-09T00:00:00Z';
    final platform = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
        ? 'macos'
        : Platform.isAndroid
        ? 'android'
        : 'linux';
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.host == 'api.github.com'
              ? {
                  'tag_name': tag,
                  'published_at': date,
                  'html_url':
                      'https://github.com/blueokanna/ArcadiaPlus/releases/tag/$tag',
                  'assets': [
                    {
                      'name': 'update-manifest.json',
                      'browser_download_url': '$base/update-manifest.json',
                    },
                    {
                      'name': 'app',
                      'browser_download_url':
                          '${base.replaceAll('+', '%2B')}/app',
                    },
                  ],
                }
              : {
                  'schema': 1,
                  'tag': tag,
                  'version': '1.0.8',
                  'build_number': 2,
                  'published_at': date,
                  'assets': [
                    {
                      'platform': platform,
                      'name': 'app',
                      'url': '$base/app',
                      'sha256': 'a' * 64,
                    },
                  ],
                },
        ),
        200,
      ),
    );
    addTearDown(client.close);
    expect(
      (await UpdateService(client: client).checkForUpdate())?.version,
      '1.0.8+2',
    );
  });

  for (final mobile in [true, false]) {
    testWidgets('Material 3 routing options respect mobile=$mobile', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SizedBox(
              width: 350,
              child: RoutingModeSelector(
                mobile: mobile,
                mode: ProxyMode.direct,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Direct Mode'), mobile ? findsNothing : findsOneWidget);
      final selected = tester
          .widgetList<ExpressiveAction>(find.byType(ExpressiveAction))
          .where((button) => button.selected);
      expect(selected, hasLength(1));
      expect(
        find.descendant(
          of: find.byWidget(selected.single),
          matching: find.text(mobile ? 'Rule Mode' : 'Direct Mode'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
