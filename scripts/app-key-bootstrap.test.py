#!/usr/bin/env python3
import base64
from copy import deepcopy
from datetime import datetime, timezone
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

SPEC = importlib.util.spec_from_file_location('bootstrap', Path(__file__).with_name('app-key-bootstrap.py'))
B = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(B)
SHA = 'a' * 40
NOW = datetime(2026, 9, 10, 2, tzinfo=timezone.utc)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.contract = B.load_contract()
        self.environment = dict(GITHUB_REPOSITORY=B.REPOSITORY, GITHUB_REPOSITORY_ID=str(B.REPOSITORY_ID),
            GITHUB_REF='refs/heads/main', GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_RUN_ATTEMPT='1',
            GITHUB_WORKFLOW_REF=f'{B.REPOSITORY}/{B.SEAL_WORKFLOW}@refs/heads/main', GITHUB_SHA=SHA, GITHUB_RUN_ID='42')
        self.environment.update({secret: 'test-only-value-' * 20 for secret in B.ROLES.values()})
        self.document = B.seal(self.contract, self.environment.copy(), lambda value, key: base64.b64encode(b'x' * 348).decode())

    def test_sealing_removes_source_values_and_emits_only_ciphertext(self):
        encrypt = Mock(return_value=base64.b64encode(b'x' * 348).decode())
        result = B.seal(self.contract, self.environment, encrypt)
        self.assertEqual(encrypt.call_count, 3)
        self.assertFalse(set(B.ROLES.values()) & self.environment.keys())
        self.assertNotIn('test-only-value', json.dumps(result))

    def test_untrusted_events_refs_and_attempts_never_encrypt(self):
        for field, value in [('GITHUB_REF', 'refs/pull/1/merge'), ('GITHUB_EVENT_NAME', 'push'),
                ('GITHUB_RUN_ATTEMPT', '2'), ('GITHUB_REPOSITORY_ID', '1'), ('GITHUB_WORKFLOW_REF', 'other')]:
            with self.subTest(field=field):
                encrypt = Mock()
                with self.assertRaises(B.BootstrapError):
                    B.seal(self.contract, {**self.environment, field: value}, encrypt)
                encrypt.assert_not_called()

    def artifact_api(self, document=None, metadata_change=None, extra_file=False):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('sealed-keys.json', json.dumps(document or self.document))
            if extra_file:
                archive.writestr('unexpected', 'x')
        raw = stream.getvalue()
        artifact = dict(id=7, name='app-key-bootstrap-42-1', expired=False, size_in_bytes=len(raw), digest=B.digest(raw),
            workflow_run=dict(id=42, repository_id=B.REPOSITORY_ID, head_repository_id=B.REPOSITORY_ID, head_sha=SHA, head_branch='main'))
        artifact.update(metadata_change or {})
        return Mock(request=Mock(side_effect=[dict(total_count=1, artifacts=[artifact]), raw]))

    def test_exact_ciphertext_artifact_is_accepted(self):
        document, receipt = B.download_ciphertext(self.artifact_api(), self.contract, SHA, 42)
        self.assertEqual(document, self.document)
        self.assertEqual(receipt['artifact_id'], 7)

    def test_artifact_tamper_origin_expiration_and_extra_members_fail(self):
        for change in [dict(digest='sha256:bad'), dict(expired=True), dict(name='other'), dict(workflow_run={})]:
            with self.subTest(change=change), self.assertRaises(B.BootstrapError):
                B.download_ciphertext(self.artifact_api(metadata_change=change), self.contract, SHA, 42)
        with self.assertRaises(B.BootstrapError):
            B.download_ciphertext(self.artifact_api(extra_file=True), self.contract, SHA, 42)

    def test_destination_changes_boolean_identity_and_invalid_ciphertext_fail(self):
        documents = []
        for field, value in [('schema', True), ('run_attempt', True), ('source_sha', 'b' * 40)]:
            documents.append({**self.document, field: value})
        altered = deepcopy(self.document)
        altered['roles']['release']['destination']['environment'] = 'other'
        documents.append(altered)
        altered = deepcopy(self.document)
        altered['roles']['release']['encrypted_value'] = 'plaintext'
        documents.append(altered)
        for document in documents:
            with self.subTest(document=document.keys()), self.assertRaises((B.BootstrapError, ValueError)):
                B.download_ciphertext(self.artifact_api(document), self.contract, SHA, 42)

    def test_ambiguous_json_is_rejected(self):
        for raw in ['{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}']:
            with self.assertRaises(B.BootstrapError):
                B.strict_json(raw)

    def environment_api(self, mutate=None):
        t = self.contract['roles']['release']
        responses = [dict(id=t['environment_id'], name=t['environment'],
            deployment_branch_policy=dict(protected_branches=False, custom_branch_policies=True),
            protection_rules=[dict(type='branch_policy', id=t['protection_rule_id'])]),
            dict(total_count=1, branch_policies=[dict(id=t['branch_policy_id'], name='main', type='branch')]), deepcopy(t['public_key'])]
        if mutate:
            mutate(responses)
        return Mock(request=Mock(side_effect=responses))

    def test_environment_policy_identity_and_rotated_keys_fail_closed(self):
        B.validate_environment(self.environment_api(), self.contract['roles']['release'])
        mutations = [lambda r: r[0].update(id=1), lambda r: r[0].update(deployment_branch_policy=None),
            lambda r: r[1]['branch_policies'][0].update(name='*'), lambda r: r[2].update(key_id='rotated')]
        for mutate in mutations:
            with self.subTest(mutate=mutate), self.assertRaises(B.BootstrapError):
                B.validate_environment(self.environment_api(lambda r: mutate(r)), deepcopy(self.contract['roles']['release']))

    def test_run_requires_exact_successful_first_attempt_and_fresh_origin(self):
        run = dict(id=42, event='workflow_dispatch', run_attempt=1, head_sha=SHA, head_branch='main', path=B.SEAL_WORKFLOW,
            repository=dict(id=B.REPOSITORY_ID), head_repository=dict(id=B.REPOSITORY_ID), workflow_id=10,
            status='completed', conclusion='success', created_at='2026-09-10T01:00:00Z')
        registration = dict(id=10, path=B.SEAL_WORKFLOW, state='active')
        B.validate_run(Mock(request=Mock(side_effect=[run, registration])), SHA, 42, B.SEAL_WORKFLOW, NOW)
        for field, value in [('run_attempt', 2), ('head_sha', 'b' * 40), ('conclusion', 'failure'), ('created_at', '2026-09-01T00:00:00Z')]:
            with self.subTest(field=field), self.assertRaises(B.BootstrapError):
                B.validate_run(Mock(request=Mock(side_effect=[{**run, field: value}, registration])), SHA, 42, B.SEAL_WORKFLOW, NOW)

    def test_minted_scope_rejects_other_app_and_broader_repository_access(self):
        t = self.contract['roles']['release']
        env = dict(MINTED_APP_SLUG=t['app_slug'], MINTED_INSTALLATION_ID=str(t['installation_id']))
        repos = dict(total_count=1, repositories=[dict(id=B.REPOSITORY_ID, full_name=B.REPOSITORY)])
        B.verify_scope(self.contract, 'release', env, repos)
        for environment, repositories in [({**env, 'MINTED_APP_SLUG': 'other'}, repos), (env, {**repos, 'total_count': 2})]:
            with self.assertRaises(B.BootstrapError):
                B.verify_scope(self.contract, 'release', environment, repositories)

    def test_apply_records_uncertain_before_put_failure_and_never_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'receipt.json'
            api = Mock()
            def request(path, method='GET', body=None):
                if method == 'PUT':
                    self.assertEqual(json.loads(receipt.read_text())['roles']['release']['state'], 'uncertain')
                    raise B.BootstrapError('simulated transport failure')
                self.fail('unexpected request')
            api.request.side_effect = request
            with patch.object(B, 'validate_source'), patch.object(B, 'validate_run'), \
                    patch.object(B, 'download_ciphertext', return_value=(self.document, {})), \
                    patch.object(B, 'validate_environment', return_value='fixed'), patch.object(B, 'require_absent') as absent:
                with self.assertRaises(B.BootstrapError):
                    B.apply(api, self.contract, SHA, 42, ['release'], receipt)
                self.assertEqual(absent.call_count, 2)
                with self.assertRaises(B.BootstrapError):
                    B.apply(api, self.contract, SHA, 42, ['release'], receipt)
            self.assertEqual(api.request.call_count, 1)
            self.assertEqual(list(Path(directory).iterdir()), [receipt])

    def test_existing_destination_prevents_write(self):
        api = Mock(request=Mock(return_value=dict(total_count=1, secrets=[dict(name=B.ROLES['release'])])))
        with self.assertRaises(B.BootstrapError):
            B.require_absent(api, 'fixed', self.contract['roles']['release'])
        self.assertEqual(api.request.call_args.args, ('fixed/secrets',))

    def test_verification_rejects_run_before_provisioning_or_incomplete_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'
            receipt = dict(source_sha=SHA, repository=B.REPOSITORY, roles={role: dict(state='created',
                environment_id=t['environment_id'], updated_at='2026-09-10T01:00:00Z') for role, t in self.contract['roles'].items()})
            path.write_text(json.dumps(receipt))
            with patch.object(B, 'validate_source'), patch.object(B, 'validate_run', return_value=dict(created_at='2026-09-10T00:59:59Z')):
                with self.assertRaises(B.BootstrapError):
                    B.verify_receipt(Mock(), self.contract, SHA, 43, [path])
            receipt['roles'].pop('review')
            path.write_text(json.dumps(receipt))
            with patch.object(B, 'validate_source'), patch.object(B, 'validate_run', return_value=dict(created_at='2026-09-10T02:00:00Z')):
                with self.assertRaises(B.BootstrapError):
                    B.verify_receipt(Mock(), self.contract, SHA, 43, [path])

    def test_successful_import_and_fresh_environment_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'
            api = Mock()
            def request(endpoint, method='GET', body=None):
                if method == 'PUT':
                    self.assertEqual(set(body), {'encrypted_value', 'key_id'})
                    self.assertNotIn('test-only-value', json.dumps(body))
                    return {}
                if endpoint.endswith('/jobs'):
                    return dict(total_count=3, jobs=[dict(name='verify-' + role, conclusion='success') for role in B.ROLES])
                return dict(name=endpoint.rsplit('/', 1)[1], updated_at='2026-09-10T01:00:00Z')
            api.request.side_effect = request
            def environment(api, target):
                return f"repos/{B.REPOSITORY}/environments/{target['environment']}"
            with patch.object(B, 'validate_source'), patch.object(B, 'validate_run', return_value=dict(created_at='2026-09-10T02:00:00Z')), \
                    patch.object(B, 'download_ciphertext', return_value=(self.document, dict(artifact_id=7))), \
                    patch.object(B, 'validate_environment', side_effect=environment), patch.object(B, 'require_absent'):
                B.apply(api, self.contract, SHA, 42, list(B.ROLES), path)
                B.verify_receipt(api, self.contract, SHA, 43, [path])
            self.assertEqual({v['state'] for v in json.loads(path.read_text())['roles'].values()}, {'created'})
            self.assertEqual(sum(call.args[1:2] == ('PUT',) for call in api.request.call_args_list), 3)

    def test_workflows_bind_exact_environment_client_and_secret_without_dispatch_inputs(self):
        import yaml
        seal = yaml.safe_load((B.ROOT / B.SEAL_WORKFLOW).read_text())
        verify = yaml.safe_load((B.ROOT / B.VERIFY_WORKFLOW).read_text())
        for workflow in (seal, verify):
            self.assertEqual(workflow.get('on', workflow.get(True)), {'workflow_dispatch': None})
            self.assertEqual(workflow['permissions'], {'contents': 'read'})
            for job in workflow['jobs'].values():
                self.assertEqual(job['runs-on'], 'ubuntu-24.04')
                self.assertIn("github.ref == 'refs/heads/main'", job['if'])
                self.assertIn('github.run_attempt == 1', job['if'])
        for role, target in self.contract['roles'].items():
            job = verify['jobs']['verify-' + role]
            self.assertEqual(job['environment'], target['environment'])
            action = job['steps'][1]['with']
            self.assertEqual(action['client-id'], target['client_id'])
            self.assertEqual(action['private-key'], '${{ secrets.' + target['secret'] + ' }}')
            self.assertEqual(action['repositories'], '.github')
            self.assertEqual(action['permission-contents'], 'read')


if __name__ == '__main__':
    unittest.main()
