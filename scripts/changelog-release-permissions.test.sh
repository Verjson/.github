#!/usr/bin/env bash
# Exercises the token authority of the reusable changelog release workflow
# (Verjson/.github#295).
#
# A called workflow's `permissions` block is the cap — a caller granting
# contents: write cannot raise it. When the release job inherited the
# workflow-level `contents: read` default, the push credential reached the final
# atomic push read-only and every consumer release died with HTTP 403 after
# generating the snapshot. The assertions below pin the shape that failure
# requires: write authority scoped to the job that pushes, read everywhere else,
# and a short-lived App token constrained to the current repository (#329).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
workflow="$root/.github/workflows/changelog-release.yml"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# The release job's header: everything from `  release:` up to its `steps:`.
# Scoping matters — a workflow-level `contents: write` would satisfy a bare
# file-wide grep while granting the permission far more broadly than the push
# needs.
job_header="$(awk '
  /^  release:/ { inside = 1; next }
  inside && /^    steps:/ { exit }
  inside && /^  [^ ]/ { exit }
  inside { print }
' "$workflow")"

grep -qE '^      contents: write$' <<<"$job_header" \
  && pass "the release job grants contents: write to its own token" \
  || fail "the release job does not grant contents: write, so its push cannot succeed"

grep -qE '^    permissions:$' <<<"$job_header" \
  && pass "the write grant is scoped to the release job" \
  || fail "the release job declares no permissions block of its own"

# Least privilege is the reason the job-level override exists at all: anything
# this workflow gains later must ask for it explicitly.
workflow_default="$(awk '
  /^permissions:/ { inside = 1; next }
  inside && /^[^ ]/ { exit }
  inside { print }
' "$workflow")"

[ "$(grep -c . <<<"$workflow_default")" -eq 1 ] && grep -qE '^  contents: read$' <<<"$workflow_default" \
  && pass "the workflow-level default stays contents: read" \
  || fail "the workflow-level default is no longer a bare contents: read"

# The permission only matters because of what the job does with it. If either of
# these changes, the grant above needs re-justifying rather than inheriting.
python3 - "$workflow" <<'PY'
import sys

import yaml

path = sys.argv[1]
doc = yaml.safe_load(open(path, encoding="utf-8"))
call = doc.get("on", doc.get(True))["workflow_call"]
inputs = call.get("inputs") or {}
secrets = call.get("secrets") or {}
release = doc["jobs"]["release"]
steps = release.get("steps") or []
mint = next((step for step in steps if step.get("id") == "release-app-token"), {})
checkout = next(
    (step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@")),
    {},
)
problems = []
if not (inputs.get("release_app_client_id") or {}).get("required"):
    problems.append("workflow_call does not require release_app_client_id")
if set(secrets) != {"release_app_private_key"} or not secrets["release_app_private_key"].get("required"):
    problems.append("workflow_call accepts a secret other than the required release App private key")
if mint.get("uses") != "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1":
    problems.append("release token action is not at the audited immutable pin")
expected = {
    "client-id": "${{ inputs.release_app_client_id }}",
    "private-key": "${{ secrets.release_app_private_key }}",
    "owner": "${{ github.repository_owner }}",
    "repositories": "${{ github.event.repository.name }}",
    "permission-contents": "write",
}
if mint.get("with") != expected:
    problems.append("release token is not constrained to owner, current repository, and contents-write")
if (checkout.get("with") or {}).get("token") != "${{ steps.release-app-token.outputs.token }}":
    problems.append("release checkout does not persist the short-lived App token")
raw = open(path, encoding="utf-8").read()
if "secrets.push_token" in raw or "ORG_ADMIN_TOKEN" in raw:
    problems.append("release workflow retains the temporary broad push credential")
if problems:
    raise SystemExit("\n".join(problems))
PY
if [ "$?" -eq 0 ]; then
  pass "the release push uses only a current-repository contents-write App token"
else
  fail "the release App token contract is not least-privilege"
fi

client_id_guard="$(awk '
  /^      - name: Require the release App client ID$/ { found = 1; next }
  found && /^      - name:/ { exit }
  found { print }
' "$workflow")"
grep -qF '[[ ! "$RELEASE_APP_CLIENT_ID" =~ ^Iv[A-Za-z0-9]+$ ]]' <<<"$client_id_guard" \
  && pass "the release workflow requires an Iv-prefixed App client ID" \
  || fail "the release workflow does not validate the GitHub App client ID"

client_id_run="$(awk '
  /^      - name: Require the release App client ID$/ { found = 1; next }
  found && /^        run: \|$/ { run = 1; next }
  run && /^      - name:/ { exit }
  run { sub(/^          /, ""); print }
' "$workflow")"
if RELEASE_APP_CLIENT_ID=Iv23liIrniWY27YJKYDP bash -c "$client_id_run" >/dev/null; then
  pass "the release workflow accepts the configured GitHub App client ID"
else
  fail "the release workflow rejects a valid Iv-prefixed App client ID"
fi
for invalid_client_id in '' 4583107; do
  if RELEASE_APP_CLIENT_ID="$invalid_client_id" bash -c "$client_id_run" >/dev/null 2>&1; then
    fail "the release workflow accepts an empty or numeric legacy App ID"
  else
    pass "the release workflow rejects legacy App ID '${invalid_client_id:-<empty>}'"
  fi
done

grep -qF 'git push --atomic origin \' "$workflow" \
  && grep -qF '"$release_commit:refs/heads/$DEFAULT_BRANCH" \' "$workflow" \
  && grep -qF '"refs/tags/$VERSION"' "$workflow" \
  && pass "the release still publishes commit and exact tag atomically" \
  || fail "the atomic commit+tag push shape changed"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
