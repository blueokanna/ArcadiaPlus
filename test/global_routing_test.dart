import 'dart:convert';

import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:flutter_test/flutter_test.dart';

const profile = '''
proxies:
  - {name: node, type: socks5, server: 127.0.0.1, port: 1080}
proxy-groups:
  - {name: Domestic, type: select, proxies: [DIRECT]}
rules:
  - DOMAIN-SUFFIX,bilibili.com,Domestic
  - MATCH,node
''';

Map<String, dynamic> convert(String yaml) => jsonDecode(
  ConfigConverter.convertClashYamlToJson(yaml, requireCompleteRules: true),
) as Map<String, dynamic>;

List<dynamic> globalMembers(Map<String, dynamic> config) {
  final group = (config['outbounds'] as List).singleWhere(
    (item) => item['tag'] == 'GLOBAL',
  );
  return (jsonDecode(group['options'] as String) as Map)['outbounds'] as List;
}

void main() {
  test(
    'global selector exposes usable nodes without changing domestic rules',
    () {
      final config = convert(profile);
      expect(globalMembers(config), ['node']);
      expect(config['rules'][0]['outbound'], 'Domestic');
      expect(config['rules'][1]['outbound'], 'node');
      final groups = ConfigConverter.parseClashConfig(profile).proxyGroups;
      expect(groups.last.name, 'GLOBAL');
      expect(groups.last.proxies, globalMembers(config));
    },
  );

  test('explicit GLOBAL selection remains authoritative', () {
    final yaml = profile
        .replaceFirst('name: Domestic', 'name: GLOBAL')
        .replaceFirst('bilibili.com,Domestic', 'bilibili.com,GLOBAL');
    expect(globalMembers(convert(yaml)), ['DIRECT']);
    expect(ConfigConverter.parseClashConfig(yaml).proxyGroups, hasLength(1));
  });

  test('global without any usable proxy fails closed', () {
    expect(globalMembers(convert('rules: ["MATCH,DIRECT"]')), ['REJECT']);
  });

  test('runtime refuses a group emptied by unsupported node filtering', () {
    final yaml = profile
        .replaceFirst('type: socks5', 'type: unsupported')
        .replaceFirst('proxies: [DIRECT]', 'proxies: [node]');
    expect(
      () => convert(yaml),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('no usable members'),
        ),
      ),
    );
  });

  test('reserved and colliding outbound names are rejected', () {
    for (final name in ['DIRECT', 'REJECT', 'GLOBAL', 'Domestic']) {
      expect(
        () => convert(profile.replaceFirst('name: node', 'name: $name')),
        throwsException,
      );
    }
  });
}
