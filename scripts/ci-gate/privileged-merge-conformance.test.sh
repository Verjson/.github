#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
audit="$root/scripts/privileged-merge-conformance.sh"
generator="$root/scripts/gen-privileged-merge-caller.sh"
workflow="$root/.github/workflows/privileged-merge-conformance.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "api orgs/Verjson/actions/secrets/ORG_ADMIN_TOKEN --jq .visibility")
    printf '%s\n' "${SECRET_VISIBILITY:-selected}"
    ;;
  "api --paginate orgs/Verjson/actions/secrets/ORG_ADMIN_TOKEN/repositories --jq .repositories[].full_name")
    printf '%s\n' "${SECRET_REPOSITORIES:-Verjson/alpha}"
    ;;
  "api --paginate orgs/Verjson/repos?type=all&per_page=100 --jq .[] | select((.archived or .fork or .is_template) | not) | .full_name")
    printf '%s\n' "${ACTIVE_REPOSITORIES:-Verjson/alpha}"
    ;;
  api*"repos/Verjson/alpha/contents/.github/workflows/ai-privileged-merge.yml?ref=main"*"--jq .content")
    case "${ALPHA_CALLER:-present}" in
      present) ;;
      missing) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      unreadable) echo "HTTP 500: unavailable" >&2; exit 1 ;;
    esac
    printf '%s\n' "$ALPHA_CONTENT"
    ;;
  api*"repos/Verjson/beta/contents/.github/workflows/ai-privileged-merge.yml?ref=trunk"*"--jq .content")
    case "${BETA_CALLER:-present}" in
      present) ;;
      missing) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      unreadable) echo "HTTP 500: unavailable" >&2; exit 1 ;;
    esac
    printf '%s\n' "$BETA_CONTENT"
    ;;
  "api repos/Verjson/alpha --jq [.default_branch,.visibility] | @tsv")
    printf '%s\n' $'main\tpublic'
    ;;
  "api repos/Verjson/beta --jq [.default_branch,.visibility] | @tsv")
    printf '%s\n' $'trunk\tprivate'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_audit() {
  local canonical
  canonical="$(bash "$generator" | base64 | tr -d '\n')"
  PATH="$tmp/bin:$PATH" GH_TOKEN="${GH_TOKEN-test-token}" \
    ACTIVE_REPOSITORIES="${ACTIVE_REPOSITORIES-Verjson/alpha}" \
    SECRET_VISIBILITY="${SECRET_VISIBILITY-selected}" \
    SECRET_REPOSITORIES="${SECRET_REPOSITORIES-Verjson/alpha}" \
    ALPHA_CALLER="${ALPHA_CALLER-present}" \
    BETA_CALLER="${BETA_CALLER-present}" \
    ALPHA_CONTENT="${ALPHA_CONTENT-$canonical}" \
    BETA_CONTENT="${BETA_CONTENT-$canonical}" \
    bash "$audit" >"$tmp/out" 2>&1
}

run_audit \
  && grep -q 'result=conformant repositories=1' "$tmp/out" \
  && pass "active managed repository with caller and selected secret access conforms" \
  || fail "conformant repository did not pass"

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  BETA_CALLER=missing run_audit \
  && fail "missing generated caller reported green" \
  || {
    grep -q 'repository=Verjson/beta' "$tmp/out" \
      && grep -q 'scripts/gen-privileged-merge-caller.sh' "$tmp/out" \
      && pass "missing caller fails with repository-scoped generator remediation" \
      || fail "missing caller lacks actionable repository-scoped evidence"
  }

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  BETA_CALLER=unreadable run_audit \
  && fail "unreadable caller state reported green" \
  || {
    grep -q 'Unreadable privileged merge caller' "$tmp/out" \
      && ! grep -q 'gen-privileged-merge-caller.sh' "$tmp/out" \
      && pass "caller API failure is distinct from confirmed absence" \
      || fail "caller API failure was misreported as missing configuration"
  }

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  BETA_CONTENT="$(printf '%s\n' '# obsolete generated caller' | base64 | tr -d '\n')" run_audit \
  && fail "non-canonical generated caller reported green" \
  || {
    grep -q 'Non-canonical privileged merge caller' "$tmp/out" \
      && grep -q 'repository=Verjson/beta' "$tmp/out" \
      && pass "caller content drift fails with repository-scoped regeneration evidence" \
      || fail "caller content drift lacks actionable repository-scoped evidence"
  }

ALPHA_CONTENT='not-base64!' run_audit \
  && fail "undecodable caller content reported green" \
  || {
    grep -q 'Unreadable privileged merge caller' "$tmp/out" \
      && grep -q 'invalid base64 content' "$tmp/out" \
      && pass "undecodable caller content fails closed as unreadable" \
      || fail "undecodable caller content was misclassified: $(<"$tmp/out")"
  }

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_REPOSITORIES=Verjson/alpha run_audit \
  && fail "missing selected-secret access reported green" \
  || {
    grep -q 'repository=Verjson/beta' "$tmp/out" \
      && grep -q 'ORG_ADMIN_TOKEN' "$tmp/out" \
      && pass "missing secret access fails with repository-scoped evidence" \
      || fail "missing secret access lacks actionable repository-scoped evidence"
  }

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_VISIBILITY=all SECRET_REPOSITORIES='' run_audit \
  && grep -q 'result=conformant repositories=2' "$tmp/out" \
  && pass "organization-wide secret visibility admits every active repository" \
  || fail "all-repository secret visibility was not honored"

GH_TOKEN='' run_audit \
  && fail "missing audit credential reported green" \
  || {
    grep -q 'Missing ORG_ADMIN_TOKEN' "$tmp/out" \
      && pass "missing audit credential fails before claiming fleet conformance" \
      || fail "missing audit credential lacks an actionable error"
  }

if python3 - "$workflow" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    document = yaml.safe_load(stream)
on = document.get(True, document.get("on"))
assert set(on) == {"schedule"}
assert document["permissions"] == {"contents": "read"}
job = document["jobs"]["audit"]
assert set(job) == {"runs-on", "timeout-minutes", "steps"}
assert job["runs-on"] == "${{ fromJSON(vars.VERJSON_RUNNER_FASTLANE || '[\"ubuntu-24.04\"]') }}"
assert job["timeout-minutes"] == 10
checkout, audit = job["steps"]
assert checkout["uses"].startswith("actions/checkout@")
assert len(checkout["uses"].split("@", 1)[1]) == 40
assert checkout["with"] == {"ref": "${{ github.sha }}", "persist-credentials": False}
assert audit["env"] == {"GH_TOKEN": "${{ secrets.ORG_ADMIN_TOKEN }}"}
assert audit["run"] == "bash scripts/privileged-merge-conformance.sh"
PY
then
  pass "scheduled fleet audit is event-SHA-bound and exposes only the org token"
else
  fail "scheduled fleet audit is missing or its privileged execution surface drifted"
fi

grep -qF 'run: bash scripts/ci-gate/privileged-merge-conformance.test.sh' \
  "$root/.github/workflows/actions-ci.yml" \
  && pass "fleet conformance contract runs in actions CI" \
  || fail "fleet conformance contract is not wired into actions CI"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
