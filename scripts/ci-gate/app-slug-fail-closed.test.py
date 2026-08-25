#!/usr/bin/env python3
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
workflow = yaml.safe_load((ROOT / ".github/workflows/gate-rearm.yml").read_text())
steps = workflow["jobs"]["arm"]["steps"]
arm = next(step for step in steps if step.get("name") == "Create exact-head authorization receipt")
script = arm["run"]

assert arm["env"]["MINTED_APP_SLUG"] == "${{ steps.app-token.outputs.app-slug }}"

early_error = "AI review authorization App slug mismatch: expected '$APP_SLUG', minted '$MINTED_APP_SLUG'"
post_error = "AI review authorization App slug mismatch after check creation: expected '$APP_SLUG', GitHub reported '$actual_app_slug'"
create = 'gh api --method POST "repos/$TARGET_REPO/check-runs"'
complete = 'gh api --method PATCH "repos/$TARGET_REPO/check-runs/$check_id"'
publish_output = 'echo "check_id=$check_id"'

assert early_error in script
assert script.index(early_error) < script.index(create)
assert "if [ \"$MINTED_APP_SLUG\" != \"$APP_SLUG\" ]" in script

assert post_error in script
assert script.index(create) < script.index(complete) < script.index(post_error)
assert "-f status=completed -f conclusion=failure" in script[script.index(complete):script.index(post_error)]
assert "No review was dispatched." in script[script.index(complete):script.index(post_error)]
assert script.index(post_error) < script.index(publish_output)

print("PASS - App slug drift fails before mutation or terminalizes the created check")
