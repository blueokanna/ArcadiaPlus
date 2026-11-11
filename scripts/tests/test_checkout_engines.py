import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    'checkout_engines', Path(__file__).resolve().parents[1] / 'checkout_engines.py')
checkout = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checkout)


class CheckoutSafety(unittest.TestCase):
    def test_requires_both_immutable_revisions(self):
        for value in ['', 'main', 'HEAD', 'v0.2.6', 'a' * 39, '../repo', 'a;exit']:
            with self.assertRaises(ValueError):
                checkout.revisions({'RECURSEX_REVISION': value, 'CORDUIT_REVISION': 'b' * 40})
        with self.assertRaises(ValueError):
            checkout.revisions({'RECURSEX_REVISION': 'a' * 40})
        self.assertEqual(checkout.revisions({'RECURSEX_REVISION': 'A' * 40,
                                            'CORDUIT_REVISION': 'b' * 40}),
                         {'RecurseX': 'a' * 40, 'Corduit': 'b' * 40})

    def test_existing_repository_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            (parent / 'Corduit').mkdir()
            with self.assertRaisesRegex(ValueError, 'Refusing to replace'):
                checkout.checkout(parent, {'RecurseX': 'a' * 40, 'Corduit': 'b' * 40})
            self.assertFalse((parent / 'RecurseX').exists())
