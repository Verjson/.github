#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('owners', ROOT / 'scripts/codeowners.py')
owners = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(owners)


class CodeownersTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / '.github').mkdir()
        self.target = self.root / '.github/CODEOWNERS'
        self.target.write_text(owners.CONTENT)

    def test_exact_generated_owner_covers_every_path_including_itself(self):
        owners.check(self.root)
        rules = [line for line in owners.CONTENT.splitlines() if line and not line.startswith('#')]
        self.assertEqual(rules, ['* @Verjson/devs'])

    def test_missing_wrong_owner_exceptions_and_generated_header_drift_fail(self):
        self.target.unlink()
        with self.assertRaises(owners.OwnershipError):
            owners.check(self.root)
        for content in (owners.CONTENT.replace('@Verjson/devs', '@Verjson/other'),
                        owners.CONTENT + '/scripts/ @Verjson/other\n',
                        owners.CONTENT + '/.github/CODEOWNERS\n',
                        '* @Verjson/devs\n', owners.CONTENT.replace('\n', '\r\n')):
            with self.subTest(content=content):
                self.target.write_bytes(content.encode())
                with self.assertRaises(owners.OwnershipError):
                    owners.check(self.root)

    def test_competing_fallback_locations_fail(self):
        for path in ('CODEOWNERS', 'docs/CODEOWNERS'):
            candidate = self.root / path
            candidate.parent.mkdir(exist_ok=True)
            candidate.write_text('* @Verjson/other\n')
            with self.assertRaises(owners.OwnershipError):
                owners.check(self.root)
            candidate.unlink()

    def test_symlinked_owner_file_or_directory_fails(self):
        self.target.unlink()
        alternate = self.root / 'alternate'
        alternate.write_text(owners.CONTENT)
        self.target.symlink_to(alternate)
        with self.assertRaises(owners.OwnershipError):
            owners.check(self.root)
        self.target.unlink()
        (self.root / '.github').rmdir()
        (self.root / '.github').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(owners.OwnershipError):
            owners.check(self.root)

    def test_canonical_generator_and_self_adoption_match_exactly(self):
        ref = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        generated = subprocess.check_output(['bash', str(ROOT / 'scripts/gen-changelog-caller.sh'), 'codeowners', ref], cwd=ROOT)
        self.assertEqual(generated, owners.CONTENT.encode())
        self.assertEqual((ROOT / '.github/CODEOWNERS').read_bytes(), generated)
        owners.check(ROOT)


if __name__ == '__main__':
    unittest.main()
