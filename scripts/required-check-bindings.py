#!/usr/bin/env python3
import argparse
from collections import Counter
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'config/required-check-bindings'
CONTEXTS = {20513599: ['changelog / validate'],
            20515817: ['ci / build-test', 'ci / eligibility', 'changelog-contract']}
PAYLOAD_KEYS = ('name', 'target', 'enforcement', 'bypass_actors', 'conditions', 'rules')
PROPERTY_KEYS = ('changelog-contract', 'verjson-stack', 'verjson-core-checks')
REPOSITORY = re.compile(r'Verjson/(?!\.{1,2}(?:/|$))[A-Za-z0-9._-]+')


class BindingError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BindingError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def decode(raw):
    require(len(raw) <= 2_097_152, 'JSON exceeds snapshot size limit')

    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result

    try:
        value = json.loads(raw, object_pairs_hook=unique)
        canonical(value)
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise BindingError('invalid finite JSON snapshot') from error


def read(name):
    return decode((DATA / name).read_bytes())


def digest(value):
    return 'sha256:' + hashlib.sha256(canonical(value).encode()).hexdigest()


def selected(properties, identity):
    if identity == 20513599:
        return properties.get('changelog-contract') == 'adopted'
    return properties.get('verjson-stack') == 'node' and properties.get('verjson-core-checks') == 'enforced'


def validate_evidence(evidence_dir, observation):
    for name in ('cohort.json', 'producer-checks.jsonl'):
        raw = (evidence_dir / name).read_bytes()
        require('sha256:' + hashlib.sha256(raw).hexdigest() == observation['evidenceDigests'][name],
                'private producer evidence digest differs')
    cohort = decode((evidence_dir / 'cohort.json').read_bytes())
    require(isinstance(cohort, list) and cohort, 'empty cohort')
    expected = set()
    names, ids = set(), set()
    for repo in cohort:
        require(isinstance(repo, dict) and isinstance(repo.get('repository'), str)
                and REPOSITORY.fullmatch(repo['repository']), 'invalid cohort repository')
        require(type(repo.get('repositoryId')) is int and repo['repositoryId'] > 0, 'invalid repository ID')
        require(repo['repository'] not in names and repo['repositoryId'] not in ids, 'duplicate cohort identity')
        names.add(repo['repository']); ids.add(repo['repositoryId'])
        require(isinstance(repo.get('properties'), dict), 'missing property selectors')
        required = [context for identity, contexts in CONTEXTS.items()
                    if selected(repo['properties'], identity) for context in contexts]
        require(required, 'unselected repository in cohort')
        expected.update((repo['repository'], context) for context in required)
    rows = [decode(line) for line in (evidence_dir / 'producer-checks.jsonl').read_bytes().splitlines()]
    found = set()
    for row in rows:
        key = (row.get('repository'), row.get('context'))
        require(key in expected and key not in found, 'unexpected or duplicate producer receipt')
        found.add(key)
        require(type(row.get('checkId')) is int and row['checkId'] > 0, 'invalid check ID')
        require(type(row.get('appId')) is int and row['appId'] == 15368
                and row.get('appSlug') == 'github-actions' and row.get('appOwner') == 'github', 'unverified producer App')
        require(isinstance(row.get('headSha'), str) and re.fullmatch(r'[0-9a-f]{40}', row['headSha'])
                and row.get('headSource', {}).get('sha') == row['headSha'], 'producer head mismatch')
        require(isinstance(row.get('detailsUrl'), str)
                and row['detailsUrl'].startswith(f"https://github.com/{row['repository']}/actions/runs/"), 'producer run URL differs')
    require(found == expected, 'producer coverage is incomplete')
    require(len(cohort) == observation['repositoryCount'] and len(rows) == observation['producerReceiptCount'],
            'private producer evidence counts differ')
    require(dict(Counter(row['context'] for row in rows)) == observation['contextCounts']
            and dict(Counter(row['conclusion'] for row in rows)) == observation['conclusionCounts']
            and min(row['completedAt'] for row in rows) == observation['oldestCompletedAt'],
            'producer aggregate outcomes or age differ')
    return cohort, rows


def prepare(evidence_dir=None):
    observation = read('observation.json')
    require(observation.get('liveActivationVerified') is False, 'snapshot must not claim live activation')
    if evidence_dir is not None:
        validate_evidence(evidence_dir, observation)
    plans = []
    for identity, contexts in CONTEXTS.items():
        before = read(f'{identity}-before.json')
        require(type(before.get('id')) is int and before['id'] == identity
                and before.get('source') == 'Verjson' and before.get('source_type') == 'Organization'
                and before.get('target') == 'branch' and before.get('enforcement') == 'active', 'baseline identity differs')
        require(len(before.get('rules', [])) == 1 and before['rules'][0].get('type') == 'required_status_checks', 'baseline rule shape differs')
        checks = before['rules'][0]['parameters']['required_status_checks']
        require(canonical(checks) == canonical([{'context': name} for name in contexts]), 'baseline contexts/bindings differ')
        rollback = {key: copy.deepcopy(before[key]) for key in PAYLOAD_KEYS}
        after = copy.deepcopy(rollback)
        for check in after['rules'][0]['parameters']['required_status_checks']:
            check['integration_id'] = 15368
        require(canonical(read(f'{identity}-after.json')) == canonical(after), 'candidate changes more than App bindings')
        require(canonical(read(f'{identity}-rollback.json')) == canonical(rollback), 'rollback does not restore the original payload')
        plans.append({'rulesetId': identity, 'beforeDigest': digest(before), 'afterDigest': digest(after),
                      'rollbackDigest': digest(rollback), 'after': after, 'rollback': rollback})
    return {'schemaVersion': 1, 'preparationOnly': True, 'liveActivationVerified': False,
            'observation': observation, 'producerEvidenceValidated': evidence_dir is not None, 'plans': plans}


def gh_get(path, paginate=False):
    require(path in ('orgs/Verjson/properties/values?per_page=100',
                    *[f'orgs/Verjson/rulesets/{identity}' for identity in CONTEXTS])
            or re.fullmatch(rf'repos/{REPOSITORY.pattern}/check-runs/[1-9][0-9]*', path), 'unsupported read path')
    arguments = ['gh', 'api', '--hostname', 'github.com', '--method', 'GET', path]
    if paginate:
        arguments += ['--paginate', '--slurp']
    try:
        result = subprocess.run(arguments, check=True, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise BindingError('authenticated preparation read failed') from error
    return decode(result.stdout)


def dry_run(evidence_dir):
    result = prepare(evidence_dir)
    cohort, rows = validate_evidence(evidence_dir, result['observation'])
    for identity in CONTEXTS:
        require(canonical(gh_get(f'orgs/Verjson/rulesets/{identity}')) == canonical(read(f'{identity}-before.json')),
                'live ruleset preimage changed; refresh and review')
    actual = []
    for page in gh_get('orgs/Verjson/properties/values?per_page=100', paginate=True):
        for repo in page:
            properties = {item['property_name']: item['value'] for item in repo['properties']}
            if any(selected(properties, identity) for identity in CONTEXTS):
                actual.append({'repository': repo['repository_full_name'], 'repositoryId': repo['repository_id'],
                               'properties': {key: properties.get(key) for key in PROPERTY_KEYS}})
    expected = [{key: value for key, value in repo.items() if key != 'defaultBranch'} for repo in cohort]
    require(canonical(sorted(actual, key=lambda r: r['repository'])) == canonical(sorted(expected, key=lambda r: r['repository'])),
            'selected repository cohort changed; refresh producer evidence')
    for row in rows:
        live = gh_get(f"repos/{row['repository']}/check-runs/{row['checkId']}")
        observed = {'checkId': live.get('id'), 'context': live.get('name'), 'headSha': live.get('head_sha'),
                    'appId': live.get('app', {}).get('id'), 'appSlug': live.get('app', {}).get('slug'),
                    'appOwner': live.get('app', {}).get('owner', {}).get('login'),
                    'conclusion': live.get('conclusion'), 'completedAt': live.get('completed_at'), 'detailsUrl': live.get('details_url')}
        require(canonical(observed) == canonical({key: row.get(key) for key in observed}), 'producer receipt changed or cannot be verified')
    result['authenticatedSnapshotsRechecked'] = True
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description='Prepare two exact organization App-binding repairs; no mutation mode.')
    parser.add_argument('mode', choices=('render', 'dry-run'))
    parser.add_argument('--evidence-dir', type=Path, help='private local producer receipts matching the public digests')
    args = parser.parse_args(arguments)
    if args.mode == 'dry-run' and args.evidence_dir is None:
        parser.error('dry-run requires --evidence-dir; producer coverage cannot be inferred')
    try:
        print(json.dumps(dry_run(args.evidence_dir) if args.mode == 'dry-run' else prepare(args.evidence_dir), indent=2, sort_keys=True))
    except (BindingError, OSError, KeyError, TypeError) as error:
        print(f'check-binding preparation: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
