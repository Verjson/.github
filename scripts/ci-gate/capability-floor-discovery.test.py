"""Adversarial contract for live, report-only caller-pin discovery (ADR 0135)."""

from __future__ import annotations

import base64
import copy
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/capability-floor-discovery.py"
WORKFLOW = ROOT / ".github/workflows/capability-floor-observe.yml"
ACTION = "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
CLIENT_ID = "${{ vars.RENOVATE_COMPATIBILITY_CLIENT_ID }}"
PRIVATE_KEY = "${{ secrets.RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY }}"
TOKEN = "${{ steps.observer-app-token.outputs.token }}"
SCOPE = "${{ steps.scope.outputs.repositories }}"
PIN = "a" * 40
SOURCE_SHA = "b" * 40
BLOB_SHA = "c" * 40


def workflow_problems(document: dict, raw: str) -> list[str]:
    problems: list[str] = []
    job = document["jobs"]["observe"]
    steps = job["steps"]
    mint = next(step for step in steps if step.get("id") == "observer-app-token")
    expected_mint = {
        "client-id": CLIENT_ID,
        "private-key": PRIVATE_KEY,
        "owner": "Verjson",
        "repositories": SCOPE,
        "permission-contents": "read",
    }
    if document.get("permissions") != {"contents": "read"}:
        problems.append("workflow GITHUB_TOKEN is not contents-read only")
    if "vars.CI_LANE_PRIVILEGED" not in str(job.get("runs-on")):
        problems.append("secret-bearing observer is not on the privileged lane")
    if mint.get("uses") != ACTION or mint.get("with") != expected_mint:
        problems.append("App mint is not exact-scope contents-read only")
    if not re.search(
        r'\[\[ -z "\$RENOVATE_COMPATIBILITY_CLIENT_ID" \|\| '
        r'"\$RENOVATE_COMPATIBILITY_CLIENT_ID" =~ \^\[0-9\]\+\$ \]\]',
        raw,
    ):
        problems.append("missing or numeric App client IDs do not fail closed")
    if raw.count(PRIVATE_KEY) != 1:
        problems.append("App private key escaped the mint step")
    token_consumers = [
        step.get("name") for step in steps if (step.get("env") or {}).get("GH_TOKEN") == TOKEN
    ]
    if token_consumers != ["Discover immutable caller pins"]:
        problems.append("App token escaped the discovery step")
    scope_step = next(step for step in steps if step.get("id") == "scope")
    if "capability-floor-discovery.py --print-repositories" not in scope_step.get("run", ""):
        problems.append("repository scope is not derived from the reviewed allowlist")
    checkout = next(step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@"))
    if (checkout.get("with") or {}).get("persist-credentials") is not False:
        problems.append("checkout persists a credential")
    forbidden = (
        "ORG_ADMIN_TOKEN",
        "RENOVATE_COMPATIBILITY_PAT",
        "permission-contents: write",
        "permission-issues",
        "permission-pull-requests",
        "gh pr ",
        "gh issue ",
        "repository_dispatch",
    )
    if any(value in raw for value in forbidden):
        problems.append("workflow contains a write or broad credential path")
    if "workflow_dispatch: {}" not in raw or "schedule:" not in raw:
        problems.append("workflow is not both scheduled and manually dispatchable")
    if "capability-floor-report.json" not in raw or "GITHUB_STEP_SUMMARY" not in raw:
        problems.append("report artifact or workflow summary evidence is absent")
    return problems


def assert_mutation_rejected(label: str, document: dict, raw: str) -> None:
    if not workflow_problems(document, raw):
        raise AssertionError(f"workflow mutation survived: {label}")


def allowlist(path: pathlib.Path, repository: str = "Verjson/example", workflow: str = "gate-rearm.yml") -> pathlib.Path:
    payload = {
        "schema_version": 1,
        "consumers": [
            {
                "repository": repository,
                "callers": [
                    {
                        "path": ".github/workflows/gate-rearm.yml",
                        "generator": "scripts/gen-gate-rearm-caller.sh",
                        "canonical_workflows": [workflow],
                    }
                ],
            }
        ],
    }
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def run_discovery(tmp: pathlib.Path, caller: str, *, repository: str = "Verjson/example", mode: str = "ok"):
    config = allowlist(tmp / "allowlist.json", repository)
    env = os.environ.copy()
    env["PATH"] = f"{tmp}{os.pathsep}{env['PATH']}"
    env["CALLER_TEXT_B64"] = base64.b64encode(caller.encode()).decode()
    env["STUB_MODE"] = mode
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--allowlist",
            str(config),
            "--pins-output",
            str(tmp / "pins.json"),
            "--receipts-output",
            str(tmp / "receipts.json"),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def main() -> None:
    raw = WORKFLOW.read_text(encoding="utf-8")
    document = yaml.safe_load(raw)
    problems = workflow_problems(document, raw)
    assert not problems, problems

    mutant = copy.deepcopy(document)
    next(step for step in mutant["jobs"]["observe"]["steps"] if step.get("id") == "observer-app-token")["with"]["permission-pull-requests"] = "write"
    assert_mutation_rejected("write permission", mutant, raw)
    mutant = copy.deepcopy(document)
    next(step for step in mutant["jobs"]["observe"]["steps"] if step.get("id") == "observer-app-token")["with"]["repositories"] = "*"
    assert_mutation_rejected("repository widening", mutant, raw)
    mutant = copy.deepcopy(document)
    next(step for step in mutant["jobs"]["observe"]["steps"] if step.get("id") == "observer-app-token")["uses"] = "actions/create-github-app-token@v3"
    assert_mutation_rejected("mutable token action", mutant, raw)
    mutant = copy.deepcopy(document)
    next(step for step in mutant["jobs"]["observe"]["steps"] if step.get("id") == "observer-app-token")["with"].pop("private-key")
    assert_mutation_rejected("missing private key", mutant, raw)

    with tempfile.TemporaryDirectory() as directory:
        tmp = pathlib.Path(directory)
        stub = tmp / "gh"
        stub.write_text(
            """#!/usr/bin/env python3
import json, os, sys
endpoint = sys.argv[sys.argv.index('GET') + 1]
if os.environ.get('STUB_MODE') == 'api-failure':
    print('denied', file=sys.stderr)
    raise SystemExit(1)
if endpoint == 'repos/Verjson/example':
    print(json.dumps({'default_branch': 'main'}))
elif endpoint == 'repos/Verjson/example/commits/main':
    print(json.dumps({'sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}))
elif endpoint == 'repos/Verjson/example/contents/.github/workflows/gate-rearm.yml':
    print(json.dumps({'type': 'file', 'encoding': 'base64', 'sha': 'cccccccccccccccccccccccccccccccccccccccc', 'content': os.environ['CALLER_TEXT_B64']}))
else:
    print('unexpected endpoint: ' + endpoint, file=sys.stderr)
    raise SystemExit(1)
""",
            encoding="utf-8",
        )
        stub.chmod(0o755)

        valid = f"jobs:\n  arm:\n    uses: Verjson/.github/.github/workflows/gate-rearm.yml@{PIN}\n"
        result = run_discovery(tmp, valid)
        assert result.returncode == 0, result.stderr
        pins = json.loads((tmp / "pins.json").read_text())
        receipts = json.loads((tmp / "receipts.json").read_text())
        assert pins == [{"generator": "scripts/gen-gate-rearm-caller.sh", "pinned_sha": PIN, "repo": "Verjson/example"}]
        assert receipts["mode"] == "observe-only"
        assert receipts["receipts"][0]["source_sha"] == SOURCE_SHA
        assert receipts["receipts"][0]["blob_sha"] == BLOB_SHA

        scope_config = allowlist(tmp / "scope.json")
        scope = subprocess.run(
            [sys.executable, str(SCRIPT), "--allowlist", str(scope_config), "--print-repositories"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        assert scope.returncode == 0 and scope.stdout == "example\n"

        for label, caller in (
            ("mutable pin", "uses: Verjson/.github/.github/workflows/gate-rearm.yml@main\n"),
            ("uppercase pin", f"uses: Verjson/.github/.github/workflows/gate-rearm.yml@{PIN.upper()}\n"),
            ("wrong canonical target", f"uses: Verjson/.github/.github/workflows/ai-review-merge.yml@{PIN}\n"),
            ("mixed duplicate references", valid + f"  retry:\n    uses: Verjson/.github/.github/workflows/gate-rearm.yml@{'d' * 40}\n"),
            ("missing reference", "jobs: {}\n"),
        ):
            rejected = run_discovery(tmp, caller)
            assert rejected.returncode == 2, f"{label} survived: {rejected.stderr}"

        api_failure = run_discovery(tmp, valid, mode="api-failure")
        assert api_failure.returncode == 2 and "GitHub API read failed" in api_failure.stderr

        invalid_config = allowlist(tmp / "invalid-owner.json", "attacker/example")
        invalid = subprocess.run(
            [sys.executable, str(SCRIPT), "--allowlist", str(invalid_config), "--print-repositories"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        assert invalid.returncode == 2 and "outside the Verjson allowlist boundary" in invalid.stderr

    print("OK: capability-floor-discovery.test.py")


if __name__ == "__main__":
    main()
