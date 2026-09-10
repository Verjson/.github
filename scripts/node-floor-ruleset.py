#!/usr/bin/env python3
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'config/node-floor-baseline.json'
BASELINE_PATH = 'orgs/Verjson/rulesets/20515817'
PROPERTY_PATH = 'orgs/Verjson/properties/schema'
PROPERTY_NAME = 'verjson-node-floor'
PROPERTY = {
    'value_type': 'single_select',
    'required': True,
    'default_value': 'disabled',
    'allowed_values': ['disabled', 'node22'],
    'values_editable_by': 'org_actors',
    'require_explicit_values': False,
    'description': 'Opt in to the canonical ci-node22 required checks; disabled does not select the lane.',
}
CONTEXTS = ['ci-node22 / build-test', 'ci-node22 / eligibility']
MAX_BYTES = 1_048_576


class PreparationError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def decode(raw):
    if len(raw) > MAX_BYTES:
        raise PreparationError('JSON input exceeds the preparation size limit')

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise PreparationError('JSON contains a duplicate key')
            result[key] = value
        return result

    try:
        value = json.loads(raw, object_pairs_hook=pairs)
        canonical(value)
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise PreparationError('invalid finite JSON input') from error


def render(baseline, source):
    expected = decode(BASELINE.read_bytes())
    if not isinstance(baseline, dict) or canonical({key: baseline.get(key) for key in expected}) != canonical(expected):
        raise PreparationError('Node baseline identity, selectors, rules or bypass actors drifted; review before preparing')
    candidate = {key: copy.deepcopy(baseline[key]) for key in
                 ('name', 'target', 'enforcement', 'bypass_actors', 'conditions', 'rules')}
    candidate['name'] = 'core-checks-node-floor'
    candidate['enforcement'] = 'disabled'
    candidate['conditions']['repository_property']['include'].append({
        'name': PROPERTY_NAME, 'property_values': ['node22'], 'source': 'custom'})
    candidate['rules'][0]['parameters']['required_status_checks'] = [
        {'context': context, 'integration_id': 15368} for context in CONTEXTS]
    return {
        'schemaVersion': 1,
        'preparationOnly': True,
        'liveAcceptanceVerified': False,
        'baselineSource': source,
        'baselineId': expected['id'],
        'baselineDigest': 'sha256:' + hashlib.sha256(canonical(baseline).encode()).hexdigest(),
        'property': {'name': PROPERTY_NAME, 'definition': copy.deepcopy(PROPERTY)},
        'ruleset': candidate,
    }


def read_github(path):
    if path not in (BASELINE_PATH, PROPERTY_PATH):
        raise PreparationError('unsupported preparation read')
    try:
        result = subprocess.run(['gh', 'api', '--hostname', 'github.com', '--method', 'GET', path],
                                check=True, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise PreparationError('GitHub preparation read failed') from error
    return decode(result.stdout)


def dry_run():
    baseline = read_github(BASELINE_PATH)
    result = render(baseline, 'authenticated-read')
    properties = read_github(PROPERTY_PATH)
    if not isinstance(properties, list) or any(not isinstance(item, dict) for item in properties):
        raise PreparationError('invalid organization property schema')
    matches = [item for item in properties if item.get('property_name') == PROPERTY_NAME]
    if len(matches) > 1:
        raise PreparationError('ambiguous Node-floor property')
    if matches:
        existing = matches[0]
        if existing.get('source_type') != 'organization' or canonical({key: existing.get(key) for key in PROPERTY}) != canonical(PROPERTY):
            raise PreparationError('existing Node-floor property conflicts with the reviewed definition')
    result['propertyState'] = 'compatible' if matches else 'absent'
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description='Prepare the opt-in Node22 lane; never writes GitHub state.')
    parser.add_argument('mode', choices=('render', 'dry-run'))
    parser.add_argument('--baseline', type=Path, help='saved baseline JSON for offline rendering')
    args = parser.parse_args(arguments)
    if args.mode == 'dry-run' and args.baseline is not None:
        parser.error('--baseline is only valid with render')
    try:
        if args.mode == 'dry-run':
            result = dry_run()
        else:
            result = render(decode((args.baseline or BASELINE).read_bytes()),
                            'saved-snapshot' if args.baseline else 'reviewed-policy')
        print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
    except (PreparationError, OSError) as error:
        print(f'node-floor preparation: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
