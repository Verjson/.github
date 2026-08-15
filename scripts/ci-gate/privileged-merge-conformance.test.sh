#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
audit="$root/scripts/privileged-merge-conformance.sh"
generator="$root/scripts/gen-privileged-merge-caller.sh"
workflow="$root/.github/workflows/privileged-merge-conformance.yml"
contract_sha=848c49fd4dac307f26180acd420760a27ceff0ba
alternate_contract_sha=a6b3ccc0590f4fcfdacd7818279ab3eea6b30155
absent_contract_sha=0123456789abcdef0123456789abcdef01234567
audit_sha=abcdef0123456789abcdef0123456789abcdef01
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
  api*"repos/Verjson/.github/contents/.github/workflows/ai-privileged-merge.yml?ref=$PRIVILEGED_MERGE_AUDIT_SHA"*"--jq .content")
    case "${CANONICAL_CALLER:-present}" in
      present) ;;
      missing) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      unreadable) echo "HTTP 500: unavailable" >&2; exit 1 ;;
    esac
    printf '%s\n' "$CANONICAL_CONTENT"
    ;;
  api*"repos/Verjson/.github/compare/"*"...main --jq .status")
    case "$*" in
      *"/0123456789abcdef0123456789abcdef01234567...main"*) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      *) printf '%s\n' "${PIN_RELATION:-ahead}" ;;
    esac
    ;;
  api*"repos/Verjson/.github/contents/scripts/gen-privileged-merge-caller.sh?ref="*"--jq .content")
    printf '%s\n' "$HISTORICAL_GENERATOR_CONTENT"
    ;;
  api*"repos/Verjson/.github/contents/.github/workflows/ai-privileged-merge.yml?ref="*"--jq .content")
    printf '%s\n' "$HISTORICAL_WORKFLOW_CONTENT"
    ;;
  "api repos/Verjson/alpha --jq [.default_branch,.visibility] | @tsv")
    printf '%s\n' $'main\tpublic'
    ;;
  "api repos/Verjson/beta --jq [.default_branch,.visibility] | @tsv")
    printf '%s\n' $'trunk\tprivate'
    ;;
  "api repos/Verjson/.github --jq [.default_branch,.visibility] | @tsv")
    printf '%s\n' $'main\tpublic'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_audit() {
  local canonical historical_workflow
  canonical="$(bash "$generator" "$contract_sha" | base64 | tr -d '\n')"
  historical_workflow="$(printf '%s\n' \
    'on:' \
    '  workflow_call:' \
    '    inputs:' \
    '      privileged_lane:' \
    '        required: false' \
    '        type: string' \
    'jobs:' \
    '  privileged_merge:' \
    '    runs-on: ubuntu-24.04' | base64 | tr -d '\n')"
  PATH="$tmp/bin:$PATH" GH_TOKEN="${GH_TOKEN-test-token}" \
    ACTIVE_REPOSITORIES="${ACTIVE_REPOSITORIES-Verjson/alpha}" \
    SECRET_VISIBILITY="${SECRET_VISIBILITY-selected}" \
    SECRET_REPOSITORIES="${SECRET_REPOSITORIES-Verjson/alpha}" \
    ALPHA_CALLER="${ALPHA_CALLER-present}" \
    BETA_CALLER="${BETA_CALLER-present}" \
    CANONICAL_CALLER="${CANONICAL_CALLER-present}" \
    ALPHA_CONTENT="${ALPHA_CONTENT-$canonical}" \
    BETA_CONTENT="${BETA_CONTENT-$canonical}" \
    CANONICAL_CONTENT="${CANONICAL_CONTENT-$(base64 <"$root/.github/workflows/ai-privileged-merge.yml" | tr -d '\n')}" \
    HISTORICAL_GENERATOR_CONTENT="${HISTORICAL_GENERATOR_CONTENT-$(base64 <"$generator" | tr -d '\n')}" \
    HISTORICAL_WORKFLOW_CONTENT="${HISTORICAL_WORKFLOW_CONTENT-$historical_workflow}" \
    PIN_RELATION="${PIN_RELATION-ahead}" \
    PRIVILEGED_MERGE_AUDIT_SHA="${PRIVILEGED_MERGE_AUDIT_SHA-$audit_sha}" \
    bash "$audit" >"$tmp/out" 2>&1
}

run_audit \
  && grep -q 'result=conformant repositories_scanned=1 consumers=1' "$tmp/out" \
  && pass "active managed repository with caller and selected secret access conforms" \
  || fail "conformant repository did not pass"

ACTIVE_REPOSITORIES=$'Verjson/.github\nVerjson/alpha' \
  SECRET_REPOSITORIES=$'Verjson/.github\nVerjson/alpha' run_audit \
  && grep -q 'result=conformant repositories_scanned=2 consumers=2' "$tmp/out" \
  && pass "canonical direct workflow is inventoried and byte-bound to the audit SHA" \
  || fail "canonical direct consumer was omitted or misclassified"

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/.github \
  CANONICAL_CALLER=missing run_audit \
  && fail "missing canonical direct workflow reported green" \
  || {
    grep -q 'Missing canonical privileged merge workflow' "$tmp/out" \
      && grep -q 'consumers=1' "$tmp/out" \
      && pass "canonical direct workflow is required even when its content API returns 404" \
      || fail "missing canonical direct workflow was treated as a non-consumer"
  }

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/.github \
  CANONICAL_CALLER=unreadable run_audit \
  && fail "unreadable canonical direct workflow reported green" \
  || {
    grep -q 'Unreadable canonical privileged merge workflow' "$tmp/out" \
      && pass "canonical direct workflow API failures fail closed" \
      || fail "unreadable canonical direct workflow was misclassified"
  }

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/.github \
  CANONICAL_CONTENT='not-base64!' run_audit \
  && fail "undecodable canonical direct workflow reported green" \
  || {
    grep -q 'Unreadable canonical privileged merge workflow' "$tmp/out" \
      && pass "undecodable canonical direct workflow fails closed" \
      || fail "undecodable canonical direct workflow was misclassified"
  }

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/.github \
  CANONICAL_CONTENT="$(printf '%s\n' 'name: corrupt direct workflow' | base64 | tr -d '\n')" run_audit \
  && fail "mismatched canonical direct workflow reported green" \
  || {
    grep -q 'Mismatched canonical privileged merge workflow' "$tmp/out" \
      && pass "canonical direct workflow must exactly match the checked-out audit revision" \
      || fail "canonical direct workflow mismatch lacks actionable evidence"
  }

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/alpha run_audit \
  && fail "canonical direct consumer without selected-secret access reported green" \
  || {
    grep -q 'Missing ORG_ADMIN_TOKEN access' "$tmp/out" \
      && grep -q 'repository=Verjson/.github' "$tmp/out" \
      && pass "canonical direct consumer requires selected-secret access evidence" \
      || fail "canonical direct consumer bypassed secret-scope validation"
  }

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  BETA_CALLER=missing run_audit \
  && grep -q 'result=conformant repositories_scanned=2 consumers=1' "$tmp/out" \
  && pass "repositories without a privileged caller are not invented as consumers" \
  || fail "non-consumer repository was treated as a missing caller"

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
  BETA_CONTENT="$(bash "$generator" "$contract_sha" | sed 's/name: AI privileged merge/name: drifted privileged merge/' | base64 | tr -d '\n')" run_audit \
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
  && grep -q 'result=conformant repositories_scanned=2 consumers=2' "$tmp/out" \
  && pass "organization-wide secret visibility admits every active repository" \
  || fail "all-repository secret visibility was not honored"

ALPHA_CONTENT="$(bash "$generator" "$alternate_contract_sha" | base64 | tr -d '\n')" run_audit \
  && grep -q 'result=conformant repositories_scanned=1 consumers=1' "$tmp/out" \
  && pass "caller bytes are canonical for a verified stable immutable pin, not the audit event SHA" \
  || fail "audit incorrectly rebound canonical caller bytes to an unrelated event SHA"

ALPHA_CONTENT="$(bash "$generator" "$absent_contract_sha" | base64 | tr -d '\n')" run_audit \
  && fail "absent 40-hex canonical pin reported green" \
  || {
    grep -q 'Untrusted privileged merge caller pin' "$tmp/out" \
      && pass "caller pin must exist on canonical main history" \
      || fail "absent caller pin lacks canonical-history evidence"
  }

HISTORICAL_WORKFLOW_CONTENT="$(printf '%s\n' 'name: incompatible' | base64 | tr -d '\n')" run_audit \
  && fail "incompatible historical reusable interface reported green" \
  || {
    grep -q 'Incompatible privileged merge contract' "$tmp/out" \
      && pass "caller pin must expose the historical reusable interface" \
      || fail "incompatible caller pin lacks interface evidence"
  }

ALPHA_CONTENT="$(bash "$generator" "$contract_sha" | sed "s/@$contract_sha/@main/" | base64 | tr -d '\n')" run_audit \
  && fail "mutable caller pin reported green" \
  || {
    grep -q 'Invalid privileged merge caller pin' "$tmp/out" \
      && pass "consumer inventory fails closed on a mutable canonical workflow pin" \
      || fail "mutable caller pin lacks actionable evidence"
  }

GH_TOKEN='' run_audit \
  && fail "missing audit credential reported green" \
  || {
    grep -q 'Missing ORG_ADMIN_TOKEN' "$tmp/out" \
      && pass "missing audit credential fails before claiming fleet conformance" \
      || fail "missing audit credential lacks an actionable error"
  }

PRIVILEGED_MERGE_AUDIT_SHA='' run_audit \
  && fail "missing audit SHA reported green" \
  || {
    grep -q 'Invalid privileged merge audit SHA' "$tmp/out" \
      && pass "audit requires a canonical lowercase event SHA" \
      || fail "missing audit SHA lacks an actionable error"
  }

PRIVILEGED_MERGE_AUDIT_SHA="${audit_sha^^}" run_audit \
  && fail "uppercase audit SHA reported green" \
  || {
    grep -q 'Invalid privileged merge audit SHA' "$tmp/out" \
      && pass "audit rejects non-canonical uppercase SHA spelling" \
      || fail "uppercase audit SHA lacks an actionable error"
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
source = ".privileged-merge-conformance-source-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}"
assert set(job) == {"runs-on", "defaults", "timeout-minutes", "steps"}
assert job["runs-on"] == "ubuntu-24.04"
assert job["defaults"] == {"run": {"working-directory": source}}
assert job["timeout-minutes"] == 10
checkout, audit, cleanup = job["steps"]
assert checkout["uses"].startswith("actions/checkout@")
assert len(checkout["uses"].split("@", 1)[1]) == 40
assert checkout["with"] == {
    "ref": "${{ github.sha }}",
    "path": source,
    "persist-credentials": False,
}
assert audit["env"] == {
    "GH_TOKEN": "${{ secrets.ORG_ADMIN_TOKEN }}",
    "PRIVILEGED_MERGE_AUDIT_SHA": "${{ github.sha }}",
}
assert audit["run"] == "bash scripts/privileged-merge-conformance.sh"
assert cleanup["if"] == "${{ always() }}"
assert cleanup["working-directory"] == "${{ github.workspace }}"
assert cleanup["run"] == f'rm -rf "{source}"'
PY
then
  pass "scheduled fleet audit binds code to the event SHA and its privileged token to fixed hosted capacity"
else
  fail "scheduled fleet audit is missing or its privileged execution surface drifted"
fi

grep -q $'\tbash scripts/ci-gate/privileged-merge-conformance.test.sh$' \
  "$root/scripts/actions-ci-groups.tsv" \
  && pass "fleet conformance contract runs in actions CI" \
  || fail "fleet conformance contract is not wired into actions CI"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
