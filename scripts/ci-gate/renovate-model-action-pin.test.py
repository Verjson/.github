#!/usr/bin/env python3
"""Verify Renovate updates the Claude action and its audited pin together."""

import json
from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[2]
ACTION = "anthropics/claude-code-action"
AUDIT_FILE = ROOT / "scripts/ci-gate/event-driven-authorization.test.py"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


config = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
managers = [
    manager
    for manager in config.get("customManagers", [])
    if manager.get("depNameTemplate") == ACTION
]
require(len(managers) == 1, "the audited Claude action pin needs one custom manager")
manager = managers[0]
require(manager.get("customType") == "regex", "the audited pin manager must use custom.regex")
require(manager.get("datasourceTemplate") == "github-tags", "the audited pin must resolve from GitHub tags")
require(manager.get("currentValueTemplate") == "v1", "the audited pin must follow the workflow's v1 channel")
require(
    manager.get("managerFilePatterns")
    == [r"/^scripts\/ci-gate\/event-driven-authorization\.test\.py$/"],
    "the custom manager must be scoped to the audited pin file",
)

patterns = manager.get("matchStrings", [])
require(len(patterns) == 1, "the audited pin manager needs one exact match expression")
python_pattern = patterns[0].replace("(?<currentDigest>", "(?P<currentDigest>")
matches = list(re.finditer(python_pattern, AUDIT_FILE.read_text(encoding="utf-8")))
require(len(matches) == 1, "the custom manager must match exactly one audited SHA")
audited_sha = matches[0].group("currentDigest")

workflow = yaml.safe_load(
    (ROOT / ".github/workflows/ai-review-merge.yml").read_text(encoding="utf-8")
)
workflow_actions = [
    step["uses"].split("@", 1)[1]
    for job in workflow["jobs"].values()
    for step in job.get("steps", [])
    if step.get("uses", "").startswith(f"{ACTION}@")
]
require(workflow_actions == [audited_sha], "the workflow and audited action SHA must match")

groups = [
    rule
    for rule in config.get("packageRules", [])
    if rule.get("groupName") == "github actions digests"
]
require(len(groups) == 1, "the action digest group must remain unique")
require(
    set(groups[0].get("matchManagers", [])) == {"github-actions", "custom.regex"},
    "workflow and audited pins must share one Renovate group",
)

print("All Renovate model-action pin tests passed.")
