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
      '$name engine checkouts do not depend on external repository variables',
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
        expect(checkouts, greaterThan(0));
        final text = File('.github/workflows/$name.yml').readAsStringSync();
        expect(text, isNot(contains('vars.RECURSEX_REVISION')));
        expect(text, isNot(contains('vars.CORDUIT_REVISION')));
      },
    );
  }

  test('sibling resolver checks select its manifest rather than a workspace member', () {
    final steps = workflow('ci')['jobs']['rust']['steps'] as List;
    for (final name in ['Lint Rust workspace', 'Test Rust workspace']) {
      final command =
          steps.singleWhere((s) => s['name'] == name)['run'] as String;
      expect(command, contains('--manifest-path ../../RecurseX/Cargo.toml'));
      expect(command, isNot(contains('-p recurse-x')));
    }
  });

  test(
    'checkout action resolves scripts from the repository root on every OS',
    () {
      final action = loadYaml(
        File('.github/actions/checkout-engines/action.yml').readAsStringSync(),
      ) as YamlMap;
      expect(action['inputs'], isNull);
      expect(action['runs']['using'], 'composite');
      final fetch = (action['runs']['steps'] as List).singleWhere(
        (s) => s['name'] == 'Fetch pinned sources',
      );
      expect(fetch['shell'], 'bash');
      expect(fetch['working-directory'], r'${{ github.workspace }}');
      expect(fetch['run'], 'python scripts/checkout_engines.py');
    },
  );
}
