"""The identity and staging of the shader libraries a DM_COPY_SHADERS=NO build leaves out of the app (dm/tools/msl_id.py); synthetic files only."""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('msl_id', REPO / 'dm/tools/msl_id.py')
assert spec is not None and spec.loader is not None
msl_id = importlib.util.module_from_spec(spec); spec.loader.exec_module(msl_id)

LINE = re.compile(r'DMMSLID1 files=(\d+) bytes=(\d+) tree=[0-9a-f]{16}')


def make(root, sub='b-test', stamp='game\t0100\ninputs\tabc\n'):
    d = Path(root) / sub; d.mkdir(parents=True)
    (d / '1_b.metallib').write_bytes(b'x' * 10); (d / '1_b.json').write_text('{}'); (d / '2_bp.metallib').write_bytes(b'y' * 7)
    (d / 'inputs.tsv').write_text(stamp); (d / '.DS_Store').write_bytes(b'junk')
    (d / 'sub').mkdir(); (d / 'sub' / '3_b.metallib').write_bytes(b'z' * 3)
    return d


class Identity(unittest.TestCase):
    def test_counts_files_and_bytes_without_hidden_files(self):
        with tempfile.TemporaryDirectory() as t:
            make(t); line, rows = msl_id.identity(t, 'b-test')
            m = LINE.fullmatch(line); self.assertIsNotNone(m)
            self.assertEqual((int(m.group(1)), int(m.group(2))), (5, 10 + 2 + 7 + len('game\t0100\ninputs\tabc\n') + 3))
            self.assertNotIn('b-test/.DS_Store', [r for r, _ in rows])

    def test_skip_suffix_leaves_the_pulling_libraries_out(self):
        with tempfile.TemporaryDirectory() as t:
            make(t); line = msl_id.identity(t, 'b-test', ('_bp.metallib',))[0]
            self.assertEqual(int(LINE.fullmatch(line).group(1)), 4)

    def test_another_build_has_another_identity(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b, tempfile.TemporaryDirectory() as c:
            make(a); make(b); make(c, stamp='game\t0100\ninputs\tdef\n')
            self.assertEqual(msl_id.identity(a, 'b-test')[0], msl_id.identity(b, 'b-test')[0])
            self.assertNotEqual(msl_id.identity(a, 'b-test')[0], msl_id.identity(c, 'b-test')[0])   # the stamp's content counts, not only its size
            (Path(b) / 'b-test' / '1_b.metallib').write_bytes(b'x' * 11)
            self.assertNotEqual(msl_id.identity(a, 'b-test')[0], msl_id.identity(b, 'b-test')[0])

    def test_missing_folder_is_an_error(self):
        with tempfile.TemporaryDirectory() as t, self.assertRaises(SystemExit): msl_id.identity(t, 'b-none')


class Stage(unittest.TestCase):
    def test_stage_makes_the_folder_the_phone_gets_and_its_identity(self):
        with tempfile.TemporaryDirectory() as t, tempfile.TemporaryDirectory() as out:
            make(t); line = msl_id.stage(t, 'b-test', out, ('_bp.metallib',)); msl = Path(out) / 'msl'
            self.assertEqual((msl / 'msl.id').read_text(), line + '\n')
            self.assertEqual(sorted(p.relative_to(msl).as_posix() for p in msl.rglob('*') if p.is_file()),
                             ['b-test/1_b.json', 'b-test/1_b.metallib', 'b-test/inputs.tsv', 'b-test/sub/3_b.metallib', 'msl.id'])
            files = [p for p in msl.rglob('*') if p.is_file() and p.name != 'msl.id']   # what main.m counts: everything but msl.id
            self.assertEqual((len(files), sum(p.stat().st_size for p in files)), tuple(int(x) for x in LINE.fullmatch(line).groups()[:2]))

    def test_stage_again_replaces_the_old_set(self):
        with tempfile.TemporaryDirectory() as t, tempfile.TemporaryDirectory() as out:
            make(t); msl_id.stage(t, 'b-test', out); (Path(t) / 'b-test' / '1_b.json').unlink()
            line = msl_id.stage(t, 'b-test', out)
            self.assertFalse((Path(out) / 'msl/b-test/1_b.json').exists()); self.assertEqual(int(LINE.fullmatch(line).group(1)), 4)   # 1_b.metallib, inputs.tsv, 2_bp.metallib and sub/3_b.metallib

    def test_command_line(self):
        with tempfile.TemporaryDirectory() as t, tempfile.TemporaryDirectory() as out:
            make(t); script = str(REPO / 'dm/tools/msl_id.py')
            ident = subprocess.run([sys.executable, '-I', script, '--identity', t, 'b-test'], capture_output=True, text=True, check=True).stdout.strip()
            staged = subprocess.run([sys.executable, '-I', script, '--stage', t, 'b-test', out], capture_output=True, text=True, check=True).stdout.strip()
            self.assertEqual(ident, staged); self.assertRegex(ident, LINE)
            self.assertNotEqual(subprocess.run([sys.executable, '-I', script, '--bogus'], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
