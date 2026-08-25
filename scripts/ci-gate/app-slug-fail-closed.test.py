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
preflight = 'installation="$(gh api /installation)"'
error = "AI review authorization App identity mismatch: expected '$APP_SLUG' ($APP_ID)"

assert preflight in script and script.index(preflight) < script.index(create)
assert "minted_app_id" in script and "minted_app_slug" in script
assert "minted AI review authorization App installation identity is malformed or incomplete" in script
assert 'type == "number" and . > 0' in script
assert 'type == "string" and test("^[a-z0-9][a-z0-9-]*$")' in script
assert 'token_action_app_slug="$(printenv MINTED_APP_SLUG || true)"' in script
assert '[ "$token_action_app_slug" != "$APP_SLUG" ]' in script
assert '[ "$minted_app_id" != "$APP_ID" ]' in script
assert '[ "$minted_app_slug" != "$APP_SLUG" ]' in script
assert error in script and script.index(error) < script.index(create)
assert "force_terminal_failure" not in script
assert "AUTHORIZATION_CHECK_CREATED_ID" not in script

print("PASS - minted App ID/slug drift fails loudly before authorization creation")
