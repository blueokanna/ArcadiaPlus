import copy
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_engine_dependencies.py'
SPEC = importlib.util.spec_from_file_location('engine_dependencies', SCRIPT)
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)


class DependencyChecks(unittest.TestCase):
    def setUp(self):
        self.expected = {'corduit': '0.3.2', 'recurse-x': '0.2.5', 'courierust': '1.1.2'}
        self.manifest = {'dependencies': {'corduit': {'version': '0.3.2'}, 'recurse-x': '0.2.5'}}
        self.lock = {'package': [dict(name=name, version=version, source=engine.REGISTRY, checksum='a' * 64)
                                 for name, version in self.expected.items()]}
        self.metadata = {'resolve': {'root': 'bridge', 'nodes': [
            {'id': 'bridge', 'deps': [{'name': 'corduit', 'pkg': 'corduit'},
                {'name': 'recurse_x', 'pkg': 'recurse-x'}, {'name': 'jni', 'pkg': 'jni-0.22'}]},
            {'id': 'corduit', 'deps': [{'name': 'recurse_x', 'pkg': 'recurse-x'},
                {'name': 'courierust', 'pkg': 'courierust'}, {'name': 'jni', 'pkg': 'jni-0.22'}]},
            {'id': 'recurse-x', 'deps': [{'name': 'courierust', 'pkg': 'courierust'}]},
            {'id': 'courierust', 'deps': []},
        ]}, 'packages': [dict(id=name, name=name, version=version, source=engine.REGISTRY)
                          for name, version in self.expected.items()]}

    def test_shared_registry_graph_is_accepted(self):
        engine.validate_manifest(self.manifest)
        self.assertEqual(engine.validate_lock(self.lock), self.expected)
        engine.validate_graph(self.metadata, self.expected)

    def test_local_manifest_override_is_rejected(self):
        self.manifest['dependencies']['corduit']['path'] = '../../Corduit'
        with self.assertRaisesRegex(ValueError, 'crates.io version'):
            engine.validate_manifest(self.manifest)

    def test_git_manifest_override_is_rejected(self):
        self.manifest['dependencies']['corduit']['git'] = 'https://example.test/engine'
        with self.assertRaisesRegex(ValueError, 'crates.io version'):
            engine.validate_manifest(self.manifest)

    def test_duplicate_locked_resolver_is_rejected(self):
        self.lock['package'].append(copy.deepcopy(self.lock['package'][1]))
        with self.assertRaisesRegex(ValueError, 'one locked package'):
            engine.validate_lock(self.lock)

    def test_missing_checksum_is_rejected(self):
        self.lock['package'][0].pop('checksum')
        with self.assertRaisesRegex(ValueError, 'checksummed'):
            engine.validate_lock(self.lock)

    def test_local_lock_entry_is_rejected(self):
        self.lock['package'][0].pop('source')
        with self.assertRaisesRegex(ValueError, 'checksummed'):
            engine.validate_lock(self.lock)

    def test_duplicate_resolved_package_is_rejected(self):
        duplicate = copy.deepcopy(self.metadata['packages'][1])
        duplicate.update(id='local-recurse-x', source=None)
        self.metadata['packages'].append(duplicate)
        self.metadata['resolve']['nodes'].append({'id': duplicate['id'], 'deps': []})
        with self.assertRaisesRegex(ValueError, 'one shared package'):
            engine.validate_graph(self.metadata, self.expected)

    def test_source_patch_is_rejected_even_if_lock_is_clean(self):
        self.metadata['packages'][0]['source'] = None
        with self.assertRaisesRegex(ValueError, 'unexpected source'):
            engine.validate_graph(self.metadata, self.expected)

    def test_wrong_courierust_edge_is_rejected(self):
        self.metadata['resolve']['nodes'][2]['deps'][0]['pkg'] = 'another-courierust'
        with self.assertRaisesRegex(ValueError, 'socket factory'):
            engine.validate_graph(self.metadata, self.expected)

    def test_android_jni_version_split_is_rejected(self):
        self.metadata['resolve']['nodes'][0]['deps'][2]['pkg'] = 'jni-0.21'
        with self.assertRaisesRegex(ValueError, 'Android JNI'):
            engine.validate_graph(self.metadata, self.expected)

    def test_missing_resolution_is_rejected(self):
        self.metadata['resolve'] = None
        with self.assertRaisesRegex(ValueError, 'resolved bridge graph'):
            engine.validate_graph(self.metadata, self.expected)


if __name__ == '__main__':
    unittest.main()
