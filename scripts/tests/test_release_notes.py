import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_release_notes.py'
SPEC = importlib.util.spec_from_file_location('release_notes', SCRIPT)
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_current_build_only(self):
        version, body = notes.release_section(
            'version: 1.1.0+5\n',
            '## Unreleased\n- Future work\n\n## 1.1.0+5\n\n- Routing fix\n\n## 1.1.0+4\n- Old work\n',
        )
        self.assertEqual(version, '1.1.0+5')
        self.assertEqual(body, '- Routing fix\n')

    def test_missing_build_does_not_reuse_previous_or_unreleased_notes(self):
        with self.assertRaises(ValueError):
            notes.release_section('version: 1.1.0+5\n', '## Unreleased\n- Work\n## 1.1.0+4\n- Old\n')

    def test_empty_and_duplicate_sections_fail(self):
        for content in ('## 1.1.0+5\n- \n', '## 1.1.0+5\n- One\n## 1.1.0+5\n- Two\n'):
            with self.subTest(content=content), self.assertRaises(ValueError):
                notes.release_section('version: 1.1.0+5\n', content)

    def test_legacy_first_build(self):
        self.assertEqual(notes.release_section('version: 1.1.0\n', '## 1.1.0\n- Initial\n')[0], '1.1.0')

    def test_windows_line_endings(self):
        self.assertEqual(notes.release_section(
            'version: 1.1.0+5\r\n', '## 1.1.0+5\r\n- Fix\r\n',
        ), ('1.1.0+5', '- Fix\n'))

    def test_rejects_ambiguous_or_prerelease_identity(self):
        for source in ('version: 1.1.0-rc1\n', 'version: 1.1.0+5\nversion: 1.1.0+6\n'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                notes.release_section(source, '## 1.1.0+5\n- Work\n')


if __name__ == '__main__':
    unittest.main()
