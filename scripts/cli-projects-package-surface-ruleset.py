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
CONTRACT = ROOT / "config/cli-projects-package-surface-ruleset.json"
WORKFLOW = ROOT / ".github/workflows/cli-projects-package-surface-required.yml"
VERIFIER = ROOT / "scripts/cli-projects-package-surface.py"
GENERATOR = ROOT / "scripts/gen-node-required-workflow.py"
GENERATOR_CONFIG = ROOT / "config/cli-projects-required-node-ci.json"
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
MUTABLE_FIELDS = (
    "name", "target", "enforcement", "bypass_actors", "conditions", "rules",
)


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
        "repository": "Verjson/verjson-cli-projects",
        "repository_id": 1277452690,
        "workflow": {
            "path": ".github/workflows/ci.yml",
            "ref": "refs/heads/main",
        },
        "repository_ruleset": {
            "id": 21567958,
            "name": "cli-projects-v1-required",
            "target": "branch",
            "enforcement": "evaluate",
            "bypass_actors": [],
            "conditions": {
                "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []},
            },
            "rules": [{
                "type": "required_status_checks",
                "parameters": {
                    "do_not_enforce_on_create": True,
                    "required_status_checks": [{
                        "context": "package-surface-contract",
                        "integration_id": 15368,
                    }],
                    "strict_required_status_checks_policy": False,
                },
            }],
        },
    }, "consumer ruleset preimage drifted")
    require(contract["canonical_workflow"] == {
        "repository": "Verjson/.github",
        "repository_id": 1269388380,
        "path": ".github/workflows/cli-projects-package-surface-required.yml",
        "ref": "refs/heads/main",
    }, "canonical workflow identity drifted")
    require(contract["ruleset"] == {
        "name": "cli-projects-package-surface-required-workflow",
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []},
            "repository_id": {"repository_ids": [1277452690]},
        },
    }, "organization ruleset image drifted")
    rollout = contract["rollout"]
    require(set(rollout) == {
        "issue", "human_gate_required", "apply_acknowledgement", "previous_workflow_sha",
        "required_run",
    }, "rollout keys drifted")
    require(rollout["issue"] == 1187, "rollout issue drifted")
    require(rollout["human_gate_required"] is True, "rollout human gate removed")
    require(rollout["apply_acknowledgement"] ==
            "ROTATE-CLI-PROJECTS-REQUIRED-WORKFLOW-1187",
            "rollout acknowledgement drifted")
    require(rollout["previous_workflow_sha"] ==
            "483afa0995f0df51cb9dfa001ded1b48c73ae8f5",
            "previous workflow identity drifted")
    require(rollout["required_run"] == {
        "event": "pull_request",
        "conclusion": "success",
        "path": ".github/workflows/cli-projects-package-surface-required.yml",
        "workflow_url_prefix": (
            "https://api.github.com/repos/Verjson/verjson-cli-projects/"
            "actions/required_workflows/"
        ),
    }, "required run receipt contract drifted")
    return contract


def validate_workflow(path=WORKFLOW):
    generated = subprocess.run(
        [sys.executable, str(GENERATOR), "config/cli-projects-required-node-ci.json"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )
    require(generated.returncode == 0, "required workflow generator failed")
    require(path.read_text(encoding="utf-8") == generated.stdout,
            "required workflow differs from canonical generator output")
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    require(document.get(True) == {"pull_request": None},
            "required workflow must trigger only on pull_request")
    require(document.get("permissions") == {"contents": "read"},
            "required workflow permissions drifted")
    require(set(document.get("jobs", {})) == {
        "admission", "ci", "ci-node-floor", "package-surface",
    }, "required workflow jobs drifted")
    admission = document["jobs"]["admission"]
    require(admission.get("if") == "github.repository == 'Verjson/verjson-cli-projects'",
            "required workflow repository guard drifted")
    require(admission.get("runs-on") == "ubuntu-24.04",
            "identity admission must use an ephemeral hosted runner")
    require(
        admission.get("permissions")
        == {"contents": "read", "pull-requests": "read"},
            "identity admission permissions drifted")
    require(len(admission.get("steps", [])) == 1,
            "identity admission step count drifted")
    admission_step = admission["steps"][0]
    require(set(admission_step.get("env", {})) == {
        "EVENT_NAME", "HEAD_REPOSITORY", "HEAD_SHA", "MERGE_SHA", "PR_NUMBER",
        "REF", "REPOSITORY", "CONSUMER_WORKFLOW_SHA256", "GH_TOKEN",
    }, "identity admission inputs drifted")
    admission_run = admission_step.get("run", "")
    for assertion in (
        'EVENT_NAME" = pull_request', 'HEAD_REPOSITORY" = \'Verjson/verjson-cli-projects\'',
        'REF" = "refs/pull/$PR_NUMBER/merge"', "merge_commit_sha", 'live_head" = "$HEAD_SHA',
        'live_merge" = "$MERGE_SHA',
        "contents/.github/workflows/ci.yml?ref=$HEAD_SHA",
        '"$CONSUMER_WORKFLOW_SHA256"',
    ):
        require(assertion in admission_run, f"identity admission omits {assertion}")
    for name, version in (("ci", "26"), ("ci-node-floor", "24.19.0")):
        job = document["jobs"][name]
        require(job.get("needs") == "admission", f"{name} bypasses identity admission")
        require(job.get("permissions") == {
            "contents": "read", "packages": "read", "statuses": "read",
        }, f"{name} permissions drifted")
        require(job.get("uses") == (
            "Verjson/.github/.github/workflows/node-ci.yml@"
            "d91d6a73128323bf9f1aec72b565d8aac8805aaa"
        ), f"{name} reusable workflow identity drifted")
        require(job.get("secrets") == {
            "NODE_AUTH_TOKEN": "${{ secrets.GITHUB_TOKEN }}",
        }, f"{name} credential mapping drifted")
        require(job.get("with", {}).get("node-version") == version,
                f"{name} Node version drifted")
        require(job.get("with", {}).get("secretless-pr") is True,
                f"{name} secretless boundary disabled")
        require(job.get("with", {}).get("approved-internal-packages") ==
                "@verjson/eslint-config\n@verjson/tsconfig",
                f"{name} package acquisition allowlist drifted")
        require("steps" not in job and "runs-on" not in job,
                f"{name} may execute only protected reusable workflow code")
    require(document["jobs"]["ci"]["with"].get("secretless-ci-script-plan") ==
            '["build","lint","test","test:contract","test:npm-config",'
            '"test:package-surface","test:public-docs","test:release-v1"]',
            "current Node lane script plan drifted")
    require("secretless-ci-script-plan" not in document["jobs"]["ci-node-floor"]["with"],
            "Node floor lane must exercise the canonical default suite")
    job = document["jobs"]["package-surface"]
    require(job.get("needs") == ["admission", "ci", "ci-node-floor"],
            "package surface does not require both protected CI lanes")
    require(job.get("runs-on") == "ubuntu-24.04",
            "required workflow must use an ephemeral hosted runner")
    require(job.get("permissions") == {"contents": "read"},
            "job permissions drifted")
    steps = job.get("steps", [])
    require(len(steps) == 3, "required workflow step count drifted")
    checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    require(steps[0].get("uses") == checkout, "candidate checkout action drifted")
    require(steps[0].get("with") == {
        "ref": "${{ github.event.pull_request.head.sha }}",
        "persist-credentials": False,
        "path": "consumer",
    }, "candidate checkout boundary drifted")
    require(steps[1].get("uses") == checkout, "policy checkout action drifted")
    require(steps[1].get("with") == {
        "repository": "Verjson/.github",
        "ref": "${{ github.workflow_sha }}",
        "persist-credentials": False,
        "path": "policy",
    }, "protected verifier checkout boundary drifted")
    require(steps[2].get("run") ==
            "python3 policy/scripts/cli-projects-package-surface.py verify consumer",
            "protected verifier invocation drifted")
    serialized_surface = json.dumps(job)
    require("secrets." not in serialized_surface and "github.token" not in serialized_surface,
            "package-surface execution may not receive a credential")


def render_payload(contract, workflow_sha):
    require(SHA_PATTERN.fullmatch(workflow_sha),
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
    require(isinstance(value, dict) and set(MUTABLE_FIELDS) <= set(value),
            "live ruleset is missing required fields")
    return {key: value[key] for key in MUTABLE_FIELDS}


def validate_org_ruleset(value, expected):
    require(value.get("source_type") == "Organization", "ruleset source is not Organization")
    require(value.get("source") == "Verjson", "ruleset organization drifted")
    require(mutable_ruleset(value) == expected, "live organization ruleset differs from reviewed image")


def expected_repository_ruleset(contract, enforcement=None):
    expected = dict(contract["consumer"]["repository_ruleset"])
    if enforcement is not None:
        expected["enforcement"] = enforcement
    return expected


def validate_repository_ruleset(value, expected):
    require(value.get("source_type") == "Repository", "repository ruleset source type drifted")
    require(value.get("source") == "Verjson/verjson-cli-projects",
            "repository ruleset source drifted")
    require(value.get("id") == expected["id"], "repository ruleset id drifted")
    require(mutable_ruleset(value) == {key: expected[key] for key in MUTABLE_FIELDS},
            "repository ruleset preimage drifted")


def gh_json(*arguments):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", *arguments],
        capture_output=True, text=True, check=False,
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
    pages = gh_json("--paginate", "--slurp", "orgs/Verjson/rulesets?per_page=100")
    require(isinstance(pages, list) and pages, "organization ruleset listing is empty")
    entries = [entry for page in pages for entry in page]
    return [entry for entry in entries if entry.get("name") == contract["ruleset"]["name"]]


def verify_canonical_bytes(contract, workflow_sha):
    comparison = gh_json(f"repos/Verjson/.github/compare/{workflow_sha}...main")
    require(comparison.get("status") in ("ahead", "identical"),
            "workflow SHA is not reachable from protected main")
    paths = (
        contract["canonical_workflow"]["path"],
        "config/cli-projects-package-surface-ruleset.json",
        "config/cli-projects-required-node-ci.json",
        "scripts/cli-projects-package-surface.py",
        "scripts/cli-projects-package-surface-ruleset.py",
        "scripts/gen-node-required-workflow.py",
    )
    for path in paths:
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com",
             f"repos/Verjson/.github/contents/{path}?ref={workflow_sha}",
             "-H", "Accept: application/vnd.github.raw+json"],
            capture_output=True, check=False,
        )
        require(result.returncode == 0, f"canonical file unreadable at workflow SHA: {path}")
        require(result.stdout == (ROOT / path).read_bytes(),
                f"local file is not the merged canonical byte sequence: {path}")


def consumer_branch_sha():
    reference = gh_json("repos/Verjson/verjson-cli-projects/git/ref/heads/main")
    sha = reference.get("object", {}).get("sha")
    require(isinstance(sha, str) and SHA_PATTERN.fullmatch(sha),
            "consumer default-branch SHA unreadable")
    return sha


def assert_consumer_branch_sha(expected_sha):
    if expected_sha is None:
        return
    require(consumer_branch_sha() == expected_sha,
            "consumer default branch moved during transaction")


def verify_consumer_workflow(contract, expected_sha=None):
    generated = subprocess.run(
        [sys.executable, str(GENERATOR), "--consumer",
         "config/cli-projects-required-node-ci.json"],
        cwd=ROOT, capture_output=True, check=False,
    )
    require(generated.returncode == 0, "consumer workflow generation failed")
    branch_sha = consumer_branch_sha()
    if expected_sha is not None:
        require(branch_sha == expected_sha,
                "consumer default branch moved during transaction")
    workflow = contract["consumer"]["workflow"]
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com",
         f"repos/Verjson/verjson-cli-projects/contents/{workflow['path']}?ref={branch_sha}",
         "-H", "Accept: application/vnd.github.raw+json"],
        capture_output=True, check=False,
    )
    require(result.returncode == 0, "consumer workflow default-branch bytes unreadable")
    require(result.stdout == generated.stdout,
            "consumer workflow is not the reviewed push-only generated image")
    assert_consumer_branch_sha(branch_sha)
    return branch_sha


def discover_state(contract, workflow_sha):
    validate_workflow()
    verify_canonical_bytes(contract, workflow_sha)
    consumer_sha = verify_consumer_workflow(contract)
    repository = gh_json("repos/Verjson/verjson-cli-projects")
    require(repository.get("id") == contract["consumer"]["repository_id"],
            "consumer repository identity drifted")
    expected_repo = expected_repository_ruleset(contract)
    live_repo = gh_json(f"repos/Verjson/verjson-cli-projects/rulesets/{expected_repo['id']}")
    validate_repository_ruleset(live_repo, expected_repo)
    named = list_named_rulesets(contract)
    require(len(named) <= 1, "multiple organization rulesets use the canonical name")
    return named, consumer_sha


def reconcile_org_disabled(ruleset_id, staged):
    path = f"orgs/Verjson/rulesets/{ruleset_id}"
    try:
        current = gh_json(path)
        validate_org_ruleset(current, staged)
    except (ContractError, OSError):
        pass
    else:
        raise ContractError(
            "organization activation failed; rule remains verified disabled"
        )
    try:
        gh_json_input("PUT", path, staged)
        restored = gh_json(path)
        validate_org_ruleset(restored, staged)
    except (ContractError, OSError):
        raise ContractError("activation failed and disabled rollback could not be verified") from None
    raise ContractError("activation failed; organization rule restored and verified disabled")


def resolve_existing_org_rule(named, expected, staged, previous=None):
    require(len(named) == 1, "canonical organization ruleset is not uniquely present")
    ruleset_id = named[0].get("id")
    require(isinstance(ruleset_id, int) and ruleset_id > 0,
            "canonical organization ruleset id is invalid")
    live = gh_json(f"orgs/Verjson/rulesets/{ruleset_id}")
    try:
        validate_org_ruleset(live, expected)
        return ruleset_id, "active"
    except ContractError:
        if previous is not None:
            try:
                validate_org_ruleset(live, previous)
                return ruleset_id, "previous-active"
            except ContractError:
                pass
        try:
            validate_org_ruleset(live, staged)
            return ruleset_id, "disabled"
        except ContractError:
            raise ContractError(
                "canonical organization ruleset differs from active and disabled reviewed images"
            ) from None


def rotate_existing_org_rule(ruleset_id, previous, expected, consumer_sha=None):
    path = f"orgs/Verjson/rulesets/{ruleset_id}"
    validate_org_ruleset(gh_json(path), previous)
    try:
        assert_consumer_branch_sha(consumer_sha)
        gh_json_input("PUT", path, expected)
        assert_consumer_branch_sha(consumer_sha)
        validate_org_ruleset(gh_json(path), expected)
        return
    except (ContractError, OSError):
        pass
    try:
        assert_consumer_branch_sha(consumer_sha)
        current = gh_json(path)
        validate_org_ruleset(current, expected)
        return
    except (ContractError, OSError):
        pass
    try:
        gh_json_input("PUT", path, previous)
        validate_org_ruleset(gh_json(path), previous)
    except (ContractError, OSError):
        raise ContractError("rotation failed and prior active workflow could not be verified") from None
    raise ContractError("rotation failed; prior active workflow restored and verified")


def reconcile_repository_evaluate(path, expected):
    try:
        current = gh_json(path)
        validate_repository_ruleset(current, expected)
    except (ContractError, OSError):
        pass
    else:
        raise ContractError(
            "repository activation failed; ruleset remains verified evaluate"
        )
    rollback = {key: expected[key] for key in MUTABLE_FIELDS}
    try:
        gh_json_input("PUT", path, rollback)
        restored = gh_json(path)
        validate_repository_ruleset(restored, expected)
    except (ContractError, OSError):
        raise ContractError(
            "repository activation failed and evaluate rollback could not be verified"
        ) from None
    raise ContractError(
        "repository activation failed; ruleset restored and verified evaluate"
    )


def activate_repository_rule(contract, consumer_sha=None):
    rule_id = contract["consumer"]["repository_ruleset"]["id"]
    path = f"repos/Verjson/verjson-cli-projects/rulesets/{rule_id}"
    before = gh_json(path)
    expected_before = expected_repository_ruleset(contract)
    validate_repository_ruleset(before, expected_before)
    active = expected_repository_ruleset(contract, "active")
    payload = {key: active[key] for key in MUTABLE_FIELDS}
    try:
        assert_consumer_branch_sha(consumer_sha)
        gh_json_input("PUT", path, payload)
        assert_consumer_branch_sha(consumer_sha)
        after = gh_json(path)
        validate_repository_ruleset(after, active)
    except (ContractError, OSError):
        reconcile_repository_evaluate(path, expected_before)


def parse_timestamp(value):
    require(isinstance(value, str) and value.endswith("Z"), "ruleset timestamp is invalid")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise ContractError("ruleset timestamp is invalid") from None


def validate_required_run(run, contract, workflow_sha, head_sha, minimum_run_id, not_before):
    required = contract["rollout"]["required_run"]
    require(run.get("event") == "pull_request", "run event is not pull_request")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "required workflow run is not successful")
    require(run.get("head_sha") == head_sha, "required workflow run is stale")
    require(isinstance(run.get("id"), int) and run["id"] > minimum_run_id,
            "required workflow run predates trigger snapshot")
    require(parse_timestamp(run.get("created_at")) >= not_before,
            "required workflow run predates ruleset activation")
    require(run.get("path") == required["path"], "run path is not protected workflow")
    url = run.get("workflow_url", "")
    require(url.startswith(required["workflow_url_prefix"]),
            "run was not created by organization required-workflow rule")
    require(url.removeprefix(required["workflow_url_prefix"]).isdigit(),
            "required workflow URL id is invalid")
    require(run.get("workflow_sha") in (None, workflow_sha),
            "reported workflow SHA disagrees with rule binding")


def main(arguments=None):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=("render", "dry-run", "apply", "snapshot", "verify-run", "activate-repository"),
    )
    parser.add_argument("--workflow-sha", required=True)
    parser.add_argument("--ack", default="")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--head-sha")
    parser.add_argument("--pre-trigger-max-run-id", type=int)
    args = parser.parse_args(arguments)
    contract = read_contract()
    expected = render_payload(contract, args.workflow_sha)
    previous = render_payload(contract, contract["rollout"]["previous_workflow_sha"])
    if args.mode == "render":
        print(json.dumps(expected, indent=2))
        return 0
    named, consumer_sha = discover_state(contract, args.workflow_sha)
    if args.mode == "dry-run":
        return 0
    if args.mode == "snapshot":
        runs = gh_json(
            "repos/Verjson/verjson-cli-projects/actions/runs?event=pull_request&per_page=100"
        )
        require(isinstance(runs.get("workflow_runs"), list), "run listing is malformed")
        maximum = max(
            (run.get("id", 0) for run in runs["workflow_runs"] if isinstance(run, dict)),
            default=0,
        )
        print(json.dumps({"pre_trigger_max_run_id": maximum}))
        return 0
    if args.mode in ("verify-run", "activate-repository"):
        require(args.run_id is not None and args.run_id > 0, "--run-id is required")
        require(args.head_sha is not None and SHA_PATTERN.fullmatch(args.head_sha),
                "--head-sha is required")
        require(args.pre_trigger_max_run_id is not None and args.pre_trigger_max_run_id >= 0,
                "--pre-trigger-max-run-id is required")
        require(len(named) == 1, "canonical organization ruleset is not uniquely present")
        live = gh_json(f"orgs/Verjson/rulesets/{named[0]['id']}")
        validate_org_ruleset(live, expected)
        run = gh_json(f"repos/Verjson/verjson-cli-projects/actions/runs/{args.run_id}")
        validate_required_run(
            run, contract, args.workflow_sha, args.head_sha,
            args.pre_trigger_max_run_id, parse_timestamp(live.get("updated_at")),
        )
        if args.mode == "verify-run":
            print("verified: fresh exact-head organization required-workflow run")
            return 0
    require(args.ack == contract["rollout"]["apply_acknowledgement"],
            "explicit apply acknowledgement required")
    if args.mode == "activate-repository":
        activate_repository_rule(contract, consumer_sha)
        print("activated and verified repository ruleset 21567958")
        return 0
    staged = dict(expected)
    staged["enforcement"] = "disabled"
    if named:
        ruleset_id, state = resolve_existing_org_rule(named, expected, staged, previous)
        if state == "active":
            print(f"verified existing active organization ruleset {ruleset_id}")
            return 0
        if state == "previous-active":
            rotate_existing_org_rule(ruleset_id, previous, expected, consumer_sha)
            print(f"rotated and verified active organization ruleset {ruleset_id}")
            return 0
    else:
        appeared, appeared_consumer_sha = discover_state(contract, args.workflow_sha)
        require(appeared_consumer_sha == consumer_sha,
                "consumer default branch moved during transaction")
        if appeared:
            ruleset_id, state = resolve_existing_org_rule(appeared, expected, staged, previous)
            if state == "active":
                print(f"verified existing active organization ruleset {ruleset_id}")
                return 0
            if state == "previous-active":
                rotate_existing_org_rule(ruleset_id, previous, expected, consumer_sha)
                print(f"rotated and verified active organization ruleset {ruleset_id}")
                return 0
        else:
            try:
                created = gh_json_input("POST", "orgs/Verjson/rulesets", staged)
                ruleset_id = created.get("id")
                require(isinstance(ruleset_id, int) and ruleset_id > 0,
                        "created ruleset returned no positive id")
                validate_org_ruleset(
                    gh_json(f"orgs/Verjson/rulesets/{ruleset_id}"), staged
                )
            except (ContractError, OSError):
                recovered = list_named_rulesets(contract)
                ruleset_id, state = resolve_existing_org_rule(
                    recovered, expected, staged
                )
                if state == "active":
                    print(f"verified existing active organization ruleset {ruleset_id}")
                    return 0
    try:
        assert_consumer_branch_sha(consumer_sha)
        gh_json_input("PUT", f"orgs/Verjson/rulesets/{ruleset_id}", expected)
        assert_consumer_branch_sha(consumer_sha)
        validate_org_ruleset(gh_json(f"orgs/Verjson/rulesets/{ruleset_id}"), expected)
    except (ContractError, OSError):
        reconcile_org_disabled(ruleset_id, staged)
    print(f"created disabled, activated, verified organization ruleset {ruleset_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
