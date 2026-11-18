import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'ohos_floors', SCRIPTS / 'check_ohos_dependency_floors.py'
)
floors = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(floors)


class ConstraintTests(unittest.TestCase):
    def test_only_the_floor_is_enforced(self):
        # Pub ignores a dependency's upper bound and enforces its lower bound, so
        # `^3.9.0` is fine on 3.11.5 and `^3.12.0` is not.
        self.assertTrue(floors.accepts_floor('^3.9.0', (3, 11, 5)))
        self.assertFalse(floors.accepts_floor('^3.12.0', (3, 11, 5)))
        self.assertTrue(floors.accepts_floor('>=3.11.5 <3.12.0', (3, 11, 5)))
        self.assertFalse(floors.accepts_floor('>=3.11.6', (3, 11, 5)))
        self.assertFalse(floors.accepts_floor('>3.11.5', (3, 11, 5)))
        self.assertTrue(floors.accepts_floor('any', (3, 11, 5)))
        self.assertTrue(floors.accepts_floor(None, (3, 11, 5)))

    def test_a_caret_0_release_floors_on_its_own_version(self):
        self.assertFalse(floors.accepts_floor('^0.6.0', (0, 5, 2)))
        self.assertTrue(floors.accepts_floor('^0.5.2', (0, 5, 2)))

    def test_a_bare_version_is_a_caret_floor(self):
        self.assertEqual(floors.floor_of('2.13.0'), ((2, 13, 0), False))
        self.assertEqual(floors.floor_of('>3.11.5'), ((3, 11, 5), True))
        self.assertIsNone(floors.floor_of('any'))

    def test_bounds_are_read_without_a_yaml_parser(self):
        bounds = floors.environment_of(
            'name: demo\nversion: 1.2.3\n\nenvironment:\n  sdk: ^3.6.0\n'
            "  flutter: '>=3.22.0'\n\ndependencies: {}\n"
        )
        self.assertEqual(bounds, {'sdk': '^3.6.0', 'flutter': '>=3.22.0'})
        self.assertEqual(floors.environment_of('name: demo\n'), {})


class DeclarationTests(unittest.TestCase):
    def test_only_inline_hosted_constraints_are_returned(self):
        manifest = (
            'environment:\n  sdk: ^3.13.0\n\n'
            'dependencies:\n  flutter:\n    sdk: flutter\n  local:\n    path: sub\n'
            '  alpha: ^1.2.3\n  beta: "2.13.0"\n\n'
            'dev_dependencies:\n  gamma: ^4.0.0\n'
        )
        self.assertEqual(
            floors.declared(manifest),
            [
                ('dependencies', 'alpha', '^1.2.3'),
                ('dependencies', 'beta', '2.13.0'),
                ('dev_dependencies', 'gamma', '^4.0.0'),
            ],
        )

    def test_a_section_ends_at_the_next_top_level_key(self):
        manifest = (
            'dependencies:\n  alpha: ^1.0.0\n\n'
            'flutter_launcher_icons:\n  android: false\n  image_path: a.png\n'
        )
        self.assertEqual(floors.declared(manifest), [('dependencies', 'alpha', '^1.0.0')])


class ReportTests(unittest.TestCase):
    def test_only_dependencies_that_reject_the_line_are_reported(self):
        dependencies = [
            ('dependencies', 'fine', '^1.0.0'),
            ('dependencies', 'too_new_dart', '^2.0.0'),
            ('dev_dependencies', 'too_new_flutter', '^3.0.0'),
            ('dependencies', 'unresolved', '^4.0.0'),
        ]
        manifests = {
            'fine': 'name: fine\nversion: 1.0.0\nenvironment:\n  sdk: ^3.9.0\n',
            'too_new_dart': 'name: a\nversion: 2.0.0\nenvironment:\n  sdk: ^3.12.0\n',
            'too_new_flutter': (
                'name: b\nversion: 3.0.0\nenvironment:\n  sdk: ^3.10.0\n'
                '  flutter: ">=3.44.0"\n'
            ),
        }
        locked = {'fine': '1.0.0', 'too_new_dart': '2.0.0', 'too_new_flutter': '3.0.0'}
        rejected = floors.violations(dependencies, locked, manifests)
        self.assertEqual(
            [entry[0] for entry in rejected], ['too_new_dart', 'too_new_flutter']
        )
        self.assertEqual(rejected[0][1], '2.0.0')

    def test_a_project_config_is_checked_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.dart_tool').mkdir()
            packages = []
            for name, constraint in (('fine', '^3.9.0'), ('too_new', '^3.12.0')):
                package = root / name
                package.mkdir()
                (package / 'pubspec.yaml').write_text(
                    f'name: {name}\nversion: 1.0.0\nenvironment:\n  sdk: {constraint}\n',
                    encoding='utf-8',
                )
                packages.append({'name': name, 'rootUri': package.as_uri()})
            (root / '.dart_tool/package_config.json').write_text(
                json.dumps({'configVersion': 2, 'packages': packages}), encoding='utf-8'
            )
            (root / 'pubspec.yaml').write_text(
                'dependencies:\n  fine: ^1.0.0\n  too_new: ^1.0.0\n', encoding='utf-8'
            )

            argv = sys.argv
            sys.argv = ['check_ohos_dependency_floors.py', '--root', str(root)]
            try:
                self.assertEqual(floors.main(), 1)
            finally:
                sys.argv = argv

    def test_an_unresolved_dependency_is_an_error_not_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.dart_tool').mkdir()
            (root / '.dart_tool/package_config.json').write_text(
                json.dumps({'configVersion': 2, 'packages': []}), encoding='utf-8'
            )
            (root / 'pubspec.yaml').write_text(
                'dependencies:\n  fine: ^1.0.0\n', encoding='utf-8'
            )

            argv = sys.argv
            sys.argv = ['check_ohos_dependency_floors.py', '--root', str(root)]
            try:
                self.assertEqual(floors.main(), 1)
            finally:
                sys.argv = argv


if __name__ == '__main__':
    unittest.main()
