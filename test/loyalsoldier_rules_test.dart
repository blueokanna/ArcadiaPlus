import 'dart:io';

import 'package:arcadiaplus/src/services/rule_provider_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = String.fromEnvironment('RULESET_FIXTURE_DIR');
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
