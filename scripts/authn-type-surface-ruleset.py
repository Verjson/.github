#!/usr/bin/env python3
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "config/authn-type-surface-ruleset.json"
WORKFLOW = ROOT / ".github/workflows/authn-type-surface-required.yml"
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


class ContractError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def load_json(text, source):
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, f"{source} contains duplicate key {key}")
            value[key] = item
        return value

    try:
        return json.loads(text, object_pairs_hook=unique_object)
    except json.JSONDecodeError as error:
        raise ContractError(f"{source} is invalid JSON: {error}") from None


def read_contract(path=CONTRACT):
    contract = load_json(path.read_text(encoding="utf-8"), str(path))
    require(set(contract) == {
        "schema_version", "organization", "consumer", "canonical_workflow",
        "ruleset", "rollout",
    }, "contract top-level keys drifted")
    require(contract["schema_version"] == 1, "contract schema_version must be 1")
    require(contract["organization"] == "Verjson", "contract organization drifted")
    require(contract["consumer"] == {
        "repository": "Verjson/verjson-authn",
        "repository_id": 1302124584,
        "retired_repository_ruleset": {
            "id": 21522093,
            "name": "authn-type-surface-required",
            "target": "branch",
            "enforcement": "active",
            "bypass_actors": [],
            "conditions": {
                "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []},
            },
            "rules": [{
                "type": "required_status_checks",
                "parameters": {
                    "do_not_enforce_on_create": True,
                    "required_status_checks": [{
                        "context": "type-surface-contract",
                        "integration_id": 15368,
                    }],
                    "strict_required_status_checks_policy": False,
                },
            }],
        },
    }, "consumer identity drifted")
    require(contract["canonical_workflow"] == {
        "repository": "Verjson/.github",
        "repository_id": 1269388380,
        "path": ".github/workflows/authn-type-surface-required.yml",
        "ref": "refs/heads/main",
    }, "canonical workflow identity drifted")
    ruleset = contract["ruleset"]
    require(ruleset == {
        "name": "authn-type-surface-required-workflow",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []},
            "repository_id": {"repository_ids": [1302124584]},
        },
    }, "ruleset base image drifted")
    rollout = contract["rollout"]
    require(set(rollout) == {
        "issue", "human_gate_required", "apply_acknowledgement", "required_run",
    }, "rollout keys drifted")
    require(rollout["issue"] == 1154, "rollout issue drifted")
    require(rollout["human_gate_required"] is True, "rollout must retain its human gate")
    require(rollout["apply_acknowledgement"] == "APPLY-AUTHN-TYPE-SURFACE-1154",
            "apply acknowledgement drifted")
    require(rollout["required_run"] == {
        "event": "pull_request",
        "conclusion": "success",
        "path": ".github/workflows/authn-type-surface-required.yml",
        "workflow_url_prefix": (
            "https://api.github.com/repos/Verjson/verjson-authn/"
            "actions/required_workflows/"
        ),
    }, "required run receipt contract drifted")
    return contract


def validate_workflow(path=WORKFLOW):
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    require(document.get(True) == {"pull_request": None},
            "required workflow must trigger only on pull_request")
    require(document.get("permissions") == {
        "contents": "read", "packages": "read", "statuses": "read",
    }, "required workflow permissions drifted")
    require(set(document.get("jobs", {})) == {"type-surface"},
            "required workflow must expose exactly one canonical job")
    job = document["jobs"]["type-surface"]
    require(job.get("if") == "github.repository == 'Verjson/verjson-authn'",
            "required workflow repository guard drifted")
    require(job.get("uses") == (
        "Verjson/.github/.github/workflows/node-ci.yml@"
        "c973a841694a41bf0b9bcd70432f64850cba0850"
    ), "required workflow must call immutable protected canonical node-ci")
    require(job.get("permissions") == document["permissions"],
            "required workflow job permissions drifted")
    require(job.get("secrets") == {"NODE_AUTH_TOKEN": "${{ secrets.GITHUB_TOKEN }}"},
            "required workflow must pass only its scoped GitHub token")
    inputs = job.get("with", {})
    require(inputs.get("secretless-pr") is True,
            "required workflow must use the secretless PR boundary")
    require(inputs.get("approved-internal-packages") ==
            "@verjson/authn\n@verjson/identity-contracts\n@verjson/tsconfig",
            "approved package set drifted")
    require(inputs.get("secretless-ci-script-plan") == '["build"]',
            "PR-authored execution plan drifted")
    require(json.loads(inputs.get("secretless-compatibility-ranges", "")) == {
        "package": "@verjson/authn",
        "ranges": ["1.0.3"],
        "script": "test:type-surface-compatibility",
    }, "type-surface compatibility request drifted")
    require(json.loads(inputs.get("secretless-auxiliary-source", "")) == {
        "repository": "Verjson/verjson-authn",
        "pinFile": ".github/ci/type-surface-base.json",
        "checkoutPath": ".authn-type-base",
        "sparsePath": "NEXT",
    }, "type-surface baseline request drifted")


def render_payload(contract, workflow_sha):
    require(SHA_PATTERN.fullmatch(workflow_sha) is not None,
            "workflow SHA must be 40 lowercase hexadecimal characters")
    workflow = contract["canonical_workflow"]
    payload = dict(contract["ruleset"])
    payload["rules"] = [{
        "type": "workflows",
        "parameters": {
            "do_not_enforce_on_create": False,
            "workflows": [{
                "path": workflow["path"],
                "repository_id": workflow["repository_id"],
                "ref": workflow["ref"],
                "sha": workflow_sha,
            }],
        },
    }]
    return payload


def mutable_ruleset(value):
    required = {
        "name", "target", "enforcement", "bypass_actors", "conditions", "rules",
    }
    require(isinstance(value, dict) and required <= set(value),
            "live ruleset is missing required fields")
    return {key: value[key] for key in (
        "name", "target", "enforcement", "bypass_actors", "conditions", "rules",
    )}


def validate_live_ruleset(value, expected):
    require(value.get("source_type") == "Organization", "ruleset source is not Organization")
    require(value.get("source") == "Verjson", "ruleset source organization drifted")
    require(mutable_ruleset(value) == expected, "live ruleset differs from the reviewed image")


def validate_retired_ruleset(value, expected):
    require(value.get("source_type") == "Repository",
            "repository ruleset source type drifted")
    require(value.get("source") == "Verjson/verjson-authn",
            "repository ruleset source drifted")
    require(isinstance(value.get("id"), int) and value["id"] == expected["id"],
            "repository ruleset identity drifted")
    require(mutable_ruleset(value) == {
        key: expected[key] for key in (
            "name", "target", "enforcement", "bypass_actors", "conditions", "rules",
        )
    }, "repository ruleset preimage drifted")


def parse_timestamp(value, location):
    require(isinstance(value, str) and value.endswith("Z"), f"{location} is invalid")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise ContractError(f"{location} is invalid") from None


def validate_required_run(
        run, contract, workflow_sha, head_sha, *, minimum_run_id, not_before):
    required = contract["rollout"]["required_run"]
    require(SHA_PATTERN.fullmatch(head_sha) is not None, "head SHA is invalid")
    require(run.get("event") == required["event"], "run event is not pull_request")
    require(run.get("status") == "completed", "required workflow run is not completed")
    require(run.get("conclusion") == required["conclusion"],
            "required workflow run is not successful")
    require(run.get("head_sha") == head_sha, "required workflow run is stale")
    require(isinstance(run.get("id"), int) and run["id"] > minimum_run_id,
            "required workflow run predates the trigger snapshot")
    require(parse_timestamp(run.get("created_at"), "run created_at") >= not_before,
            "required workflow run predates ruleset activation")
    require(run.get("path") == required["path"],
            "run path is not the protected required workflow")
    workflow_url = run.get("workflow_url", "")
    require(workflow_url.startswith(required["workflow_url_prefix"]),
            "run was not created by an organization required-workflow rule")
    suffix = workflow_url.removeprefix(required["workflow_url_prefix"])
    require(suffix.isdigit() and int(suffix) > 0, "required workflow URL id is invalid")
    require(run.get("workflow_sha") in (None, workflow_sha),
            "reported workflow SHA disagrees with the rule binding")


def gh_json(*arguments):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise ContractError(f"GitHub API request failed: {' '.join(arguments)}")
    return load_json(result.stdout, f"GitHub API response for {' '.join(arguments)}")


def gh_json_input(method, path, payload):
    with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
        json.dump(payload, stream)
        stream.flush()
        return gh_json("--method", method, path, "--input", stream.name)


def list_named_rulesets(contract):
    listing = gh_json("--paginate", "--slurp", "orgs/Verjson/rulesets?per_page=100")
    require(isinstance(listing, list) and listing, "organization ruleset listing is empty")
    entries = [entry for page in listing for entry in page]
    return [entry for entry in entries if entry.get("name") == contract["ruleset"]["name"]]


def verify_canonical_bytes(contract, workflow_sha):
    comparison = gh_json(
        f"repos/Verjson/.github/compare/{workflow_sha}...main"
    )
    require(comparison.get("status") in {"ahead", "identical"},
            "workflow SHA is not reachable from protected main")
    for path in (contract["canonical_workflow"]["path"],
                 "config/authn-type-surface-ruleset.json",
                 "scripts/authn-type-surface-ruleset.py"):
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com",
             f"repos/Verjson/.github/contents/{path}?ref={workflow_sha}",
             "-H", "Accept: application/vnd.github.raw+json"],
            capture_output=True,
            check=False,
        )
        require(result.returncode == 0, f"canonical file is unreadable at workflow SHA: {path}")
        require(result.stdout == (ROOT / path).read_bytes(),
                f"local file is not the merged canonical byte sequence: {path}")


def discover_state(contract, workflow_sha):
    verify_canonical_bytes(contract, workflow_sha)
    consumer = gh_json("repos/Verjson/verjson-authn")
    require(consumer.get("id") == contract["consumer"]["repository_id"],
            "consumer repository identity drifted")
    retired_expected = contract["consumer"]["retired_repository_ruleset"]
    retired = gh_json(
        f"repos/Verjson/verjson-authn/rulesets/{retired_expected['id']}"
    )
    validate_retired_ruleset(retired, retired_expected)
    named = list_named_rulesets(contract)
    require(len(named) <= 1, "multiple organization rulesets use the canonical name")
    return named


def parse_arguments(arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode", choices=("render", "dry-run", "apply", "snapshot", "verify-run")
    )
    parser.add_argument("--workflow-sha", required=True)
    parser.add_argument("--ack", default="")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--head-sha")
    parser.add_argument("--pre-trigger-max-run-id", type=int)
    return parser.parse_args(arguments)


def restore_disabled_after_activation_failure(ruleset_id, staged):
    try:
        gh_json_input("PUT", f"orgs/Verjson/rulesets/{ruleset_id}", staged)
    except (ContractError, OSError):
        raise ContractError(
            "active verification failed; disable rollback mutation failed"
        ) from None
    try:
        restored = gh_json(f"orgs/Verjson/rulesets/{ruleset_id}")
        validate_live_ruleset(restored, staged)
    except (ContractError, OSError):
        raise ContractError(
            "active verification failed; disable rollback could not be verified"
        ) from None
    raise ContractError(
        "active verification failed; ruleset restored and verified disabled"
    )


def main(arguments=None):
    args = parse_arguments(arguments or sys.argv[1:])
    contract = read_contract()
    validate_workflow()
    expected = render_payload(contract, args.workflow_sha)
    if args.mode == "render":
        print(json.dumps(expected, sort_keys=True, indent=2))
        return 0
    named = discover_state(contract, args.workflow_sha)
    live = None
    if named:
        live = gh_json(f"orgs/Verjson/rulesets/{named[0]['id']}")
        validate_live_ruleset(live, expected)
    if args.mode == "dry-run":
        print("ready: merged canonical bytes and live preconditions match")
        return 0
    if args.mode == "snapshot":
        require(live is not None, "canonical organization ruleset is not active")
        runs = gh_json(
            "repos/Verjson/verjson-authn/actions/runs?event=pull_request&per_page=100"
        )
        require(isinstance(runs.get("workflow_runs"), list),
                "pre-trigger run inventory is invalid")
        required = contract["rollout"]["required_run"]
        matching_ids = [
            run.get("id") for run in runs["workflow_runs"]
            if run.get("path") == required["path"]
            and str(run.get("workflow_url", "")).startswith(
                required["workflow_url_prefix"]
            )
        ]
        require(all(isinstance(run_id, int) and run_id > 0 for run_id in matching_ids),
                "pre-trigger run inventory contains an invalid id")
        print(json.dumps({
            "ruleset_id": live["id"],
            "ruleset_updated_at": live["updated_at"],
            "pre_trigger_max_run_id": max(matching_ids, default=0),
        }, sort_keys=True))
        return 0
    if args.mode == "verify-run":
        require(live is not None, "canonical organization ruleset is not active")
        require(args.run_id is not None and args.run_id > 0, "--run-id is required")
        require(args.head_sha is not None, "--head-sha is required")
        require(args.pre_trigger_max_run_id is not None
                and args.pre_trigger_max_run_id >= 0,
                "--pre-trigger-max-run-id is required")
        run = gh_json(f"repos/Verjson/verjson-authn/actions/runs/{args.run_id}")
        validate_required_run(
            run,
            contract,
            args.workflow_sha,
            args.head_sha,
            minimum_run_id=args.pre_trigger_max_run_id,
            not_before=parse_timestamp(
                live.get("updated_at"), "ruleset updated_at"
            ),
        )
        print("verified: fresh exact-head organization required-workflow run")
        return 0
    require(not named, "canonical organization ruleset already exists")
    require(args.ack == contract["rollout"]["apply_acknowledgement"],
            "explicit apply acknowledgement is required")
    require(not discover_state(contract, args.workflow_sha),
            "canonical organization ruleset appeared during apply preflight")
    staged = dict(expected)
    staged["enforcement"] = "disabled"
    created = gh_json_input("POST", "orgs/Verjson/rulesets", staged)
    ruleset_id = created.get("id")
    require(isinstance(ruleset_id, int) and ruleset_id > 0,
            "created ruleset returned no positive id")
    staged_live = gh_json(f"orgs/Verjson/rulesets/{ruleset_id}")
    validate_live_ruleset(staged_live, staged)
    gh_json_input("PUT", f"orgs/Verjson/rulesets/{ruleset_id}", expected)
    try:
        live = gh_json(f"orgs/Verjson/rulesets/{ruleset_id}")
        validate_live_ruleset(live, expected)
    except (ContractError, OSError):
        restore_disabled_after_activation_failure(ruleset_id, staged)
    print(f"created disabled, activated, and verified organization ruleset {ruleset_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
