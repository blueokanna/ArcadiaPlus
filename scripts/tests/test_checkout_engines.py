import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'checkout_engines', Path(__file__).resolve().parents[1] / 'checkout_engines.py')
checkout = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checkout)


class CheckoutSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.pins = self.parent / 'engine_revisions.json'

    def patch_fixture(self):
        repo = self.parent / 'Corduit'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        source = repo / 'source.txt'
        source.write_text('before\n', encoding='utf-8', newline='\n')
        patch_file = self.parent / 'fix.patch'
        patch_file.write_text('--- a/source.txt\n+++ b/source.txt\n'
                              '@@ -1 +1 @@\n-before\n+after\n', encoding='utf-8', newline='\n')
        return source, patch_file

    def test_required_patch_is_applied_once_and_verified_without_mutation(self):
        source, patch_file = self.patch_fixture()
        with patch.object(checkout, 'PATCHES', {'Corduit': patch_file}):
            with self.assertRaisesRegex(ValueError, 'required network fixes missing'):
                checkout.engine_patches(self.parent)
            self.assertEqual(source.read_text(), 'before\n')
            checkout.engine_patches(self.parent, apply=True)
            checkout.engine_patches(self.parent, apply=True)
            checkout.engine_patches(self.parent)
            self.assertEqual(source.read_text(), 'after\n')

    def test_patch_conflict_preserves_developer_changes(self):
        source, patch_file = self.patch_fixture()
        source.write_text('developer edit\n', encoding='utf-8')
        with patch.object(checkout, 'PATCHES', {'Corduit': patch_file}):
            with self.assertRaises(subprocess.CalledProcessError):
                checkout.engine_patches(self.parent, apply=True)
        self.assertEqual(source.read_text(), 'developer edit\n')

    def load(self, value):
        self.pins.write_text(json.dumps(value), encoding='utf-8')
        return checkout.revisions(self.pins)

    def test_requires_both_immutable_revisions(self):
        for value in ['', 'main', 'HEAD', 'v0.2.6', 'a' * 39, '../repo', 'a;exit', None, 123]:
            with self.assertRaises(ValueError):
                self.load({'RecurseX': value, 'Corduit': 'b' * 40})
        with self.assertRaises(ValueError):
            self.load({'RecurseX': 'a' * 40})
        self.assertEqual(self.load({'RecurseX': 'A' * 40, 'Corduit': 'b' * 40}),
                         {'RecurseX': 'a' * 40, 'Corduit': 'b' * 40})

    def test_committed_pins_need_no_repository_variables(self):
        with patch.dict('os.environ', {}, clear=True):
            pins = checkout.revisions()
            versions = checkout.locked_versions()
        self.assertEqual(set(pins), {'RecurseX', 'Corduit'})
        self.assertEqual(set(versions), set(pins))

    def test_unknown_repositories_and_non_objects_are_rejected(self):
        for value in [[], None, {'../outside': 'a' * 40},
                      {'RecurseX': 'a' * 40, 'Corduit': 'b' * 40, 'Other': 'c' * 40}]:
            with self.assertRaises(ValueError):
                self.load(value)

    def test_bad_or_missing_pin_file_has_no_fallback_to_head(self):
        with self.assertRaises(FileNotFoundError):
            checkout.revisions(self.pins)
        self.pins.write_text('{bad json', encoding='utf-8')
        with self.assertRaises(ValueError):
            checkout.revisions(self.pins)

    def test_fetched_package_must_match_the_lockfile(self):
        manifest = self.parent / 'Cargo.toml'
        for name, version in [('corduit', '0.3.2'), ('unrelated', '0.3.3')]:
            manifest.write_text(f'[package]\nname="{name}"\nversion="{version}"\n', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'matching rust/Cargo.lock'):
                checkout.validate_package(self.parent, 'Corduit', '0.3.3')
        manifest.write_text('[package]\nname="corduit"\nversion="0.3.3"\n', encoding='utf-8')
        checkout.validate_package(self.parent, 'Corduit', '0.3.3')

    def test_lockfile_refuses_missing_duplicate_or_registry_engines(self):
        file = self.parent / 'Cargo.lock'
        base = ('[[package]]\nname="corduit"\nversion="0.3.3"\n'
                '[[package]]\nname="recurse-x"\nversion="0.2.6"\n')
        file.write_text(base, encoding='utf-8')
        self.assertEqual(checkout.locked_versions(file), {'Corduit': '0.3.3', 'RecurseX': '0.2.6'})
        for content in ['', base + '[[package]]\nname="corduit"\nversion="0.3.3"\n',
                        base + 'source="registry+https://github.com/rust-lang/crates.io-index"\n']:
            file.write_text(content, encoding='utf-8')
            with self.assertRaises(ValueError):
                checkout.locked_versions(file)

    def test_existing_repository_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            (parent / 'Corduit').mkdir()
            with self.assertRaisesRegex(ValueError, 'Refusing to replace'):
                checkout.checkout(parent, {'RecurseX': 'a' * 40, 'Corduit': 'b' * 40},
                                  {'RecurseX': '0.2.6', 'Corduit': '0.3.3'})
            self.assertFalse((parent / 'RecurseX').exists())

    def test_local_pin_check_reads_commit_manifest_not_current_checkout(self):
        with patch.object(checkout.subprocess, 'check_output', return_value=
                          '[package]\nname="corduit"\nversion="0.3.4"\n') as read:
            checkout.verify_local(self.parent, {'Corduit': 'a' * 40}, {'Corduit': '0.3.4'})
        self.assertEqual(read.call_args.args[0],
                         ['git', '-C', str(self.parent / 'Corduit'), 'show', 'a' * 40 + ':Cargo.toml'])

    def test_old_ci_pin_is_rejected_after_local_version_upgrade(self):
        with patch.object(checkout.subprocess, 'check_output', return_value=
                          '[package]\nname="corduit"\nversion="0.3.3"\n'):
            with self.assertRaisesRegex(ValueError, 'matching rust/Cargo.lock'):
                checkout.verify_local(self.parent, {'Corduit': 'a' * 40}, {'Corduit': '0.3.4'})
