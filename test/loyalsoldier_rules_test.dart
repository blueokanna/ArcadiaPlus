import 'dart:io';

import 'package:arcadiaplus/src/services/rule_provider_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const root = String.fromEnvironment('RULESET_FIXTURE_DIR');
  const meta = String.fromEnvironment('METACUBEX_FIXTURE_DIR');
  const library = String.fromEnvironment('RULESET_NATIVE_LIBRARY');
  test('GEOSITE category snapshots retain every domain condition', () async {
    final cache = await Directory.systemTemp.createTemp('geosite-reference-');
    final service = RuleProviderService(
      storageRoot: () async => cache,
      client: MockClient((request) async {
        final file = File('$meta/geosite-${request.url.pathSegments.last}');
        return http.Response.bytes(await file.readAsBytes(), 200);
      }),
    );
    try {
      for (final name in ['cn', 'geolocation-!cn', 'apple@cn']) {
        final report = await service.prepare(
          name,
          'rules: ["GEOSITE,$name,DIRECT"]',
        );
        final source = await File('$meta/geosite-$name.list').readAsLines();
        expect(report.states.single.error, isNull, reason: name);
        expect(report.entryCount, source.length, reason: name);
        final entries = await File(report.paths[name]!).readAsLines();
        for (final regex in source.where(
          (line) => line.startsWith('DOMAIN-REGEX,'),
        )) {
          expect(
            entries.contains('regexp:${regex.substring(13)}'),
            isTrue,
            reason: regex,
          );
        }
      }
    } finally {
      service.dispose();
      await cache.delete(recursive: true);
    }
  }, skip: meta.isEmpty);

  test('native MRS validation publishes intact sets and retains them on invalid refresh', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File(library).absolute.path),
    );
    final cache = await Directory.systemTemp.createTemp('mrs-reference-');
    final domain = await File('$meta/geosite-cn.mrs').readAsBytes();
    final cidr = await File('$meta/geoip-cn.mrs').readAsBytes();
    var response = domain;
    final service = RuleProviderService(
      storageRoot: () async => cache,
      client: MockClient((_) async => http.Response.bytes(response, 200)),
    );
    try {
      for (final behavior in ['domain', 'ipcidr']) {
        final profile =
            'rule-providers: {cn: {type: http, url: https://example.test/cn.mrs, behavior: $behavior}}';
        response = behavior == 'domain' ? domain : cidr;
        final good = await service.prepare(behavior, profile);
        expect(good.states.single.error, isNull, reason: behavior);
        expect(good.entryCount, greaterThan(1));
        expect(await File(good.paths['cn']!).readAsBytes(), response);
        for (final bad in [
          response.sublist(0, response.length ~/ 2),
          behavior == 'domain' ? cidr : domain,
        ]) {
          response = bad;
          final retry = await service.prepare(behavior, profile, force: true);
          expect(retry.states.single.error, isNotNull);
          expect(retry.paths, good.paths);
        }
      }
    } finally {
      service.dispose();
      await cache.delete(recursive: true);
      RustLib.dispose();
    }
  }, skip: meta.isEmpty || library.isEmpty);
  test(
    'official domain and CIDR snapshots load without dropping entries',
    () async {
      final cache = await Directory.systemTemp.createTemp('rules-reference-');
      final service = RuleProviderService(storageRoot: () async => cache);
      try {
        for (final name in [
          'direct',
          'proxy',
          'reject',
          'private',
          'cncidr',
          'lancidr',
        ]) {
          final source = File('$root/$name.txt').absolute.path
              .replaceAll('\\', '/');
          final report = await service.prepare(name, '''
rule-providers:
  reference:
    type: file
    behavior: ${name.endsWith('cidr') ? 'ipcidr' : 'domain'}
    path: '$source'
''');
          final state = report.states.single;
          expect(state.ready, true, reason: '$name: ${state.error}');
          expect(state.skipped, 0, reason: name);
          expect(state.entries, greaterThan(0), reason: name);
        }
      } finally {
        service.dispose();
        await cache.delete(recursive: true);
      }
    },
    skip: root.isEmpty
        ? 'Pass RULESET_FIXTURE_DIR with official downloaded snapshots.'
        : false,
  );
}
