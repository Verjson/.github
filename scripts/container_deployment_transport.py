#!/usr/bin/env python3
"""Credential-separated GitHub transport; host observation remains blocked by CLI #504."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from datetime import datetime
from urllib import error, parse, request
import zipfile

MAX_BYTES = 2_000_000
SHA = re.compile(r'[0-9a-f]{40}')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')
CANARY_PATH = '.github/workflows/runner-canary.yml'
CANARY_REPOSITORY = 'Verjson/.github'
PERMISSIONS = {
    'manifest': {'metadata': 'read', 'contents': 'read', 'attestations': 'read'},
    'probe': {'metadata': 'read', 'contents': 'read', 'actions': 'write'},
}


class TransportError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise TransportError(message)


def object_keys(value, keys, name):
    require(isinstance(value, dict) and set(value) == set(keys), f'{name} fields differ')


def positive(value):
    return type(value) is int and value > 0


def timestamp(value):
    require(isinstance(value, str) and value.endswith('Z'), 'timestamp must be UTC')
    try:
        return datetime.fromisoformat(value[:-1] + '+00:00').timestamp()
    except ValueError:
        raise TransportError('timestamp is invalid') from None


def digest(raw):
    return 'sha256:' + hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def persist_record(path, value):
    with path.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(value, sort_keys=True) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def decode(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicate JSON field')
            result[key] = value
        return result
    require(len(raw) <= MAX_BYTES, 'JSON exceeds transport size limit')
    try:
        return json.loads(raw, object_pairs_hook=unique, parse_constant=lambda _: require(False, 'non-finite JSON number'))
    except (UnicodeError, json.JSONDecodeError):
        raise TransportError('transport JSON is invalid') from None


def validate_request(value, now):
    object_keys(value, ('schemaVersion', 'operation', 'attemptId', 'fleetSelector', 'lane',
                       'issuedAt', 'expiresAt', 'deploymentContractCommit', 'configDigest', 'planDigest', 'action', 'rollbackOfAttempt',
                       'github', 'release', 'probe'), 'request')
    require(value['schemaVersion'] == 1 and type(value['schemaVersion']) is int, 'unsupported request version')
    operation = value['operation']
    require(operation in ('manifest', 'probe', 'host-export'), 'unsupported transport operation')
    require(isinstance(value['attemptId'], str) and re.fullmatch(r'[1-9][0-9]*\.[1-9][0-9]*', value['attemptId']), 'attempt identity is invalid')
    require(isinstance(value['deploymentContractCommit'], str) and SHA.fullmatch(value['deploymentContractCommit']), 'deployment contract must be immutable')
    require(isinstance(value['configDigest'], str) and DIGEST.fullmatch(value['configDigest']), 'admitted configuration digest is invalid')
    require((operation != 'probe' and value['planDigest'] is None) or
            (isinstance(value['planDigest'], str) and DIGEST.fullmatch(value['planDigest'])), 'approved plan digest is invalid')
    require(value['action'] in ('deploy', 'rollback'), 'deployment action is invalid')
    rollback = value['rollbackOfAttempt']
    require((value['action'] == 'deploy' and rollback is None) or
            (value['action'] == 'rollback' and isinstance(rollback, str)
             and re.fullmatch(r'[1-9][0-9]*\.[1-9][0-9]*', rollback) and rollback != value['attemptId']),
            'rollback attempt identity is invalid')
    for field in ('fleetSelector', 'lane'):
        require(isinstance(value[field], str) and re.fullmatch(r'[a-z][a-z0-9_-]{1,31}', value[field]), f'{field} is invalid')
    issued, expires = timestamp(value['issuedAt']), timestamp(value['expiresAt'])
    require(issued == int(issued) and expires == int(expires), 'request timestamps must use whole seconds')
    require(issued <= now < expires and expires - issued <= 1800, 'request is stale or exceeds bounded lifetime')
    github = value['github']
    object_keys(github, ('repository', 'repositoryId', 'appId', 'installationId'), 'GitHub authority')
    require(isinstance(github['repository'], str) and re.fullmatch(r'[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+', github['repository'])
            and github['repository'].split('/')[1] not in ('.', '..'), 'repository identity is invalid')
    require(all(positive(github[k]) for k in ('repositoryId', 'appId', 'installationId')), 'reviewed numeric GitHub identities are required')
    release = value['release']
    object_keys(release, ('repository', 'assetId', 'manifestDigest', 'variant', 'imageDigest',
                         'sourceCommit', 'sourceRef', 'signerWorkflow', 'signerCommit'), 'release')
    require(isinstance(release['repository'], str) and re.fullmatch(r'[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+', release['repository'])
            and release['repository'].split('/')[1] not in ('.', '..'), 'release repository is invalid')
    require(positive(release['assetId']), 'release asset identity is required')
    for field in ('manifestDigest', 'imageDigest'):
        require(isinstance(release[field], str) and DIGEST.fullmatch(release[field]), f'{field} is invalid')
    for field in ('sourceCommit', 'signerCommit'):
        require(isinstance(release[field], str) and SHA.fullmatch(release[field]), f'{field} must be immutable')
    require(release['sourceRef'] == 'refs/heads/main', 'release source must be main')
    require(release['signerWorkflow'] == 'Verjson/.github/.github/workflows/container-release.yml', 'release signer differs')
    require(isinstance(release['variant'], str) and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', release['variant']), 'release variant is invalid')
    probe = value['probe']
    object_keys(probe, ('runnerId', 'runnerName', 'runnerLabel', 'transactionNonce', 'workflowId', 'workflowRef', 'workflowCommit'), 'probe')
    require(positive(probe['runnerId']) and positive(probe['workflowId']), 'exact runner/workflow IDs are required')
    for field in ('runnerName', 'runnerLabel'):
        require(isinstance(probe[field], str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', probe[field]), f'{field} is invalid')
    require(isinstance(probe['transactionNonce'], str) and re.fullmatch(r'[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}', probe['transactionNonce']), 'transaction nonce must be an exact UUID')
    require(isinstance(probe['workflowCommit'], str) and SHA.fullmatch(probe['workflowCommit']), 'canary workflow commit must be immutable')
    require(isinstance(probe['workflowRef'], str) and re.fullmatch(r'refs/tags/runner-canary-v[0-9]+\.[0-9]+\.[0-9]+', probe['workflowRef']), 'reviewed canary tag is required')
    if operation == 'probe':
        require(github['repository'] == CANARY_REPOSITORY, 'canary dispatch targets another repository')
    return value


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHubHTTP:
    def __init__(self):
        self.opener = request.build_opener(request.ProxyHandler({}), NoRedirect())

    def call(self, method, path, token, body=None, binary=False):
        require(path.startswith('/') and not path.startswith('//') and '\\' not in path, 'invalid API path')
        headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/octet-stream' if binary else 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json'}
        req = request.Request('https://api.github.com' + path, data=None if body is None else canonical(body), headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as response:
                raw = response.read(MAX_BYTES + 1)
        except error.HTTPError as failure:
            if binary and method == 'GET' and failure.code in (301, 302, 303, 307, 308):
                location = failure.headers.get('Location', '')
                target = parse.urlsplit(location)
                host = target.hostname or ''
                require(target.scheme == 'https' and target.port in (None, 443) and not target.username and not target.password
                        and (host in ('objects.githubusercontent.com', 'release-assets.githubusercontent.com')
                             or host.endswith('.blob.core.windows.net') or host.endswith('.actions.githubusercontent.com')),
                        'asset redirect escaped reviewed storage hosts')
                # Signed storage receives no API Authorization header or ambient credentials.
                try:
                    with self.opener.open(request.Request(location), timeout=30) as response:
                        raw = response.read(MAX_BYTES + 1)
                except (error.URLError, OSError):
                    raise TransportError('asset download failed') from None
            else:
                raise TransportError(f'GitHub request failed with HTTP {failure.code}') from None
        except (error.URLError, OSError):
            raise TransportError('GitHub transport failed') from None
        require(len(raw) <= MAX_BYTES, 'GitHub response exceeds size limit')
        if binary:
            return raw
        value = decode(raw) if raw else None
        require(value is None or isinstance(value, dict), 'GitHub response is not an object')
        return value


def installation_token(api, value, jwt, now):
    require(isinstance(jwt, str) and jwt and '\n' not in jwt, 'explicit dedicated App JWT is required')
    operation = value['operation']
    require(operation in PERMISSIONS, 'host export has no GitHub credential capability')
    expected = PERMISSIONS[operation]
    authority = value['github']
    app = api.call('GET', '/app', jwt)
    require(positive(app.get('id')) and app['id'] == authority['appId'] and app.get('permissions') == expected,
            'App identity or permissions differ from the dedicated transport role')
    installation = api.call('GET', f"/app/installations/{authority['installationId']}", jwt)
    require(positive(installation.get('id')) and positive(installation.get('app_id')) and installation['id'] == authority['installationId'] and installation.get('app_id') == authority['appId']
            and installation.get('account', {}).get('login') == authority['repository'].split('/')[0]
            and installation.get('repository_selection') == 'selected' and installation.get('suspended_at') is None
            and installation.get('permissions') == expected, 'installation identity or scope differs')
    minted = api.call('POST', f"/app/installations/{authority['installationId']}/access_tokens", jwt,
                      {'repository_ids': [authority['repositoryId']], 'permissions': expected})
    require(minted.get('permissions') == expected and isinstance(minted.get('token'), str) and minted['token'], 'minted token permissions differ')
    require(now < timestamp(minted.get('expires_at')) <= now + 3660, 'installation token expiry is invalid')
    token = minted['token']
    repositories = api.call('GET', '/installation/repositories?per_page=100', token)
    require(type(repositories.get('total_count')) is int and repositories['total_count'] == 1 and len(repositories.get('repositories', [])) == 1,
            'installation token is not scoped to one repository')
    repository = repositories['repositories'][0]
    require(positive(repository.get('id')) and repository['id'] == authority['repositoryId'] and repository.get('full_name') == authority['repository'], 'installation token repository differs')
    return token


def fetch_manifest(api, value, token, run=subprocess.run, clock=time.time):
    validate_request(value, clock())
    release = value['release']
    authority = value['github']
    repository = api.call('GET', f"/repositories/{authority['repositoryId']}", token)
    require(positive(repository.get('id')) and repository['id'] == authority['repositoryId']
            and repository.get('full_name') == authority['repository'], 'release API repository identity differs')
    path = f"/repos/{authority['repository']}/releases/assets/{release['assetId']}"
    metadata = api.call('GET', path, token)
    require(positive(metadata.get('id')) and metadata['id'] == release['assetId'] and metadata.get('name') == 'release-manifest.json'
            and metadata.get('state') == 'uploaded' and positive(metadata.get('size')) and metadata['size'] <= MAX_BYTES,
            'release asset metadata differs')
    raw = api.call('GET', path, token, binary=True)
    require(len(raw) == metadata['size'] and digest(raw) == release['manifestDigest'], 'release asset bytes differ from reviewed digest')
    manifest = decode(raw)
    require(manifest.get('source', {}).get('repository') == release['repository']
            and manifest['source'].get('commit') == release['sourceCommit'], 'manifest source differs')
    workflow = manifest.get('release', {}).get('workflow', {})
    require(workflow.get('path') == '.github/workflows/container-release.yml' and workflow.get('contractCommit') == release['signerCommit'], 'manifest release signer differs')
    images = manifest.get('images')
    require(isinstance(images, list), 'manifest images are invalid')
    selected = [image for image in images if isinstance(image, dict) and image.get('variant') == release['variant']]
    require(len(selected) == 1 and selected[0].get('indexDigest') == release['imageDigest'], 'manifest variant/image differs')
    with tempfile.TemporaryDirectory(prefix='deployment-manifest-') as directory:
        subject = Path(directory) / 'release-manifest.json'
        subject.write_bytes(raw)
        # No HOME configuration, SSH agent, mutation token, or App JWT reaches gh.
        environment = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': directory, 'GH_TOKEN': token, 'GH_HOST': 'github.com'}
        try:
            verified = run(['gh', 'attestation', 'verify', str(subject), '--repo', release['repository'],
                            '--signer-workflow', release['signerWorkflow'], '--signer-digest', release['signerCommit'],
                            '--source-ref', release['sourceRef'], '--source-digest', release['sourceCommit'], '--format', 'json'],
                           check=True, capture_output=True, timeout=120, env=environment)
        except (OSError, subprocess.SubprocessError):
            raise TransportError('release attestation verification failed') from None
        verification = decode(verified.stdout)
        require(isinstance(verification, list) and verification, 'attestation verifier returned no verified evidence')
    validate_request(value, clock())
    return {'schemaVersion': 1, 'requestDigest': digest(canonical(value)), 'manifestIdentity': digest(raw),
            'manifestBytes': raw.decode('utf-8'), 'manifest': manifest,
            'attestation': {'verified': True, 'repository': release['repository'], 'sourceRef': release['sourceRef'],
                            'sourceCommit': release['sourceCommit'], 'signerWorkflow': release['signerWorkflow'],
                            'contractCommit': release['signerCommit'], 'subjectDigest': digest(raw),
                            'expiresAt': value['expiresAt'], 'verificationDigest': digest(canonical(verification))}}


def validate_probe_receipt(value, receipt, run_record, job, artifact, now):
    validate_request(value, now)
    probe, release = value['probe'], value['release']
    require(positive(run_record.get('id')) and type(run_record.get('run_attempt')) is int
            and run_record['run_attempt'] == 1 and positive(job.get('id')), 'independent run/job scalar types differ')
    object_keys(receipt, ('schemaVersion', 'contract', 'transactionNonce', 'runner', 'release', 'canary',
                          'imageBuild', 'postCanary', 'dependencies', 'artifact'), 'canary receipt')
    object_keys(receipt['imageBuild'], ('conclusion', 'imageDigest', 'diskBytesConsumed'), 'image build')
    object_keys(receipt['postCanary'], ('freeBytes', 'freeInodePercent', 'observedAt'), 'post-canary observation')
    object_keys(receipt['artifact'], ('name', 'contentDigest'), 'receipt artifact')
    dependencies = receipt['dependencies']
    object_keys(dependencies, ('uploadArtifactCommit', 'postgresImage', 'nginxImage', 'curlImage', 'buildBaseImage'), 'canary dependencies')
    require(isinstance(dependencies['uploadArtifactCommit'], str) and SHA.fullmatch(dependencies['uploadArtifactCommit']), 'artifact uploader must be immutable')
    for name in ('postgresImage', 'nginxImage', 'curlImage', 'buildBaseImage'):
        require(isinstance(dependencies[name], str) and re.fullmatch(r'[a-z0-9/._-]+@sha256:[a-f0-9]{64}', dependencies[name]), 'canary image dependency must be immutable')
    require(type(receipt.get('schemaVersion')) is int and receipt['schemaVersion'] == 2 and receipt.get('contract') == 'verjson-runner-promotion/2', 'unsupported canary receipt')
    require(receipt.get('transactionNonce') == probe['transactionNonce'], 'receipt nonce differs')
    require(canonical(receipt.get('runner')) == canonical({'id': probe['runnerId'], 'name': probe['runnerName']}), 'receipt runner differs')
    require(receipt.get('release') == {'manifest': release['manifestDigest'], 'variant': release['variant'], 'imageDigest': release['imageDigest']}, 'receipt release differs')
    canary = receipt.get('canary', {})
    expected = {'repository': CANARY_REPOSITORY, 'workflow': 'canonical-db-backed-runner-canary',
                'runId': run_record['id'], 'jobId': job['id'], 'runAttempt': run_record['run_attempt'],
                'event': 'workflow_dispatch', 'headBranch': probe['workflowRef'].removeprefix('refs/tags/'),
                'headSha': probe['workflowCommit'], 'workflowPath': CANARY_PATH, 'workflowSha': probe['workflowCommit'],
                'conclusion': 'success', 'databaseServiceReachable': True, 'dockerServiceReachable': True, 'pwshExecuted': True,
                'runUrl': f"https://github.com/{CANARY_REPOSITORY}/actions/runs/{run_record['id']}",
                'jobUrl': f"https://github.com/{CANARY_REPOSITORY}/actions/runs/{run_record['id']}/job/{job['id']}"}
    require(canonical(canary) == canonical(expected), 'receipt workflow/job or representative checks differ')
    require(positive(job.get('runner_id')) and job['runner_id'] == probe['runnerId'] and job.get('runner_name') == probe['runnerName']
            and probe['runnerLabel'] in job.get('labels', []) and job.get('status') == 'completed'
            and job.get('conclusion') == 'success', 'independent job routing/outcome differs')
    observed = receipt.get('postCanary', {})
    require(timestamp(value['issuedAt']) <= timestamp(observed.get('observedAt')) <= now
            and now - timestamp(observed['observedAt']) <= 1800, 'canary evidence is stale')
    require(type(observed.get('freeBytes')) is int and observed['freeBytes'] >= 10_737_418_240
            and type(observed.get('freeInodePercent')) is int and 10 <= observed['freeInodePercent'] <= 100,
            'canary capacity evidence is below policy floor')
    require(receipt.get('imageBuild', {}).get('conclusion') == 'success'
            and receipt['imageBuild'].get('imageDigest') == release['imageDigest']
            and type(receipt['imageBuild']['diskBytesConsumed']) is int and receipt['imageBuild']['diskBytesConsumed'] == 0,
            'representative image build differs')
    self_digest = receipt.get('artifact', {}).get('contentDigest')
    unsigned = dict(receipt) | {'artifact': {'name': 'runner-promotion-receipt', 'contentDigest': ''}}
    require(receipt.get('artifact', {}).get('name') == 'runner-promotion-receipt' and digest(canonical(unsigned)) == self_digest, 'receipt content digest differs')
    require(artifact.get('expired') is False and positive(artifact.get('workflow_run', {}).get('id')) and artifact['workflow_run']['id'] == run_record['id'], 'artifact run provenance differs')


def probe_runner(api, value, token, *, record_intent, clock=time.time, sleep=time.sleep):
    validate_request(value, clock())
    probe = value['probe']
    repo = f'/repos/{CANARY_REPOSITORY}'
    workflow = api.call('GET', f"{repo}/actions/workflows/{probe['workflowId']}", token)
    require(positive(workflow.get('id')) and workflow['id'] == probe['workflowId'] and workflow.get('path') == CANARY_PATH and workflow.get('state') == 'active', 'dispatch workflow identity differs')
    ref = probe['workflowRef'].removeprefix('refs/')
    tag = api.call('GET', f'{repo}/git/ref/{ref}', token)
    target = tag.get('object', {})
    if target.get('type') == 'tag':
        require(isinstance(target.get('sha'), str) and SHA.fullmatch(target['sha']), 'annotated tag identity is invalid')
        annotated = api.call('GET', f"{repo}/git/tags/{target.get('sha')}", token)
        target = annotated.get('object', {})
    require(target == {'type': 'commit', 'sha': probe['workflowCommit'], 'url': f"https://api.github.com/repos/{CANARY_REPOSITORY}/git/commits/{probe['workflowCommit']}"}, 'canary tag does not resolve to reviewed commit')
    runs_path = f"{repo}/actions/workflows/{probe['workflowId']}/runs?event=workflow_dispatch&per_page=100"
    prior = api.call('GET', runs_path, token)
    require(isinstance(prior.get('workflow_runs'), list), 'run baseline is unavailable')
    title = 'runner-canary-' + probe['transactionNonce']
    require(not any(run.get('display_title') == title for run in prior['workflow_runs']), 'transaction nonce was already dispatched; reconcile before retry')
    ids = [run.get('id') for run in prior['workflow_runs']]
    require(all(positive(run_id) for run_id in ids), 'run baseline has invalid identity')
    maximum = max(ids, default=0)
    inputs = {'runner_name': probe['runnerName'], 'runner_id': str(probe['runnerId']), 'runner_label': probe['runnerLabel'],
              'transaction_nonce': probe['transactionNonce'], 'release_manifest': value['release']['manifestDigest'],
              'release_variant': value['release']['variant'], 'image_digest': value['release']['imageDigest']}
    validate_request(value, clock())
    record_intent({'requestDigest': digest(canonical(value)), 'transactionNonce': probe['transactionNonce'],
                   'preDispatchMaxRunId': maximum, 'workflowCommit': probe['workflowCommit']})
    # Never retry an ambiguous dispatch: the caller must inspect its nonce/run inventory.
    api.call('POST', f"{repo}/actions/workflows/{probe['workflowId']}/dispatches", token,
             {'ref': probe['workflowRef'].removeprefix('refs/tags/'), 'inputs': inputs})
    found = None
    while clock() < timestamp(value['expiresAt']):
        page = api.call('GET', runs_path, token)
        require(isinstance(page.get('workflow_runs'), list), 'run inventory is unavailable')
        matching = [run for run in page['workflow_runs'] if run.get('display_title') == title]
        require(len(matching) <= 1, 'ambiguous transaction nonce runs')
        if matching:
            found = matching[0]
            require(positive(found.get('id')) and found['id'] > maximum and positive(found.get('workflow_id')) and found['workflow_id'] == probe['workflowId']
                    and found.get('event') == 'workflow_dispatch' and found.get('head_sha') == probe['workflowCommit']
                    and found.get('head_branch') == probe['workflowRef'].removeprefix('refs/tags/')
                    and found.get('path') == CANARY_PATH and type(found.get('run_attempt')) is int and found['run_attempt'] == 1
                    and timestamp(value['issuedAt']) <= timestamp(found.get('created_at')) <= clock(), 'run identity is stale or differs')
            if found.get('status') == 'completed':
                require(found.get('conclusion') == 'success', 'representative run failed')
                break
        sleep(min(5, max(0, timestamp(value['expiresAt']) - clock())))
    require(found is not None and found.get('status') == 'completed', 'representative run timed out')
    jobs = api.call('GET', f"{repo}/actions/runs/{found['id']}/attempts/1/jobs?per_page=100", token)
    require(type(jobs.get('total_count')) is int and jobs['total_count'] == 1 and len(jobs.get('jobs', [])) == 1 and jobs['jobs'][0].get('name') == 'canary', 'canary job identity is ambiguous')
    job = jobs['jobs'][0]
    require(positive(job.get('id')), 'canary job ID is invalid')
    artifacts = api.call('GET', f"{repo}/actions/runs/{found['id']}/artifacts?per_page=100", token)
    require(type(artifacts.get('total_count')) is int and artifacts['total_count'] == 1 and len(artifacts.get('artifacts', [])) == 1, 'canary artifact identity is ambiguous')
    artifact = artifacts['artifacts'][0]
    require(positive(artifact.get('id')) and artifact.get('name') == 'runner-promotion-receipt', 'canary artifact differs')
    archive = api.call('GET', f"{repo}/actions/artifacts/{artifact['id']}/zip", token, binary=True)
    require(digest(archive) == artifact.get('digest'), 'artifact archive digest differs')
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            members = bundle.infolist()
            require(len(members) == 1 and members[0].filename == 'runner-promotion-receipt.json'
                    and 0 < members[0].file_size <= MAX_BYTES and not members[0].is_dir(), 'artifact archive layout is invalid')
            receipt = decode(bundle.read(members[0]))
    except (zipfile.BadZipFile, RuntimeError):
        raise TransportError('canary artifact archive is invalid') from None
    validate_probe_receipt(value, receipt, found, job, artifact, clock())
    return {'schemaVersion': 1, 'requestDigest': digest(canonical(value)), 'routedRunner': probe['runnerName'],
            'outcome': 'passed', 'preDispatchMaxRunId': maximum, 'runId': found['id'], 'runAttempt': 1, 'artifactId': artifact['id'],
            'artifactDigest': artifact['digest'], 'receipt': receipt}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    value = validate_request(decode(args.request.read_bytes()), time.time())
    require(value['operation'] != 'host-export', 'CLI read-only host export unavailable: Verjson/verjson-cli-cloud#504')
    require(not args.dry_run or value['operation'] == 'manifest', 'dry-run has no dispatch authority')
    intent_path = args.output.with_name(args.output.name + '.dispatch-intent.json')
    require(not args.output.exists() and not intent_path.exists(), 'output or dispatch intent already exists; reconcile before retry')
    def record_intent(value):
        persist_record(intent_path, value)
    role = value['operation'].upper()
    jwt = os.environ.get(f'VERJSON_DEPLOYMENT_{role}_APP_JWT')
    api = GitHubHTTP()
    token = installation_token(api, value, jwt, time.time())
    result = fetch_manifest(api, value, token) if value['operation'] == 'manifest' else probe_runner(api, value, token, record_intent=record_intent)
    persist_record(args.output, result)


if __name__ == '__main__':
    try:
        main()
    except (TransportError, OSError, KeyError, TypeError) as failure:
        # Never relay HTTP bodies, JWTs, headers, signed asset URLs, or subprocess stderr.
        raise SystemExit(str(failure) if isinstance(failure, TransportError) else 'deployment transport failed') from None
