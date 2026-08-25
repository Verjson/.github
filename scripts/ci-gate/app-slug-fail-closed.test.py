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
create = 'gh api --method POST "repos/$TARGET_REPO/check-runs"'
activate = "-f status=in_progress"
publish_output = 'echo "check_id=$check_id"'

assert early_error in script
assert script.index(early_error) < script.index(create)
assert "if [ \"$MINTED_APP_SLUG\" != \"$APP_SLUG\" ]" in script

assert 'status:"completed",conclusion:"failure"' in script
assert script.index(create) < script.index("force_terminal_failure()") < script.index(activate)
assert script.index(activate) < script.index(publish_output)
assert script.count(".id == $id and .app.id == $app_id and .app.slug == $slug") >= 2
assert script.count(".external_id == $external_id") >= 3
assert 'status == "completed" and .conclusion == "failure"' in script
assert 'status == "in_progress" and .conclusion == null' in script

print("PASS - App slug and authorization-check lifecycle are fail-closed by construction")
