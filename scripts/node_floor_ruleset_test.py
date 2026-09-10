#!/usr/bin/env python3
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('node_floor', ROOT / 'scripts/node-floor-ruleset.py')
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class NodeFloorPreparationTests(unittest.TestCase):
    def setUp(self):
        self.baseline = policy.decode(policy.BASELINE.read_bytes())

    def test_render_is_deterministic_and_does_not_mutate_baseline(self):
        before = copy.deepcopy(self.baseline)
        first = policy.render(self.baseline, 'reviewed-policy')
        self.assertEqual(first, policy.render(self.baseline, 'reviewed-policy'))
        self.assertEqual(self.baseline, before)
        self.assertTrue(first['preparationOnly'])
        self.assertFalse(first['liveAcceptanceVerified'])
        self.assertEqual(first['baselineId'], 20515817)
        self.assertTrue(first['baselineDigest'].startswith('sha256:'))

    def test_default_is_disabled_and_node22_requires_both_existing_core_selectors(self):
        result = policy.render(self.baseline, 'reviewed-policy')
        definition = result['property']['definition']
        self.assertEqual(result['property']['name'], 'verjson-node-floor')
        self.assertEqual(definition['value_type'], 'single_select')
        self.assertTrue(definition['required'])
        self.assertEqual(definition['default_value'], 'disabled')
        self.assertEqual(definition['allowed_values'], ['disabled', 'node22'])
        self.assertEqual(definition['values_editable_by'], 'org_actors')
        rule = result['ruleset']
        self.assertEqual(rule['enforcement'], 'disabled')
        self.assertEqual(rule['conditions']['ref_name'], {'include': ['~DEFAULT_BRANCH'], 'exclude': []})
        selectors = rule['conditions']['repository_property']['include']
        wanted = {item['name']: item['property_values'] for item in selectors}
        self.assertEqual(wanted, {'verjson-stack': ['node'], 'verjson-core-checks': ['enforced'], 'verjson-node-floor': ['node22']})
        for stack, core, floor, selected in [('node', 'enforced', 'disabled', False),
                                            ('node', 'enforced', 'node22', True),
                                            ('ui', 'enforced', 'node22', False),
                                            ('node', 'exempt', 'node22', False)]:
            values = dict(zip(wanted, [stack, core, floor]))
            self.assertEqual(all(values[name] in allowed for name, allowed in wanted.items()), selected)

    def test_only_two_app_bound_floor_contexts_and_reviewed_bypasses_are_proposed(self):
        rule = policy.render(self.baseline, 'reviewed-policy')['ruleset']
        self.assertEqual(rule['bypass_actors'], [
            {'actor_id': None, 'actor_type': 'OrganizationAdmin', 'bypass_mode': 'always'},
            {'actor_id': 4583107, 'actor_type': 'Integration', 'bypass_mode': 'always'},
            {'actor_id': 4693283, 'actor_type': 'Integration', 'bypass_mode': 'always'}])
        self.assertEqual(rule['rules'], [{'type': 'required_status_checks', 'parameters': {
            'do_not_enforce_on_create': True, 'strict_required_status_checks_policy': False,
            'required_status_checks': [{'context': name, 'integration_id': 15368}
                                       for name in ['ci-node22 / build-test', 'ci-node22 / eligibility']]}}])

    def test_baseline_drift_fails_closed_including_boolean_integer_equivalence(self):
        changes = [lambda b: b.update(id=20515817.0), lambda b: b.update(name='other'),
                   lambda b: b.update(source='other'), lambda b: b.update(enforcement='disabled'),
                   lambda b: b['bypass_actors'].pop(),
                   lambda b: b['bypass_actors'][1].update(actor_id=999),
                   lambda b: b['bypass_actors'][1].update(bypass_mode='pull_request'),
                   lambda b: b['conditions']['ref_name'].update(include=['refs/heads/develop']),
                   lambda b: b['conditions']['repository_property']['include'].pop(),
                   lambda b: b['rules'][0]['parameters'].update(do_not_enforce_on_create=1)]
        for change in changes:
            value = copy.deepcopy(self.baseline)
            change(value)
            with self.assertRaises(policy.PreparationError):
                policy.render(value, 'saved-snapshot')

    def test_full_observation_digest_changes_with_metadata_but_policy_does_not(self):
        observed = dict(self.baseline, updated_at='2026-09-10T00:00:00Z')
        a = policy.render(self.baseline, 'saved-snapshot')
        b = policy.render(observed, 'saved-snapshot')
        self.assertNotEqual(a['baselineDigest'], b['baselineDigest'])
        self.assertEqual(a['ruleset'], b['ruleset'])

    def test_invalid_json_is_rejected(self):
        for raw in (b'{"id":1,"id":2}', b'{"id":NaN}', b'{"id":1e999}', b'\xff', b'{}' * policy.MAX_BYTES):
            with self.assertRaises(policy.PreparationError):
                policy.decode(raw)

    def test_dry_run_only_reads_fixed_baseline_and_property_schema(self):
        outputs = [mock.Mock(stdout=json.dumps(value).encode()) for value in (self.baseline, [])]
        with mock.patch.dict(os.environ, {'GH_HOST': 'untrusted.example'}), \
                mock.patch.object(policy.subprocess, 'run', side_effect=outputs) as execute:
            result = policy.dry_run()
        self.assertEqual(result['propertyState'], 'absent')
        self.assertFalse(result['liveAcceptanceVerified'])
        for call in execute.call_args_list:
            self.assertNotIn('env', call.kwargs)
            self.assertFalse(call.kwargs.get('shell', False))
            self.assertEqual(call.kwargs['timeout'], 30)
        self.assertEqual([call.args[0] for call in execute.call_args_list], [
            ['gh', 'api', '--hostname', 'github.com', '--method', 'GET', policy.BASELINE_PATH],
            ['gh', 'api', '--hostname', 'github.com', '--method', 'GET', policy.PROPERTY_PATH]])

    def test_existing_property_must_match_reviewed_definition(self):
        existing = dict(policy.PROPERTY, property_name=policy.PROPERTY_NAME, source_type='organization')
        with mock.patch.object(policy, 'read_github', side_effect=[self.baseline, [existing]]):
            self.assertEqual(policy.dry_run()['propertyState'], 'compatible')
        for values in ([dict(existing, default_value='node22')], [dict(existing, required=1)],
                       [dict(existing, values_editable_by='org_and_repo_actors')],
                       [existing, existing], {}):
            with mock.patch.object(policy, 'read_github', side_effect=[self.baseline, values]):
                with self.assertRaises(policy.PreparationError):
                    policy.dry_run()

    def test_failed_read_does_not_leak_subprocess_output(self):
        failure = subprocess.CalledProcessError(1, 'gh', stderr=b'credential')
        with mock.patch.object(policy.subprocess, 'run', side_effect=failure):
            with self.assertRaisesRegex(policy.PreparationError, '^GitHub preparation read failed$'):
                policy.dry_run()

    def test_cli_has_no_apply_or_activation_mode_and_offline_render_never_calls_github(self):
        for args in (['apply'], ['activate'], ['dry-run', '--baseline', 'snapshot.json']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                policy.main(args)
            self.assertEqual(caught.exception.code, 2)
        with mock.patch.object(policy, 'read_github') as read, redirect_stdout(io.StringIO()):
            self.assertEqual(policy.main(['render']), 0)
        read.assert_not_called()


if __name__ == '__main__':
    unittest.main()
