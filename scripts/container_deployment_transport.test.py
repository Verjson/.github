#!/usr/bin/env python3
import contextlib
import copy
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError
import zipfile

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('transport', ROOT / 'container_deployment_transport.py')
t = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(t)
NOW = 1_800_000_000

def stamp(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')


def request(operation='probe'):
    return {'schemaVersion': 1, 'operation': operation, 'attemptId': '100.1', 'fleetSelector': 'production', 'lane': 'gate',
            'issuedAt': stamp(NOW - 1), 'expiresAt': stamp(NOW + 60),
            'deploymentContractCommit': 'd' * 40, 'configDigest': 'sha256:' + 'f' * 64, 'planDigest': 'sha256:' + 'e' * 64, 'action': 'deploy', 'rollbackOfAttempt': None,
            'github': {'repository': t.CANARY_REPOSITORY if operation != 'manifest' else 'Verjson/runners',
                       'repositoryId': 11, 'appId': 22, 'installationId': 33},
            'release': {'repository': 'Verjson/runners', 'assetId': 44, 'manifestDigest': 'sha256:' + '1' * 64,
                        'variant': 'pwsh', 'imageDigest': 'sha256:' + '2' * 64, 'sourceCommit': 'a' * 40,
                        'sourceRef': 'refs/heads/main', 'signerWorkflow': 'Verjson/.github/.github/workflows/container-release.yml',
                        'signerCommit': 'b' * 40},
            'probe': {'runnerId': 55, 'runnerName': 'gha-gate-1', 'runnerLabel': 'canary-private',
                      'transactionNonce': '11111111-2222-3333-4444-555555555555', 'workflowId': 66,
                      'workflowRef': 'refs/tags/runner-canary-v1.0.1', 'workflowCommit': 'c' * 40}}


class ProbeAPI:
    def __init__(self, value):
        self.value, self.calls, self.dispatched = value, [], False
        p, r = value['probe'], value['release']
        self.workflow = {'id': p['workflowId'], 'path': t.CANARY_PATH, 'state': 'active'}
        self.tag = {'object': {'type': 'commit', 'sha': p['workflowCommit'],
                    'url': f"https://api.github.com/repos/{t.CANARY_REPOSITORY}/git/commits/{p['workflowCommit']}"}}
        self.baseline = {'workflow_runs': [{'id': 100, 'display_title': 'prior'}]}
        self.record = {'id': 101, 'display_title': 'runner-canary-' + p['transactionNonce'], 'workflow_id': p['workflowId'],
                       'head_sha': p['workflowCommit'], 'head_branch': p['workflowRef'].removeprefix('refs/tags/'),
                       'event': 'workflow_dispatch', 'path': t.CANARY_PATH, 'run_attempt': 1, 'created_at': stamp(NOW),
                       'status': 'completed', 'conclusion': 'success'}
        self.job = {'id': 102, 'name': 'canary', 'runner_id': p['runnerId'], 'runner_name': p['runnerName'],
                    'labels': [p['runnerLabel']], 'status': 'completed', 'conclusion': 'success'}
        self.receipt = {'schemaVersion': 2, 'contract': 'verjson-runner-promotion/2', 'transactionNonce': p['transactionNonce'],
                        'runner': {'id': p['runnerId'], 'name': p['runnerName']},
                        'release': {'manifest': r['manifestDigest'], 'variant': r['variant'], 'imageDigest': r['imageDigest']},
                        'canary': {'repository': t.CANARY_REPOSITORY, 'workflow': 'canonical-db-backed-runner-canary',
                                   'runId': 101, 'jobId': 102, 'runAttempt': 1, 'event': 'workflow_dispatch',
                                   'headBranch': p['workflowRef'].removeprefix('refs/tags/'), 'headSha': p['workflowCommit'],
                                   'workflowPath': t.CANARY_PATH, 'workflowSha': p['workflowCommit'], 'conclusion': 'success',
                                   'databaseServiceReachable': True, 'dockerServiceReachable': True, 'pwshExecuted': True,
                                   'runUrl': f'https://github.com/{t.CANARY_REPOSITORY}/actions/runs/101',
                                   'jobUrl': f'https://github.com/{t.CANARY_REPOSITORY}/actions/runs/101/job/102'},
                        'imageBuild': {'conclusion': 'success', 'imageDigest': r['imageDigest'], 'diskBytesConsumed': 0},
                        'postCanary': {'freeBytes': 20_000_000_000, 'freeInodePercent': 90, 'observedAt': stamp(NOW)},
                        'dependencies': {'uploadArtifactCommit': 'a' * 40, **{name: 'image@sha256:' + 'b' * 64 for name in ('postgresImage', 'nginxImage', 'curlImage', 'buildBaseImage')}}, 'artifact': {'name': 'runner-promotion-receipt', 'contentDigest': ''}}
        self.artifact = {'id': 103, 'name': 'runner-promotion-receipt', 'expired': False, 'workflow_run': {'id': 101}}
        self.archive_path = 'runner-promotion-receipt.json'
        self.refresh_archive()

    def refresh_archive(self):
        self.receipt['artifact']['contentDigest'] = ''
        self.receipt['artifact']['contentDigest'] = t.digest(t.canonical(self.receipt))
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr(self.archive_path, t.canonical(self.receipt))
        self.archive = output.getvalue()
        self.artifact['digest'] = t.digest(self.archive)

    def call(self, method, path, token, body=None, binary=False):
        self.calls.append((method, path, token, body))
        if path.endswith('/dispatches'):
            self.dispatched = True
            return None
        if '/runs?' in path:
            return {'workflow_runs': [self.record]} if self.dispatched else self.baseline
        if path.endswith('/actions/workflows/66'): return self.workflow
        if '/git/ref/' in path: return self.tag
        if '/jobs?' in path: return {'total_count': 1, 'jobs': [self.job]}
        if path.endswith('/artifacts?per_page=100'): return {'total_count': 1, 'artifacts': [self.artifact]}
        if path.endswith('/zip'): return self.archive
        raise AssertionError((method, path))


class RequestTests(unittest.TestCase):
    def test_full_request_preserves_distinct_selector_lane_and_transaction(self):
        value = request()
        self.assertIs(t.validate_request(value, NOW), value)
        self.assertNotEqual(value['fleetSelector'], value['lane'])

    def test_missing_wrong_and_stale_request_fields_fail(self):
        mutations = [lambda v: v.pop('attemptId'), lambda v: v.update(schemaVersion=2),
                     lambda v: v.update(expiresAt=stamp(NOW)), lambda v: v.update(issuedAt=stamp(NOW + 1)),
                     lambda v: v.update(expiresAt=stamp(NOW + 1801)), lambda v: v.update(extra='secret'),
                     lambda v: v.update(schemaVersion=True), lambda v: v['github'].update(repositoryId=11.0), lambda v: v['probe'].update(runnerId=True), lambda v: v['probe'].update(workflowCommit='main'),
                     lambda v: v['probe'].update(transactionNonce=''), lambda v: v['github'].update(repository='attacker/repo')]
        for mutate in mutations:
            value = request(); mutate(value)
            with self.subTest(value=value), self.assertRaises(t.TransportError): t.validate_request(value, NOW)

    def test_rollback_requires_an_independent_attempt_and_binds_response_request(self):
        value = request(); value['action'] = 'rollback'
        with self.assertRaises(t.TransportError): t.validate_request(value, NOW)
        value['rollbackOfAttempt'] = '99.1'
        t.validate_request(value, NOW)
        value['rollbackOfAttempt'] = value['attemptId']
        with self.assertRaises(t.TransportError): t.validate_request(value, NOW)

    def test_preplan_manifest_binds_config_but_dispatch_requires_approved_plan(self):
        value = request('manifest'); value['planDigest'] = None
        t.validate_request(value, NOW)
        value['configDigest'] = None
        with self.assertRaises(t.TransportError): t.validate_request(value, NOW)
        value = request(); value['planDigest'] = None
        with self.assertRaises(t.TransportError): t.validate_request(value, NOW)

    def test_intent_persists_file_and_directory_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'intent.json'
            with mock.patch.object(t.os, 'fsync', wraps=t.os.fsync) as sync:
                t.persist_record(path, {'nonce': 'first'})
                self.assertEqual(sync.call_count, 2)
            with self.assertRaises(FileExistsError): t.persist_record(path, {'nonce': 'second'})
            self.assertEqual(json.loads(path.read_text()), {'nonce': 'first'})

    def test_duplicate_json_fields_fail(self):
        with self.assertRaises(t.TransportError): t.decode(b'{"operation":"probe","operation":"manifest"}')

    def test_host_export_and_dry_run_probe_never_acquire_credentials(self):
        for operation, dry in [('host-export', False), ('probe', True)]:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'request.json'; path.write_text(json.dumps(request(operation)))
                argv = ['transport', '--request', str(path), '--output', str(Path(directory) / 'result')]
                if dry: argv.append('--dry-run')
                with mock.patch.object(sys, 'argv', argv), mock.patch.object(t.time, 'time', return_value=NOW), mock.patch.object(t, 'GitHubHTTP') as api:
                    with self.assertRaises(t.TransportError): t.main()
                    api.assert_not_called()


class AuthTests(unittest.TestCase):
    def api(self, value):
        permissions = copy.deepcopy(t.PERMISSIONS[value['operation']])
        return mock.Mock(call=mock.Mock(side_effect=[
            {'id': 22, 'permissions': permissions},
            {'id': 33, 'app_id': 22, 'account': {'login': 'Verjson'}, 'repository_selection': 'selected', 'suspended_at': None, 'permissions': permissions},
            {'permissions': permissions, 'token': 'installation-secret', 'expires_at': stamp(NOW + 3600)},
            {'total_count': 1, 'repositories': [{'id': 11, 'full_name': value['github']['repository']}]},
        ]))

    def test_role_credential_mints_exact_repository_and_permissions(self):
        for operation in ('manifest', 'probe'):
            value = request(operation); api = self.api(value)
            self.assertEqual(t.installation_token(api, value, 'explicit-app-jwt', NOW), 'installation-secret')
            self.assertEqual(api.call.call_args_list[2].args[3], {'repository_ids': [11], 'permissions': t.PERMISSIONS[operation]})

    def test_missing_credential_does_not_fall_back_to_ambient_tokens(self):
        api = mock.Mock()
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'broad', 'GH_RUNNER_CONTROL_TOKEN': 'control'}):
            with self.assertRaises(t.TransportError): t.installation_token(api, request(), None, NOW)
        api.call.assert_not_called()

    def test_broad_app_wrong_installation_expiry_and_repository_are_rejected(self):
        mutations = [(0, lambda v: v['permissions'].update(organization_self_hosted_runners='write')),
                     (0, lambda v: v.update(id=22.0)), (0, lambda v: v.update(id=9)), (1, lambda v: v.update(repository_selection='all')),
                     (1, lambda v: v.update(app_id=9)), (1, lambda v: v.update(suspended_at=stamp(NOW))),
                     (2, lambda v: v.update(expires_at=stamp(NOW))),
                     (2, lambda v: v.update(permissions={'administration': 'write'})),
                     (3, lambda v: v.update(total_count=True)), (3, lambda v: v.update(total_count=2)),
                     (3, lambda v: v['repositories'][0].update(id=9))]
        for index, mutate in mutations:
            value = request(); api = self.api(value)
            replies = list(api.call.side_effect); replies = copy.deepcopy(replies); mutate(replies[index]); api.call.side_effect = replies
            with self.subTest(index=index), self.assertRaises(t.TransportError): t.installation_token(api, value, 'explicit-app-jwt', NOW)


class ManifestTests(unittest.TestCase):
    def fixture(self):
        value = request('manifest'); r = value['release']
        manifest = {'source': {'repository': r['repository'], 'commit': r['sourceCommit']},
                    'release': {'workflow': {'path': '.github/workflows/container-release.yml', 'contractCommit': r['signerCommit']}},
                    'images': [{'variant': r['variant'], 'indexDigest': r['imageDigest']}]}
        raw = (json.dumps(manifest, indent=2) + '\n').encode(); r['manifestDigest'] = t.digest(raw)
        metadata = {'id': 44, 'name': 'release-manifest.json', 'state': 'uploaded', 'size': len(raw)}
        return value, raw, metadata

    def test_exact_asset_bytes_and_strict_attestation_are_bound(self):
        value, raw, metadata = self.fixture(); api = mock.Mock(call=mock.Mock(side_effect=[{'id': value['github']['repositoryId'], 'full_name': value['github']['repository']}, metadata, raw]))
        verifier = mock.Mock(return_value=mock.Mock(stdout=b'[{}]'))
        with mock.patch.dict(os.environ, {'HOME': '/untrusted', 'SSH_AUTH_SOCK': 'agent', 'DIGITALOCEAN_RUNNER_FLEET_TOKEN': 'mutation'}):
            result = t.fetch_manifest(api, value, 'read-only-token', run=verifier, clock=lambda: NOW)
        self.assertEqual(result['manifestBytes'].encode(), raw)
        args, kwargs = verifier.call_args
        for flag in ('--signer-workflow', '--signer-digest', '--source-ref', '--source-digest'): self.assertIn(flag, args[0])
        self.assertEqual(set(kwargs['env']), {'PATH', 'HOME', 'GH_TOKEN', 'GH_HOST'})
        self.assertNotEqual(kwargs['env']['HOME'], '/untrusted')
        self.assertEqual(kwargs['env']['GH_TOKEN'], 'read-only-token')

    def test_renamed_repository_uses_stable_api_identity_and_historical_signed_source(self):
        raw = (Path(__file__).parent / 'fixtures/container-deployment/transport/runner-v0.2.1-manifest.json').read_bytes()
        self.assertEqual(t.digest(raw), 'sha256:4f5bb96e1fe07f7b56cfe124206ed85c4e59b9715b3b4e18b3054d890dd1ad32')
        manifest = json.loads(raw)
        value = request('manifest')
        value['github'].update(repository='Verjson/verjson-git-runners', repositoryId=1301436066)
        value['release'].update(repository='Verjson/verjson-github-runner', assetId=532627568,
                                manifestDigest=t.digest(raw), sourceCommit=manifest['source']['commit'],
                                signerCommit=manifest['release']['workflow']['contractCommit'],
                                imageDigest=next(image['indexDigest'] for image in manifest['images'] if image['variant'] == 'pwsh'))
        repository = {'id': 1301436066, 'full_name': 'Verjson/verjson-git-runners'}
        metadata = {'id': 532627568, 'name': 'release-manifest.json', 'state': 'uploaded', 'size': len(raw)}
        verifier = mock.Mock(return_value=mock.Mock(stdout=b'[{}]'))
        api = mock.Mock(call=mock.Mock(side_effect=[repository, metadata, raw]))
        result = t.fetch_manifest(api, value, 'read', run=verifier, clock=lambda: NOW)
        self.assertEqual(result['manifestBytes'].encode(), raw)
        self.assertEqual(api.call.call_args_list[0].args[1], '/repositories/1301436066')
        self.assertEqual(api.call.call_args_list[1].args[1], '/repos/Verjson/verjson-git-runners/releases/assets/532627568')
        args = verifier.call_args.args[0]
        self.assertEqual(args[args.index('--repo') + 1], 'Verjson/verjson-github-runner')
        self.assertEqual(args[args.index('--source-digest') + 1], manifest['source']['commit'])
        self.assertEqual(args[args.index('--signer-digest') + 1], manifest['release']['workflow']['contractCommit'])
        for changed in ({'id': 99, 'full_name': repository['full_name']},
                        {'id': 1301436066, 'full_name': 'Verjson/unreviewed-renamed-repository'}):
            verifier.reset_mock()
            with self.assertRaises(t.TransportError):
                t.fetch_manifest(mock.Mock(call=mock.Mock(return_value=changed)), value, 'read', run=verifier, clock=lambda: NOW)
            verifier.assert_not_called()
        wrong_source = copy.deepcopy(value); wrong_source['release']['repository'] = 'Verjson/verjson-git-runners'
        with self.assertRaises(t.TransportError):
            t.fetch_manifest(mock.Mock(call=mock.Mock(side_effect=[repository, metadata, raw])), wrong_source, 'read', run=verifier, clock=lambda: NOW)
        verifier.assert_not_called()

    def test_altered_asset_and_failed_attestation_never_return_evidence(self):
        value, raw, metadata = self.fixture()
        with self.assertRaises(t.TransportError): t.fetch_manifest(mock.Mock(call=mock.Mock(side_effect=[{'id': value['github']['repositoryId'], 'full_name': value['github']['repository']}, metadata, raw + b' '])), value, 'read', clock=lambda: NOW)
        verifier = mock.Mock(side_effect=subprocess.CalledProcessError(1, 'gh', stderr='Authorization: secret'))
        with self.assertRaisesRegex(t.TransportError, '^release attestation verification failed$'):
            t.fetch_manifest(mock.Mock(call=mock.Mock(side_effect=[{'id': value['github']['repositoryId'], 'full_name': value['github']['repository']}, metadata, raw])), value, 'read', run=verifier, clock=lambda: NOW)


class ProbeTests(unittest.TestCase):
    def run_probe(self, api):
        intents = []
        result = t.probe_runner(api, api.value, 'dispatch-token', record_intent=intents.append, clock=lambda: NOW, sleep=lambda _: self.fail('unexpected wait'))
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]['preDispatchMaxRunId'], 100)
        return result

    def test_real_dispatch_shape_and_authenticated_receipt_bind_every_identity(self):
        value = request(); api = ProbeAPI(value); result = self.run_probe(api)
        self.assertEqual(result['outcome'], 'passed')
        self.assertEqual(result['requestDigest'], t.digest(t.canonical(value)))
        posts = [call for call in api.calls if call[0] == 'POST']
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][3]['ref'], 'runner-canary-v1.0.1')
        self.assertEqual(set(posts[0][3]['inputs']), {'runner_name', 'runner_id', 'runner_label', 'transaction_nonce', 'release_manifest', 'release_variant', 'image_digest'})

    def test_wrong_runner_nonce_manifest_image_workflow_or_stale_receipt_fails(self):
        mutations = [lambda r: r.update(schemaVersion=2.0), lambda r: r['runner'].update(id=55.0), lambda r: r['runner'].update(id=9), lambda r: r.update(transactionNonce='replayed'),
                     lambda r: r['release'].update(manifest='sha256:' + '9' * 64), lambda r: r['release'].update(imageDigest='sha256:' + '9' * 64),
                     lambda r: r['canary'].update(workflowSha='9' * 40), lambda r: r['canary'].update(runAttempt=2),
                     lambda r: r['canary'].update(pwshExecuted=False), lambda r: r['canary'].update(databaseServiceReachable=1),
                     lambda r: r['canary'].update(runAttempt=True), lambda r: r['canary'].update(runId=101.0), lambda r: r['postCanary'].update(observedAt=stamp(NOW - 1900)),
                     lambda r: r['postCanary'].update(freeBytes=0), lambda r: r['imageBuild'].update(diskBytesConsumed=True),
                     lambda r: r['dependencies'].update(postgresImage='postgres:latest')]
        for mutate in mutations:
            api = ProbeAPI(request()); mutate(api.receipt); api.refresh_archive()
            with self.subTest(mutate=mutate), self.assertRaises(t.TransportError): self.run_probe(api)

    def test_run_job_artifact_and_tag_independent_evidence_mismatch_fails(self):
        mutations = [lambda a: a.record.update(id=99), lambda a: a.record.update(run_attempt=2), lambda a: a.record.update(run_attempt=True),
                     lambda a: a.record.update(head_sha='9' * 40), lambda a: a.record.update(conclusion='failure'),
                     lambda a: a.job.update(runner_id=9), lambda a: a.job.update(labels=['other']),
                     lambda a: a.artifact.update(expired=True), lambda a: a.artifact.update(digest='sha256:' + '9' * 64),
                     lambda a: a.artifact['workflow_run'].update(id=9), lambda a: a.tag['object'].update(sha='9' * 40)]
        for mutate in mutations:
            api = ProbeAPI(request()); mutate(api)
            with self.subTest(mutate=mutate), self.assertRaises(t.TransportError): self.run_probe(api)

    def test_replayed_nonce_and_unpersisted_intent_prevent_dispatch(self):
        api = ProbeAPI(request()); api.baseline['workflow_runs'][0]['display_title'] = 'runner-canary-' + api.value['probe']['transactionNonce']
        with self.assertRaises(t.TransportError): self.run_probe(api)
        self.assertFalse(api.dispatched)
        api = ProbeAPI(request())
        with self.assertRaises(FileExistsError):
            t.probe_runner(api, api.value, 'token', record_intent=mock.Mock(side_effect=FileExistsError()), clock=lambda: NOW)
        self.assertFalse(api.dispatched)

    def test_uncertain_dispatch_is_never_retried(self):
        api = ProbeAPI(request()); original = api.call
        def fail(method, path, token, body=None, binary=False):
            if path.endswith('/dispatches'):
                api.calls.append((method, path, token, body)); raise t.TransportError('uncertain dispatch')
            return original(method, path, token, body, binary)
        api.call = fail
        with self.assertRaises(t.TransportError): self.run_probe(api)
        self.assertEqual(sum(call[0] == 'POST' for call in api.calls), 1)

    def test_archive_traversal_is_rejected_without_extracting_files(self):
        api = ProbeAPI(request()); api.archive_path = '../receipt.json'; api.refresh_archive()
        with self.assertRaises(t.TransportError): self.run_probe(api)

    def test_timeout_never_returns_a_success_receipt(self):
        api = ProbeAPI(request()); api.record['status'] = 'in_progress'; current = [NOW]
        def advance(seconds): current[0] += seconds
        with self.assertRaisesRegex(t.TransportError, 'timed out'):
            t.probe_runner(api, api.value, 'token', record_intent=lambda _: None, clock=lambda: current[0], sleep=advance)


class HTTPTests(unittest.TestCase):
    def test_api_error_redacts_body_and_token(self):
        api = t.GitHubHTTP(); api.opener = mock.Mock()
        api.opener.open.side_effect = HTTPError('https://api.github.com/path', 403, 'Authorization: secret', {}, None)
        with self.assertRaisesRegex(t.TransportError, '^GitHub request failed with HTTP 403$'): api.call('GET', '/path', 'secret')

    def test_asset_redirect_never_forwards_api_authorization(self):
        api = t.GitHubHTTP(); api.opener = mock.Mock()
        redirect = HTTPError('https://api.github.com/path', 302, 'redirect', {'Location': 'https://release-assets.githubusercontent.com/signed'}, None)
        response = mock.MagicMock(); response.__enter__.return_value.read.return_value = b'bytes'
        api.opener.open.side_effect = [redirect, response]
        self.assertEqual(api.call('GET', '/path', 'secret', binary=True), b'bytes')
        second = api.opener.open.call_args_list[1].args[0]
        self.assertIsNone(second.get_header('Authorization'))

    def test_unreviewed_redirect_is_not_followed(self):
        for destination in ('http://release-assets.githubusercontent.com/x', 'https://attacker.invalid/x', 'https://user@release-assets.githubusercontent.com/x'):
            api = t.GitHubHTTP(); api.opener = mock.Mock()
            api.opener.open.side_effect = HTTPError('https://api.github.com/path', 302, 'redirect', {'Location': destination}, None)
            with self.subTest(destination=destination), self.assertRaises(t.TransportError): api.call('GET', '/path', 'secret', binary=True)
            self.assertEqual(api.opener.open.call_count, 1)


if __name__ == '__main__':
    unittest.main()
