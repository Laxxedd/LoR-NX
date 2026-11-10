import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('version', ROOT / 'scripts/version.py')
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def test_the_repository_version_is_semver(self):
        self.assertRegex(version.read(ROOT / 'VERSION'), version.SEMVER)

    def test_bump_resets_the_lower_parts(self):
        self.assertEqual(version.bump('1.2.3', 'major'), '2.0.0')
        self.assertEqual(version.bump('1.2.3', 'minor'), '1.3.0')
        self.assertEqual(version.bump('1.2.3', 'patch'), '1.2.4')
        self.assertEqual(version.bump('1.2.3-rc.1+b5', 'patch'), '1.2.4')

    def test_malformed_versions_are_refused(self):
        for text in ('1.2', '01.2.3', 'v1.2.3', '1.2.3.4', '1.2.3-', ''):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as tmp:
                f = Path(tmp) / 'VERSION'
                f.write_text(text + '\n')
                with self.assertRaises(SystemExit):
                    version.read(f)

    def test_valid_versions_are_accepted(self):
        for text in ('0.0.0', '1.10.2', '1.0.0-alpha.1', '1.0.0+build.5', '2.0.0-rc.1+sha.5114f85'):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as tmp:
                f = Path(tmp) / 'VERSION'
                f.write_text(text + '\n')
                self.assertEqual(version.read(f), text)


if __name__ == '__main__':
    unittest.main()
