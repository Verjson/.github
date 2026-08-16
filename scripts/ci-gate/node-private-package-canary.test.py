#!/usr/bin/env python3

from pathlib import Path

import yaml


root = Path(__file__).resolve().parents[2]
workflow = root / ".github/workflows/node-private-package-canary.yml"
document = yaml.safe_load(workflow.read_text(encoding="utf-8"))
job = document["jobs"]["fresh-cache-add"]
steps = job["steps"]
acquire = next(step for step in steps if step.get("name", "").startswith("Acquire one fixed"))
cleanup = steps[-1]

assert document["permissions"] == {}
assert document[True] == {"pull_request": {"paths": [
    ".github/workflows/node-ci.yml",
    ".github/workflows/node-private-package-canary.yml",
]}}
assert job["permissions"] == {"contents": "read", "packages": "read"}
assert job["timeout-minutes"] == 5
assert acquire["env"]["NODE_AUTH_TOKEN"] == "${{ github.token }}"
assert acquire["env"]["PACKAGE_URL"].endswith("82a9d2eaf6862dc9210f7b368618ef153976758c")
assert 'mkdir "$NPM_CONFIG_CACHE"' in acquire["run"]
assert 'npm cache add "$PACKAGE_URL"' in acquire["run"]
assert "EXPECTED_SHA512" in acquire["run"]
assert cleanup["if"] == "always()"
assert "rm -rf" in cleanup["run"]
raw = workflow.read_text(encoding="utf-8")
assert "actions/checkout@" not in raw
assert "pull_request_target" not in raw

print("ok - private package canary proves fixed authenticated cache-add without PR code")
