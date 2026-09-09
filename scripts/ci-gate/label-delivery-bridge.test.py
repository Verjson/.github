#!/usr/bin/env python3
from pathlib import Path
import copy
import json
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[2]
ARM = ROOT / ".github/workflows/gate-rearm.yml"
CALLER = ROOT / ".github/workflows/ai-review-label-rearm.yml"
GENERATOR = ROOT / "scripts/gen-ai-review-label-rearm-caller.sh"

def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))

def validate_caller(doc, target):
    assert doc[True] == {"pull_request_target": {"types": ["labeled", "ready_for_review", "converted_to_draft", "edited", "unlabeled"]}}
    assert doc["permissions"] == {"contents": "read"}
    assert doc["jobs"] == {"rearm": {
        "permissions": {"actions": "write", "contents": "read", "issues": "write", "pull-requests": "write"},
        "uses": target,
        "secrets": {"AI_REVIEW_APP_PRIVATE_KEY": "${{ secrets.AI_REVIEW_APP_PRIVATE_KEY }}"},
    }}

def validate_event_admission(job):
    condition = job.get("if", "true")
    cases = [
        ("body-only edit", {"action": "edited", "changes": {"body": {"from": "old body"}}}, False),
        ("base-only edit", {"action": "edited", "changes": {"base": {"ref": {"from": "main"}}}}, False),
        ("missing changes", {"action": "edited"}, False),
        ("null previous title", {"action": "edited", "changes": {"title": {"from": None}}}, False),
        ("empty previous title", {"action": "edited", "changes": {"title": {"from": ""}}}, False),
        ("ordinary title edit", {"action": "edited", "changes": {"title": {"from": "Old title"}}}, True),
        ("title removal", {"action": "edited", "changes": {"title": {"from": "Old title"}}, "pull_request": {"title": ""}}, True),
        ("add title hold", {"action": "edited", "changes": {"title": {"from": "Old title"}}, "pull_request": {"title": "DO NOT MERGE: Old title"}}, True),
        ("remove title hold", {"action": "edited", "changes": {"title": {"from": "do not merge: Old title"}}, "pull_request": {"title": "Old title"}}, True),
    ]
    cases.extend((action, {"action": action}, True) for action in (
        "opened", "reopened", "synchronize", "labeled", "unlabeled",
        "ready_for_review", "converted_to_draft",
    ))
    for name, event, expected in cases:
        context = copy.deepcopy(event)
        context.setdefault("changes", {}).setdefault("title", {}).setdefault("from", "")
        # The configured guard uses string inequality and truthiness, which have
        # the same semantics in JavaScript for these GitHub event values.
        completed = subprocess.run([
            "node", "-e",
            'const vm = require("node:vm"); process.stdout.write(JSON.stringify(Boolean(vm.runInNewContext(process.argv[1], {github: {event: JSON.parse(process.argv[2])}}))));',
            condition, json.dumps(context),
        ], check=True, capture_output=True, text=True)
        assert json.loads(completed.stdout) is expected, name

def main():
    arm = load(ARM)
    validate_event_admission(arm["jobs"]["arm"])
    assert "issues" not in arm[True]
    assert "labeled" not in arm[True]["pull_request_target"]["types"]
    validate_caller(load(CALLER), "./.github/workflows/gate-rearm.yml")
    sha = "1" * 40
    with tempfile.NamedTemporaryFile() as generated:
        subprocess.run([str(GENERATOR), sha], check=True, stdout=generated)
        generated.flush()
        validate_caller(load(Path(generated.name)), f"Verjson/.github/.github/workflows/gate-rearm.yml@{sha}")
    for invalid in ("main", "v1", "1" * 39, "1" * 41):
        assert subprocess.run([str(GENERATOR), invalid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    script = next(step["run"] for step in arm["jobs"]["arm"]["steps"] if step.get("id") == "arm")
    for marker in (
        '[ "$EVENT_NAME" = pull_request_target ] && [ "$EVENT_ACTION" = labeled ]',
        'case "$label_normalized" in ai-review|re-review)',
        '[ "${GITHUB_RUN_ATTEMPT:-}" = 1 ]',
        '[ "$WORKFLOW_REF" = "$TARGET_REPO/.github/workflows/ai-review-label-rearm.yml@refs/heads/$DEFAULT_BRANCH" ]',
        '.path == ".github/workflows/ai-review-label-rearm.yml"',
        '.head_sha == $head',
        '[ "$head_sha" != "$EVENT_HEAD_SHA" ]',
        '.actor.login == $actor',
        '[ -n "$rereview_label" ]',
        '[ -n "$ai_review_label" ]',
        'schema:(if $source_bound then 2 else 1 end)',
    ):
        assert marker in script
    assert "ORG_ADMIN_TOKEN" not in ARM.read_text() and "secrets: inherit" not in CALLER.read_text()
    print("PASS: separate protected PR-label caller is exact-source, exact-head, actor-bound and fail-closed")

if __name__ == "__main__":
    main()
