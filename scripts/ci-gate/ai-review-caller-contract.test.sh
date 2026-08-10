#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sha=0123456789abcdef0123456789abcdef01234567

"$root/scripts/gen-ai-review-caller.sh" "$sha" >"$tmp/caller.yml"
python3 - "$tmp/caller.yml" "$sha" <<'PY'
import sys, yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.load(stream, Loader=yaml.BaseLoader)
sha = sys.argv[2]
assert workflow["on"] == {"workflow_dispatch": {"inputs": {
    "pr_number": {"required": "true", "type": "string"},
    "expected_head_sha": {"required": "true", "type": "string"},
    "authorization_check_id": {"required": "true", "type": "string"},
    "arm_run_id": {"required": "true", "type": "string"},
    "arm_run_attempt": {"required": "true", "type": "string"},
    "explicit_rereview": {"required": "false", "type": "boolean", "default": "false"},
    "review_policy": {"required": "true", "type": "string"},
}}}
assert workflow["permissions"] == {
    "actions": "write", "checks": "read", "contents": "read",
    "issues": "write", "pull-requests": "write", "statuses": "read",
}
job = workflow["jobs"]["review"]
assert job["uses"] == f"Verjson/.github/.github/workflows/ai-review-merge.yml@{sha}"
assert set(job) == {"uses", "secrets", "with"}
assert set(job["secrets"]) == {
    "AI_REVIEW_APP_PRIVATE_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY",
}
assert set(job["with"]) == {
    "pr_number", "expected_head_sha", "authorization_check_id", "arm_run_id",
    "arm_run_attempt", "explicit_rereview", "review_policy",
}
PY

grep -qF "scripts/gen-ai-review-caller.sh $sha" "$tmp/caller.yml"
if grep -Eq '(^|@)(main|master|v[0-9]+)([[:space:]]|$)' "$tmp/caller.yml"; then
  echo 'generated review caller contains a mutable reference' >&2
  exit 1
fi
for invalid in main v1 0123456789abcdef0123456789abcdef0123456 ''; do
  if "$root/scripts/gen-ai-review-caller.sh" "$invalid" >/dev/null 2>&1; then
    echo "generator accepted unsafe ref: ${invalid:-<empty>}" >&2
    exit 1
  fi
done

echo 'AI review caller generator contract: ok'
