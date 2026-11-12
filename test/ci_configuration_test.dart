import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

YamlMap workflow(String name) =>
    loadYaml(File('.github/workflows/$name.yml').readAsStringSync()) as YamlMap;

void main() {
  test(
    'security audit needs only the lockfile and does not bypass failures',
    () {
      final document = workflow('security');
      expect(document['on'], isA<Map>());
      final steps = document['jobs']['audit']['steps'] as List;
      expect(
        steps.where((s) => s['uses'] == './.github/actions/checkout-engines'),
        isEmpty,
      );
      expect(
        steps.where((s) => s['uses'] == 'Swatinem/rust-cache@v2'),
        isEmpty,
      );
      final audit = steps.singleWhere(
        (s) => s['name'] == 'Audit every target in the committed lockfile',
      );
      expect(
        audit['run'],
        contains('audit --file rust/Cargo.lock --deny warnings'),
      );
      expect(audit['continue-on-error'], isNull);
      expect(audit['if'], isNull);
    },
  );

  for (final name in ['ci', 'release']) {
    test(
      '$name builds locked registry dependencies without sibling checkouts',
      () {
        final document = workflow(name);
        expect(document['on'], isA<Map>());
        var checkouts = 0;
        for (final job in (document['jobs'] as Map).values) {
          for (final step in (job['steps'] as List? ?? [])) {
            if (step['uses'] != './.github/actions/checkout-engines') continue;
            checkouts++;
            expect(step['with'], isNull);
            expect(step['continue-on-error'], isNull);
          }
        }
        expect(checkouts, 0);
        final text = File('.github/workflows/$name.yml').readAsStringSync();
        expect(text, isNot(contains('vars.RECURSEX_REVISION')));
        expect(text, isNot(contains('vars.CORDUIT_REVISION')));
      },
    );
  }

  test('Rust CI validates and tests the application registry graph', () {
    final steps = workflow('ci')['jobs']['rust']['steps'] as List;
    final graph = steps.singleWhere(
      (s) => s['name'] == 'Verify locked networking dependencies',
    );
    expect(
      graph['run'],
      contains('python ../scripts/check_engine_dependencies.py'),
    );
    for (final name in ['Lint Rust workspace', 'Test Rust workspace']) {
      final command =
          steps.singleWhere((s) => s['name'] == name)['run'] as String;
      expect(command, contains('--locked'));
      expect(command, contains('--all-features'));
      expect(command, isNot(contains('../../')));
    }
  });
}
