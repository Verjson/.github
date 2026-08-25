#!/usr/bin/env python3
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
workflow = yaml.safe_load((ROOT / ".github/workflows/gate-rearm.yml").read_text())
steps = workflow["jobs"]["arm"]["steps"]
arm = next(step for step in steps if step.get("name") == "Create exact-head authorization receipt")
script = arm["run"]

assert arm["env"]["MINTED_APP_SLUG"] == "${{ steps.app-token.outputs.app-slug }}"

create = 'gh api --method POST "repos/$TARGET_REPO/check-runs"'
error = "AI review authorization App slug mismatch: expected '$APP_SLUG'"

assert "gh api /installation" not in script
assert 'token_action_app_slug="$(printenv MINTED_APP_SLUG || true)"' in script
assert '[[ "$token_action_app_slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]' in script
assert '[ "$token_action_app_slug" != "$APP_SLUG" ]' in script
assert error in script and script.index(error) < script.index(create)
assert "force_terminal_failure" not in script
assert "AUTHORIZATION_CHECK_CREATED_ID" not in script

print("PASS - pinned token-action slug drift fails loudly before authorization creation")
