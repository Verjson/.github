#!/usr/bin/env python3
"""Adversarial contract for the trusted issues:labeled authorization bridge."""

from copy import deepcopy
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/gate-rearm.yml"
GENERATOR = ROOT / "scripts/gen-gate-rearm-caller.sh"


def validate(document: dict, text: str) -> None:
    triggers = document[True]
    assert triggers["issues"] == {"types": ["labeled"]}
    assert "labeled" not in triggers["pull_request_target"]["types"]
    assert document["permissions"] == {"contents": "read"}
    arm = document["jobs"]["arm"]
    assert arm["permissions"] == {
        "actions": "write",
        "contents": "read",
        "issues": "write",
        "pull-requests": "write",
    }
    assert arm["env"]["PR_NUMBER"] == "${{ github.event.pull_request.number || github.event.issue.number }}"
    script = next(step["run"] for step in arm["steps"] if step.get("id") == "arm")
    required = (
        '[ "$EVENT_NAME" = issues ]',
        '[ "$EVENT_ACTION" = labeled ]',
        'case "$label_normalized" in ai-review|re-review)',
        '[ "${GITHUB_RUN_ATTEMPT:-}" = 1 ]',
        '[[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]]',
        '[ "$WORKFLOW_REF" = "$TARGET_REPO/.github/workflows/gate-rearm.yml@refs/heads/$DEFAULT_BRANCH" ]',
        '.event == "issues" and .path == ".github/workflows/gate-rearm.yml"',
        '.head_repository.full_name == $repo and .repository.id == $repo_id',
        '.actor.login == $actor',
        '[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]',
        '[ "$head_owner" != "$GITHUB_REPOSITORY_OWNER" ]',
        'elif [ "$EVENT_ACTION" = labeled ]',
        'schema:(if $delivery_event == "issues" then 2 else 1 end)',
        'if $delivery_event == "issues" then',
    )
    assert all(marker in script for marker in required)
    assert 'elif [ -n "$ai_review_label" ]' not in script
    mint = next(step for step in arm["steps"] if step.get("id") == "app-token")
    assert mint["with"] == {
        "client-id": "${{ vars.AI_REVIEW_CLIENT_ID }}",
        "private-key": "${{ secrets.AI_REVIEW_APP_PRIVATE_KEY }}",
        "owner": "${{ github.repository_owner }}",
        "repositories": "${{ github.event.repository.name }}",
    }
    assert "ORG_ADMIN_TOKEN" not in text and "secrets: inherit" not in text


def rejects(mutator, document: dict, text: str) -> None:
    mutant = deepcopy(document)
    mutant_text = mutator(mutant, text)
    try:
        validate(mutant, mutant_text)
    except AssertionError:
        return
    raise AssertionError("security mutation escaped the label bridge contract")


def main() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    document = yaml.safe_load(text)
    validate(document, text)

    def widen_permissions(doc, value):
        doc["jobs"]["arm"]["permissions"]["checks"] = "write"
        return value

    def restore_pr_label_trigger(doc, value):
        doc[True]["pull_request_target"]["types"].append("labeled")
        return value

    def allow_persistent_label(doc, value):
        step = next(step for step in doc["jobs"]["arm"]["steps"] if step.get("id") == "arm")
        step["run"] += '\nelif [ -n "$ai_review_label" ]; then true; fi\n'
        return value

    def remove_binding(doc, value):
        mutated = value.replace('.actor.login == $actor', 'true')
        doc.clear()
        doc.update(yaml.safe_load(mutated))
        return mutated

    for mutation in (widen_permissions, restore_pr_label_trigger, allow_persistent_label, remove_binding):
        rejects(mutation, document, text)

    generator = GENERATOR.read_text(encoding="utf-8")
    assert "issues:" in generator and "types: [labeled]" in generator
    assert "pull_request_target:" in generator
    print("PASS: label delivery bridge is exact-source, exact-actor, exact-head and fail-closed")


if __name__ == "__main__":
    main()
