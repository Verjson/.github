#!/usr/bin/env python3
import copy
from collections import Counter
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('bindings', ROOT / 'scripts/required-check-bindings.py')
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class RequiredCheckBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.data = self.base / 'public'
        shutil.copytree(policy.DATA, self.data)
        self.patch = mock.patch.object(policy, 'DATA', self.data)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.private = self.base / 'private'
        self.private.mkdir()
        self.cohort = [
            {'repository': 'Verjson/fixture-node', 'repositoryId': 1, 'defaultBranch': 'main', 'properties': {
                'changelog-contract': 'adopted', 'verjson-stack': 'node', 'verjson-core-checks': 'enforced'}},
            {'repository': 'Verjson/fixture-changelog', 'repositoryId': 2, 'defaultBranch': 'main', 'properties': {
                'changelog-contract': 'adopted', 'verjson-stack': 'actions', 'verjson-core-checks': 'exempt'}}]
        self.rows = []
        for repo in self.cohort:
            for identity, contexts in policy.CONTEXTS.items():
                if not policy.selected(repo['properties'], identity):
                    continue
                for context in contexts:
                    self.rows.append({'repository': repo['repository'], 'context': context, 'checkId': len(self.rows) + 1,
                        'headSha': 'a' * 40, 'headSource': {'sha': 'a' * 40, 'kind': 'default-branch'},
                        'appId': 15368, 'appSlug': 'github-actions', 'appOwner': 'github',
                        'conclusion': 'failure' if self.rows else 'success', 'completedAt': '2026-09-10T00:00:00Z',
                        'detailsUrl': 'https://github.com/' + repo['repository'] + '/actions/runs/1/job/1'})
        self.save_evidence()

    def save_evidence(self):
        (self.private / 'cohort.json').write_text(json.dumps(self.cohort))
        (self.private / 'producer-checks.jsonl').write_text('\n'.join(json.dumps(row) for row in self.rows))
        observation = policy.read('observation.json')
        observation.update(repositoryCount=len(self.cohort), producerReceiptCount=len(self.rows),
                           contextCounts=dict(Counter(row['context'] for row in self.rows)),
                           conclusionCounts=dict(Counter(row['conclusion'] for row in self.rows)),
                           oldestCompletedAt=min(row['completedAt'] for row in self.rows))
        observation['evidenceDigests'] = {name: 'sha256:' + hashlib.sha256((self.private / name).read_bytes()).hexdigest()
                                        for name in ('cohort.json', 'producer-checks.jsonl')}
        (self.data / 'observation.json').write_text(json.dumps(observation))

    def test_offline_proposal_is_deterministic_without_claiming_private_or_live_verification(self):
        result = policy.prepare()
        self.assertEqual(result, policy.prepare())
        self.assertFalse(result['producerEvidenceValidated'])
        self.assertFalse(result['liveActivationVerified'])
        self.assertTrue(result['preparationOnly'])
        self.assertNotIn('fixture-node', json.dumps(result))

    def test_exact_candidates_add_only_four_bindings_and_rollback_preserves_original_payloads(self):
        result = policy.prepare(self.private)
        self.assertTrue(result['producerEvidenceValidated'])
        count = 0
        for plan in result['plans']:
            unbound = copy.deepcopy(plan['after'])
            for check in unbound['rules'][0]['parameters']['required_status_checks']:
                self.assertEqual(check.pop('integration_id'), 15368)
                count += 1
            self.assertEqual(unbound, plan['rollback'])
        self.assertEqual(count, 4)

    def test_candidate_and_rollback_scope_or_bypass_drift_is_rejected(self):
        for suffix, field, replacement in [('after', 'bypass_actors', []), ('after', 'enforcement', 'disabled'),
                                            ('rollback', 'conditions', {})]:
            path = self.data / f'20515817-{suffix}.json'
            original = path.read_bytes()
            value = json.loads(original); value[field] = replacement
            path.write_text(json.dumps(value))
            with self.assertRaises(policy.BindingError): policy.prepare()
            path.write_bytes(original)

    def test_incomplete_and_duplicate_context_coverage_is_rejected_even_with_matching_digest(self):
        original = copy.deepcopy(self.rows)
        for rows in (original[:-1], original + [original[0]]):
            self.rows = rows; self.save_evidence()
            with self.assertRaises(policy.BindingError): policy.prepare(self.private)

    def test_forged_app_or_head_and_boolean_ids_are_rejected(self):
        for field, value in [('appId', 15368.0), ('appId', 999), ('appSlug', 'untrusted'),
                             ('appOwner', 'untrusted'), ('checkId', True), ('headSha', 'b' * 40)]:
            original = copy.deepcopy(self.rows)
            self.rows[0][field] = value; self.save_evidence()
            with self.assertRaises(policy.BindingError): policy.prepare(self.private)
            self.rows = original

    def test_evidence_digest_mismatch_is_rejected(self):
        with (self.private / 'producer-checks.jsonl').open('a') as file: file.write(' ')
        with self.assertRaisesRegex(policy.BindingError, 'digest differs'): policy.prepare(self.private)

    def fake_read(self, path, paginate=False):
        for identity in policy.CONTEXTS:
            if path == f'orgs/Verjson/rulesets/{identity}': return policy.read(f'{identity}-before.json')
        if path.startswith('orgs/Verjson/properties/'):
            return [[{'repository_full_name': r['repository'], 'repository_id': r['repositoryId'],
                      'properties': [{'property_name': k, 'value': v} for k, v in r['properties'].items()]} for r in self.cohort]]
        row = next(row for row in self.rows if path == f"repos/{row['repository']}/check-runs/{row['checkId']}")
        return {'id': row['checkId'], 'name': row['context'], 'head_sha': row['headSha'],
                'app': {'id': row['appId'], 'slug': row['appSlug'], 'owner': {'login': row['appOwner']}},
                'conclusion': row['conclusion'], 'completed_at': row['completedAt'], 'details_url': row['detailsUrl']}

    def test_dry_run_rechecks_every_receipt_with_fixed_host_and_get_only(self):
        def execute(args, **kwargs):
            self.assertEqual(args[:6], ['gh', 'api', '--hostname', 'github.com', '--method', 'GET'])
            return subprocess.CompletedProcess(args, 0, json.dumps(self.fake_read(args[6])).encode(), b'')
        with mock.patch.dict(os.environ, {'GH_HOST': 'untrusted.invalid'}), mock.patch.object(policy.subprocess, 'run', side_effect=execute) as run:
            result = policy.dry_run(self.private)
        self.assertEqual(run.call_count, 3 + len(self.rows))
        self.assertTrue(result['authenticatedSnapshotsRechecked'])
        self.assertFalse(result['liveActivationVerified'])

    def test_changed_live_baseline_cohort_or_producer_is_rejected(self):
        def changed(path, paginate=False):
            value = self.fake_read(path, paginate)
            if 'rulesets/20513599' in path: value['updated_at'] = 'changed'
            return value
        with mock.patch.object(policy, 'gh_get', side_effect=changed):
            with self.assertRaisesRegex(policy.BindingError, 'preimage changed'): policy.dry_run(self.private)
        for target in ('cohort', 'producer'):
            def altered(path, paginate=False):
                value = self.fake_read(path, paginate)
                if target == 'cohort' and '/properties/' in path: value[0].pop()
                if target == 'producer' and '/check-runs/' in path: value['app']['id'] = 999
                return value
            with mock.patch.object(policy, 'gh_get', side_effect=altered):
                with self.assertRaises(policy.BindingError): policy.dry_run(self.private)

    def test_dot_segment_repositories_are_rejected_before_any_subprocess(self):
        for name in ('.', '..'):
            with mock.patch.object(policy.subprocess, 'run') as execute:
                with self.assertRaisesRegex(policy.BindingError, 'unsupported read path'):
                    policy.gh_get(f'repos/Verjson/{name}/check-runs/1')
                self.cohort[0]['repository'] = f'Verjson/{name}'
                self.save_evidence()
                with self.assertRaisesRegex(policy.BindingError, 'invalid cohort repository'):
                    policy.prepare(self.private)
            execute.assert_not_called()

    def test_normal_dot_and_hyphen_names_keep_the_same_cohort_and_api_boundary(self):
        for name in ('.github', 'repo.with-dots', 'normal-repo'):
            old = self.cohort[0]['repository']
            current = f'Verjson/{name}'
            self.cohort[0]['repository'] = current
            for row in self.rows:
                if row['repository'] == old:
                    row['repository'] = current
                    row['detailsUrl'] = row['detailsUrl'].replace(old, current)
            self.save_evidence()
            self.assertTrue(policy.prepare(self.private)['producerEvidenceValidated'])
            with mock.patch.object(policy.subprocess, 'run', return_value=mock.Mock(stdout=b'{}')) as execute:
                self.assertEqual(policy.gh_get(f'repos/{current}/check-runs/1'), {})
            execute.assert_called_once()

    def test_json_and_cli_fail_closed_without_mutation_or_missing_private_evidence(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":1e999}'):
            with self.assertRaises(policy.BindingError): policy.decode(raw)
        for args in (['apply'], ['dry-run']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error: policy.main(args)
            self.assertEqual(error.exception.code, 2)
        with mock.patch.object(policy, 'gh_get') as read, redirect_stdout(io.StringIO()): policy.main(['render'])
        read.assert_not_called()


if __name__ == '__main__':
    unittest.main()
