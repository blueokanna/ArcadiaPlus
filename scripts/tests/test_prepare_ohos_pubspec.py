"""Regressions for SDK/profile selection before the real OHOS pub solve."""

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "prepare_ohos_pubspec", ROOT / "scripts/prepare_ohos_pubspec.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareOhosTests(unittest.TestCase):
    def setUp(self):
        self.manifest = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")

    def prepare(self, text=None, dart="3.11.5", flutter="3.41.10-ohos-1.0.0"):
        return module.prepare(self.manifest if text is None else text, dart, flutter)

    def test_selects_compatible_adapter_without_relaxing_third_party_constraints(self):
        result = self.prepare()
        self.assertIn("sdk: '>=3.11.5 <3.12.0'", result)
        self.assertIn("flutter: '>=3.41.9 <3.42.0'", result)
        self.assertIn("path: ohos/compat/arcadia_expressive", result)
        before = self.manifest.split("dependencies:", 1)[1]
        after = result.split("dependencies:", 1)[1]
        self.assertEqual(
            before.replace("packages/arcadia_expressive", "ohos/compat/arcadia_expressive"),
            after,
        )

    def test_preparation_is_idempotent(self):
        result = self.prepare()
        self.assertEqual(self.prepare(result), result)

    def test_sdk_plugins_are_untouched(self):
        result = self.prepare()
        self.assertEqual(
            result.count("    sdk: flutter"), self.manifest.count("    sdk: flutter")
        )

    def test_either_yaml_quote_style_is_accepted(self):
        self.assertEqual(
            self.prepare(self.manifest.replace('"', "'")),
            self.prepare().replace('"', "'"),
        )

    def test_unvalidated_sdk_lines_fail(self):
        for dart, flutter in [
            ("3.11.4", "3.41.9"),
            ("3.13.0", "3.47.0"),
            ("3.11.5", "3.38.0"),
            ("null", "3.41.9"),
        ]:
            with self.subTest(dart=dart, flutter=flutter), self.assertRaises(ValueError):
                self.prepare(dart=dart, flutter=flutter)

    def test_missing_or_ambiguous_adapter_fails(self):
        for text in [
            self.manifest.replace("arcadia_expressive:", "missing:"),
            self.manifest
            + "\n  arcadia_expressive:\n    path: packages/arcadia_expressive\n",
        ]:
            with self.assertRaises(ValueError):
                self.prepare(text)

    def test_missing_environment_does_not_rewrite_flutter_sdk_dependencies(self):
        with self.assertRaises(ValueError):
            self.prepare(self.manifest.replace("environment:", "unexpected:"))


if __name__ == "__main__":
    unittest.main()
