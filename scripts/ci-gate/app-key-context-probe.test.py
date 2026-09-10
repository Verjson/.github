#!/usr/bin/env python3
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
PREFIX = ROOT / '.github/workflows'


def workflow(suffix=''):
    return yaml.safe_load((PREFIX / f'app-key-context-probe{suffix}.yml').read_text())


class ContextProbeTests(unittest.TestCase):
    def test_four_cases_vary_only_declaration_and_secret_grant(self):
        caller = workflow()
        self.assertEqual(caller[True], {'workflow_dispatch': None})
        self.assertEqual(caller['permissions'], {})
        jobs = caller['jobs']
        self.assertEqual(set(jobs), {'undeclared', 'declared', 'explicit-empty', 'inherited'})
        self.assertNotIn('secrets', jobs['undeclared'])
        self.assertNotIn('secrets', jobs['declared'])
        self.assertEqual(jobs['explicit-empty']['secrets'], {'APP_KEY_CONTEXT_PROBE': ''})
        self.assertEqual(jobs['inherited']['secrets'], 'inherit')
        for name in jobs:
            mode = 'declared' if name in ('declared', 'explicit-empty') else 'undeclared'
            self.assertEqual(jobs[name]['uses'], f'./.github/workflows/app-key-context-probe-{mode}.yml')

    def test_callees_have_identical_fixed_environment_jobs_without_actions_or_real_keys(self):
        declared, undeclared = workflow('-declared'), workflow('-undeclared')
        self.assertEqual(declared[True]['workflow_call']['secrets'], {'APP_KEY_CONTEXT_PROBE': {'required': False}})
        self.assertIsNone(undeclared[True]['workflow_call'])
        self.assertEqual(declared['jobs'], undeclared['jobs'])
        for child in (declared, undeclared):
            self.assertEqual(child['permissions'], {})
            job = child['jobs']['probe']
            self.assertEqual(job['environment'], 'ai-review-app')
            self.assertEqual(job['runs-on'], 'ubuntu-24.04')
            self.assertEqual(job['if'], "github.repository == 'Verjson/.github'")
            self.assertEqual(len(job['steps']), 1)
            self.assertNotIn('uses', job['steps'][0])
            self.assertEqual(job['steps'][0]['env'], {'PROBE': '${{ secrets.APP_KEY_CONTEXT_PROBE }}'})

    def test_probe_reports_only_boolean_and_never_value_or_length(self):
        script = workflow('-declared')['jobs']['probe']['steps'][0]['run']
        for value, expected in [('', 'false'), ('noncredential-test-fixture', 'true')]:
            with self.subTest(expected=expected):
                result = subprocess.run(['bash', '-e', '-c', script], env={'PROBE': value}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, f'populated={expected}\n')
                self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
