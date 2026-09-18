#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
audit="$root/scripts/privileged-merge-conformance.sh"
# Assigned here, not defaulted at the call site, so an inherited environment value cannot
# redirect the suite at a script the per-call prefix below never chose.
AUDIT_SCRIPT="$audit"
generator="$root/scripts/gen-privileged-merge-caller.sh"
workflow="$root/.github/workflows/privileged-merge-conformance.yml"
contract_sha=848c49fd4dac307f26180acd420760a27ceff0ba
alternate_contract_sha=a6b3ccc0590f4fcfdacd7818279ab3eea6b30155
absent_contract_sha=0123456789abcdef0123456789abcdef01234567
audit_sha=abcdef0123456789abcdef0123456789abcdef01
required_checks='[{"name":"shell-tests","app_id":15368,"workflow_id":315894159,"workflow_path":".github/workflows/actions-ci.yml"}]'
retry_workflow_names='["actions-ci"]'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  "api orgs/Verjson/actions/secrets/MERGE_APP_PRIVATE_KEY --jq .visibility")
    printf '%s\n' "${SECRET_VISIBILITY:-selected}"
    ;;
  "api --paginate orgs/Verjson/actions/secrets/MERGE_APP_PRIVATE_KEY/repositories --jq .repositories[].full_name")
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
  api*"repos/Verjson/alpha/contents/.github/workflows/ai-promotion-retry.yml?ref=main"*"--jq .content")
    [ "${ALPHA_RETRY_CALLER:-present}" = present ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    printf '%s\n' "$ALPHA_RETRY_CONTENT"
    ;;
  api*"repos/Verjson/beta/contents/.github/workflows/ai-privileged-merge.yml?ref=trunk"*"--jq .content")
    case "${BETA_CALLER:-present}" in
      present) ;;
      missing) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      unreadable) echo "HTTP 500: unavailable" >&2; exit 1 ;;
    esac
    printf '%s\n' "$BETA_CONTENT"
    ;;
  api*"repos/Verjson/beta/contents/.github/workflows/ai-promotion-retry.yml?ref=trunk"*"--jq .content")
    [ "${BETA_RETRY_CALLER:-present}" = present ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    printf '%s\n' "$BETA_RETRY_CONTENT"
    ;;
  api*"repos/Verjson/.github/contents/.github/workflows/ai-privileged-merge.yml?ref=$PRIVILEGED_MERGE_AUDIT_SHA"*"--jq .content")
    case "${CANONICAL_CALLER:-present}" in
      present) ;;
      missing) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      unreadable) echo "HTTP 500: unavailable" >&2; exit 1 ;;
    esac
    printf '%s\n' "$CANONICAL_CONTENT"
    ;;
  api*"repos/Verjson/.github/contents/.github/workflows/ai-promotion-retry.yml?ref=$PRIVILEGED_MERGE_AUDIT_SHA"*"--jq .content")
    [ "${CANONICAL_RETRY_CALLER:-present}" = present ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    printf '%s\n' "$CANONICAL_RETRY_CONTENT"
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
  api*"repos/Verjson/.github/contents/.github/workflows/ai-promotion-retry.yml?ref="*"--jq .content")
    printf '%s\n' "$HISTORICAL_RETRY_WORKFLOW_CONTENT"
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
  api*"repos/"*"/rules/branches/"*)
    case "${RULE_BINDING_MODE:-valid}" in
      valid) printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"shell-tests","integration_id":%s}]}}]\n' "${RULE_APP_ID:-15368}" ;;
      missing) printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"shell-tests"}]}}]' ;;
      ambiguous) printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"shell-tests","integration_id":15368},{"context":"shell-tests","integration_id":999}]}}]' ;;
    esac
    ;;
  api*"repos/"*"/actions/workflows/"*"/runs?event=pull_request&per_page=100&page="*)
    page=""
    for arg in "$@"; do [[ "$arg" == *'&page='* ]] && page="${arg##*&page=}"; done
    case "${RUN_SEARCH_MODE:-valid}" in
      valid) printf '%s\n' '{"workflow_runs":[{"id":7002,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed","conclusion":"success"}]}' ;;
      missing) printf '%s\n' '{"workflow_runs":[]}' ;;
      queued-then-completed)
        if [ "$page" = 1 ]; then
          jq -nc '{workflow_runs:[range(0;100) as $i | {id:(8000+$i),head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",status:"queued",conclusion:null}]}'
        else
          printf '%s\n' '{"workflow_runs":[{"id":7002,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed","conclusion":"success"}]}'
        fi ;;
      saturated)
        jq -nc --argjson base "$((page * 1000))" '{workflow_runs:[range(0;100) as $i | {id:($base+$i),head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",status:"queued",conclusion:null}]}' ;;
    esac
    ;;
  api*"repos/"*"/actions/workflows/"*)
    [ "${WORKFLOW_EVIDENCE_MODE:-valid}" != deleted ] || { echo 'HTTP 404: Not Found' >&2; exit 1; }
    printf '{"id":%s,"name":"%s","path":"%s","state":"%s"}\n' \
      "${WORKFLOW_ID:-315894159}" "${WORKFLOW_NAME:-actions-ci}" "${WORKFLOW_PATH:-.github/workflows/actions-ci.yml}" "${WORKFLOW_STATE:-active}"
    ;;
  api*"repos/"*"/actions/runs/7002/jobs?per_page=100"*)
    endpoint=""
    for arg in "$@"; do [[ "$arg" == repos/* ]] && endpoint="$arg"; done
    repository="$(sed -E 's#^repos/([^/]+/[^/]+)/.*#\1#' <<<"$endpoint")"
    if [ "${WORKFLOW_EVIDENCE_MODE:-valid}" = renamed-check ]; then
      printf '%s\n' "{\"jobs\":[{\"id\":8002,\"name\":\"renamed-shell-tests\",\"check_run_url\":\"https://api.github.com/repos/$repository/check-runs/9002\"}]}"
    else
      printf '%s\n' "{\"jobs\":[{\"id\":8002,\"name\":\"shell-tests\",\"check_run_url\":\"https://api.github.com/repos/$repository/check-runs/9002\"}]}"
    fi
    ;;
  api*"https://api.github.com/repos/"*"/check-runs/9002"*)
    printf '{"name":"shell-tests","app":{"id":%s}}\n' "${CHECK_APP_ID:-15368}"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_audit() {
  local canonical canonical_retry historical_workflow historical_retry_workflow
  : >"$tmp/gh-calls"
  canonical="$(bash "$generator" "$contract_sha" "$required_checks" | base64 | tr -d '\n')"
  canonical_retry="$(bash "$generator" "$contract_sha" --retry "$retry_workflow_names" "$required_checks" | base64 | tr -d '\n')"
  historical_workflow="$(printf '%s\n' \
    'on:' \
    '  workflow_call:' \
    '    inputs:' \
    '      required_checks:' \
    '        required: true' \
    '        type: string' \
    '      privileged_lane:' \
    '        required: false' \
    '        type: string' \
    'jobs:' \
    '  privileged_merge:' \
    '    runs-on: ubuntu-24.04' | base64 | tr -d '\n')"
  historical_retry_workflow="$(printf '%s\n' \
    'on:' \
    '  workflow_call:' \
    '    inputs:' \
    '      required_checks:' \
    '        required: true' \
    '        type: string' \
    'jobs:' \
    '  retry:' \
    '    runs-on: ubuntu-24.04' | base64 | tr -d '\n')"
  PATH="$tmp/bin:$PATH" GH_TOKEN="${GH_TOKEN-test-token}" \
    ACTIVE_REPOSITORIES="${ACTIVE_REPOSITORIES-Verjson/alpha}" \
    SECRET_VISIBILITY="${SECRET_VISIBILITY-selected}" \
    SECRET_REPOSITORIES="${SECRET_REPOSITORIES-Verjson/alpha}" \
    ALPHA_CALLER="${ALPHA_CALLER-present}" \
    BETA_CALLER="${BETA_CALLER-present}" \
    CANONICAL_CALLER="${CANONICAL_CALLER-present}" \
    ALPHA_RETRY_CALLER="${ALPHA_RETRY_CALLER-present}" \
    BETA_RETRY_CALLER="${BETA_RETRY_CALLER-present}" \
    CANONICAL_RETRY_CALLER="${CANONICAL_RETRY_CALLER-present}" \
    ALPHA_CONTENT="${ALPHA_CONTENT-$canonical}" \
    BETA_CONTENT="${BETA_CONTENT-$canonical}" \
    CANONICAL_CONTENT="${CANONICAL_CONTENT-$(base64 <"$root/.github/workflows/ai-privileged-merge.yml" | tr -d '\n')}" \
    ALPHA_RETRY_CONTENT="${ALPHA_RETRY_CONTENT-$canonical_retry}" \
    BETA_RETRY_CONTENT="${BETA_RETRY_CONTENT-$canonical_retry}" \
    CANONICAL_RETRY_CONTENT="${CANONICAL_RETRY_CONTENT-$(base64 <"$root/.github/workflows/ai-promotion-retry.yml" | tr -d '\n')}" \
    HISTORICAL_GENERATOR_CONTENT="${HISTORICAL_GENERATOR_CONTENT-$(base64 <"$generator" | tr -d '\n')}" \
    HISTORICAL_WORKFLOW_CONTENT="${HISTORICAL_WORKFLOW_CONTENT-$historical_workflow}" \
    HISTORICAL_RETRY_WORKFLOW_CONTENT="${HISTORICAL_RETRY_WORKFLOW_CONTENT-$historical_retry_workflow}" \
    PIN_RELATION="${PIN_RELATION-ahead}" \
    GH_CALLS="$tmp/gh-calls" \
    WORKFLOW_EVIDENCE_MODE="${WORKFLOW_EVIDENCE_MODE-valid}" \
    RUN_SEARCH_MODE="${RUN_SEARCH_MODE-valid}" \
    RULE_BINDING_MODE="${RULE_BINDING_MODE-valid}" \
    RULE_APP_ID="${RULE_APP_ID-15368}" \
    WORKFLOW_ID="${WORKFLOW_ID-315894159}" \
    WORKFLOW_NAME="${WORKFLOW_NAME-actions-ci}" \
    WORKFLOW_PATH="${WORKFLOW_PATH-.github/workflows/actions-ci.yml}" \
    WORKFLOW_STATE="${WORKFLOW_STATE-active}" \
    CHECK_APP_ID="${CHECK_APP_ID-15368}" \
    PRIVILEGED_MERGE_AUDIT_SHA="${PRIVILEGED_MERGE_AUDIT_SHA-$audit_sha}" \
    bash "$AUDIT_SCRIPT" >"$tmp/out" 2>&1
}

run_audit \
  && grep -q 'result=conformant repositories_scanned=1 consumers=1' "$tmp/out" \
  && pass "active managed repository with caller and selected secret access conforms" \
  || fail "conformant repository did not pass: $(<"$tmp/out")"

ALPHA_RETRY_CALLER=missing run_audit \
  && fail "consumer without a generated promotion retry reported green" \
  || {
    grep -q 'Missing or unreadable generated promotion retry' "$tmp/out" \
      && pass "conformance requires both generated privileged callers" \
      || fail "missing promotion retry lacks conformance evidence"
  }

ALPHA_RETRY_CONTENT="$(bash "$generator" "$contract_sha" --retry "$retry_workflow_names" "$required_checks" | sed 's/name: AI terminal promotion retry/name: drifted retry/' | base64 | tr -d '\n')" run_audit \
  && fail "non-canonical promotion retry reported green" \
  || {
    grep -q 'Non-canonical promotion retry caller' "$tmp/out" \
      && pass "promotion retry bytes are reconstructed with the pinned historical generator" \
      || fail "promotion retry byte drift lacks regeneration evidence"
  }

retry_drift_checks='[{"name":"shell-tests","app_id":15368,"workflow_id":999,"workflow_path":".github/workflows/renamed.yml"}]'
ALPHA_RETRY_CONTENT="$(bash "$generator" "$contract_sha" --retry "$retry_workflow_names" "$retry_drift_checks" | base64 | tr -d '\n')" run_audit \
  && fail "promotion retry with weakened required-check policy reported green" \
  || {
    grep -q 'Promotion retry required-check policy drift' "$tmp/out" \
      && pass "promotion retry cannot substitute or weaken the privileged caller policy" \
      || fail "promotion retry policy substitution was not detected"
  }

ALPHA_RETRY_CONTENT="$(bash "$generator" "$contract_sha" --retry "$retry_workflow_names" "$required_checks" | sed '/^      required_checks:/d' | base64 | tr -d '\n')" run_audit \
  && fail "promotion retry that omitted the required-check policy reported green" \
  || {
    grep -Eq 'Invalid reviewed promotion retry policy|Promotion retry required-check policy drift' "$tmp/out" \
      && pass "promotion retry cannot omit the privileged caller policy" \
      || fail "omitted promotion retry policy was not detected: $(<"$tmp/out")"
  }

ALPHA_RETRY_CONTENT="$(bash "$generator" "$contract_sha" --retry '["renamed-ci"]' "$required_checks" | base64 | tr -d '\n')" run_audit \
  && fail "promotion retry with unrelated workflow names reported green" \
  || {
    grep -q 'Retry workflow names do not match required-check workflow IDs' "$tmp/out" \
      && pass "retry workflow names are bound to the policy workflow IDs" \
      || fail "retry workflow name substitution was not detected"
  }

ALPHA_RETRY_CONTENT="$(bash "$generator" "$alternate_contract_sha" --retry "$retry_workflow_names" "$required_checks" | base64 | tr -d '\n')" run_audit \
  && fail "promotion retry pinned differently from privileged merge reported green" \
  || {
    grep -q 'Invalid promotion retry caller pin' "$tmp/out" \
      && pass "both generated callers must share the exact immutable pin" \
      || fail "promotion retry pin drift was not detected"
  }

RULE_BINDING_MODE=missing run_audit \
  && fail "required status check without an App binding reported green" \
  || {
    grep -q 'lacks an exact App binding' "$tmp/out" \
      && pass "conformance rejects a native required check without integration identity" \
      || fail "missing native App binding lacks conformance evidence"
  }

RULE_APP_ID=999 run_audit \
  && fail "required status check with a mismatched App binding reported green" \
  || {
    grep -q 'does not match effective branch protection' "$tmp/out" \
      && pass "conformance compares required context and App identity together" \
      || fail "mismatched native App binding lacks conformance evidence"
  }

RULE_BINDING_MODE=ambiguous run_audit \
  && fail "same-name required checks with different App identities reported green" \
  || {
    grep -q 'Ambiguous required-check rule identity' "$tmp/out" \
      && pass "conformance preserves multiplicity and rejects ambiguous same-name contexts" \
      || fail "ambiguous native App bindings were collapsed"
  }

RUN_SEARCH_MODE=queued-then-completed run_audit \
  && grep -q 'page=2' "$tmp/gh-calls" \
  && pass "bounded evidence pagination looks past newer queued noise" \
  || fail "completed evidence on a later bounded page was hidden: $(<"$tmp/out") calls=$(tr '\n' ';' <"$tmp/gh-calls")"

RUN_SEARCH_MODE=saturated run_audit \
  && fail "saturated workflow evidence search reported green" \
  || {
    grep -q 'evidence exceeded bound' "$tmp/out" \
      && grep -q 'page=5' "$tmp/gh-calls" \
      && ! grep -q 'page=6' "$tmp/gh-calls" \
      && pass "workflow evidence search fails closed at its explicit page bound" \
      || fail "workflow evidence page bound is missing or bypassable: $(<"$tmp/out") calls=$(tr '\n' ';' <"$tmp/gh-calls")"
  }

ALPHA_CONTENT="$(bash "$generator" "$contract_sha" "$required_checks" | sed '/^      required_checks:/d' | base64 | tr -d '\n')" run_audit \
  && fail "caller without a reviewed required-check policy reported green" \
  || {
    grep -q 'Missing reviewed required-check policy' "$tmp/out" \
      && pass "adoption fails closed when the generated caller omits its reviewed policy" \
      || fail "missing policy lacks adoption-time evidence"
  }

WORKFLOW_EVIDENCE_MODE=renamed-check run_audit \
  && fail "renamed required check reported green" \
  || {
    grep -q 'Missing or renamed required check' "$tmp/out" \
      && pass "conformance rejects a reviewed check name no longer published by its workflow" \
      || fail "renamed check lacks conformance-time evidence"
  }

WORKFLOW_EVIDENCE_MODE=deleted run_audit \
  && fail "deleted required workflow reported green" \
  || {
    grep -q 'Invalid required-check workflow identity' "$tmp/out" \
      && pass "conformance rejects a deleted reviewed workflow" \
      || fail "deleted workflow lacks conformance-time evidence"
  }

wrong_app_checks='[{"name":"shell-tests","app_id":999,"workflow_id":315894159,"workflow_path":".github/workflows/actions-ci.yml"}]'
RULE_APP_ID=999 ALPHA_CONTENT="$(bash "$generator" "$contract_sha" "$wrong_app_checks" | base64 | tr -d '\n')" run_audit \
  && fail "wrong required-check App identity reported green" \
  || {
    grep -q 'Wrong required-check App identity' "$tmp/out" \
      && pass "conformance rejects a required check published by the wrong GitHub App" \
      || fail "wrong App lacks conformance-time evidence"
  }

wrong_workflow_checks='[{"name":"shell-tests","app_id":15368,"workflow_id":999,"workflow_path":".github/workflows/actions-ci.yml"}]'
ALPHA_CONTENT="$(bash "$generator" "$contract_sha" "$wrong_workflow_checks" | base64 | tr -d '\n')" run_audit \
  && fail "wrong required-check workflow ID reported green" \
  || {
    grep -q 'Invalid required-check workflow identity' "$tmp/out" \
      && pass "conformance rejects a wrong repository-specific workflow ID" \
      || fail "wrong workflow ID lacks conformance-time evidence"
  }

wrong_path_checks='[{"name":"shell-tests","app_id":15368,"workflow_id":315894159,"workflow_path":".github/workflows/renamed.yml"}]'
ALPHA_CONTENT="$(bash "$generator" "$contract_sha" "$wrong_path_checks" | base64 | tr -d '\n')" run_audit \
  && fail "wrong required-check workflow path reported green" \
  || {
    grep -q 'Invalid required-check workflow identity' "$tmp/out" \
      && pass "conformance rejects a wrong repository-specific workflow path" \
      || fail "wrong workflow path lacks conformance-time evidence"
  }

ACTIVE_REPOSITORIES=$'Verjson/.github\nVerjson/alpha' \
  SECRET_REPOSITORIES=$'Verjson/.github\nVerjson/alpha' run_audit \
  && grep -q 'result=conformant repositories_scanned=2 consumers=2' "$tmp/out" \
  && pass "canonical direct workflow is inventoried and byte-bound to the audit SHA" \
  || fail "canonical direct consumer was omitted or misclassified"

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/.github \
  CANONICAL_RETRY_CALLER=missing run_audit \
  && fail "missing canonical promotion retry reported green" \
  || {
    grep -q 'Missing or unreadable canonical promotion retry' "$tmp/out" \
      && pass "canonical conformance inventories the promotion retry workflow" \
      || fail "missing canonical promotion retry lacks audit evidence"
  }

ACTIVE_REPOSITORIES=Verjson/.github SECRET_REPOSITORIES=Verjson/.github \
  CANONICAL_RETRY_CONTENT="$(printf '%s\n' 'name: corrupt canonical retry' | base64 | tr -d '\n')" run_audit \
  && fail "mismatched canonical promotion retry reported green" \
  || {
    grep -q 'Mismatched canonical promotion retry' "$tmp/out" \
      && pass "canonical promotion retry bytes are bound to the audit SHA" \
      || fail "canonical promotion retry mismatch lacks audit evidence"
  }

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
    grep -q 'Missing privileged merge App key access' "$tmp/out" \
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
  BETA_CONTENT="$(bash "$generator" "$contract_sha" "$required_checks" | sed 's/name: AI privileged merge/name: drifted privileged merge/' | base64 | tr -d '\n')" run_audit \
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
      && grep -q 'MERGE_APP_PRIVATE_KEY' "$tmp/out" \
      && pass "missing secret access fails with repository-scoped evidence" \
      || fail "missing secret access lacks actionable repository-scoped evidence"
  }

ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta' \
  SECRET_VISIBILITY=all SECRET_REPOSITORIES='' run_audit \
  && grep -q 'result=conformant repositories_scanned=2 consumers=2' "$tmp/out" \
  && pass "organization-wide secret visibility admits every active repository" \
  || fail "all-repository secret visibility was not honored"

ALPHA_CONTENT="$(bash "$generator" "$alternate_contract_sha" "$required_checks" | base64 | tr -d '\n')" \
  ALPHA_RETRY_CONTENT="$(bash "$generator" "$alternate_contract_sha" --retry "$retry_workflow_names" "$required_checks" | base64 | tr -d '\n')" run_audit \
  && grep -q 'result=conformant repositories_scanned=1 consumers=1' "$tmp/out" \
  && pass "caller bytes are canonical for a verified stable immutable pin, not the audit event SHA" \
  || fail "audit incorrectly rebound canonical caller bytes to an unrelated event SHA"

ALPHA_CONTENT="$(bash "$generator" "$absent_contract_sha" "$required_checks" | base64 | tr -d '\n')" run_audit \
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

ALPHA_CONTENT="$(bash "$generator" "$contract_sha" "$required_checks" | sed "s/@$contract_sha/@main/" | base64 | tr -d '\n')" run_audit \
  && fail "mutable caller pin reported green" \
  || {
    grep -q 'Invalid privileged merge caller pin' "$tmp/out" \
      && pass "consumer inventory fails closed on a mutable canonical workflow pin" \
      || fail "mutable caller pin lacks actionable evidence"
  }

# The 40-hex pin guard cannot fire against today's extractor, whose capture group is
# literally ([0-9a-f]{40}) -- the guard exists to survive that extractor changing. Widening
# the capture is exactly that change, and it is the only way to measure the guard's control
# flow rather than describe it. The fixture is ordered: Verjson/alpha populates every
# loop-scoped variable with a conforming value, Verjson/beta then trips the guard, and
# Verjson/.github follows. Each must be judged on its own evidence.
widened_root="$tmp/widened"
widened_audit="$widened_root/scripts/privileged-merge-conformance.sh"
mkdir -p "$widened_root/scripts" "$widened_root/.github/workflows"
ln -sf "$root/.github/workflows/ai-privileged-merge.yml" \
  "$root/.github/workflows/ai-promotion-retry.yml" "$widened_root/.github/workflows/"
sed 's/ai-privileged-merge\\\.yml@(\[0-9a-f\]{40})/ai-privileged-merge\\\.yml@([0-9A-Za-z]+)/' \
  "$audit" >"$widened_audit"
# A test against a mutated copy is only worth anything if the mutation is confined to the
# one line it claims to change, so require exactly one replaced line -- one `<`, one `>`.
widened_changed_lines="$(diff "$audit" "$widened_audit" | grep -c '^[<>]')"
if [ "$widened_changed_lines" -eq 2 ] \
  && grep -q 'ai-privileged-merge\\\.yml@(\[0-9A-Za-z\]+)' "$widened_audit"; then
  pass "pin-extractor widening fixture mutates the caller pin extractor and nothing else"
else
  fail "pin-extractor widening fixture changed $widened_changed_lines line(s) instead of the extractor alone"
fi

mutable_pin_caller="$(bash "$generator" "$contract_sha" "$required_checks" | sed "s/@$contract_sha/@main/" | base64 | tr -d '\n')"
AUDIT_SCRIPT="$widened_audit" \
  ACTIVE_REPOSITORIES=$'Verjson/alpha\nVerjson/beta\nVerjson/.github' \
  SECRET_REPOSITORIES=$'Verjson/alpha\nVerjson/.github' \
  BETA_CONTENT="$mutable_pin_caller" run_audit \
  && fail "non-40-hex caller pin reported green under a widened extractor" \
  || {
    grep -q "pin is not a 40-hex commit SHA" "$tmp/out" \
      && grep -q 'Missing privileged merge App key access::repository=Verjson/beta' "$tmp/out" \
      && ! grep -q 'repository=Verjson/\.github' "$tmp/out" \
      && grep -q 'result=nonconformant repositories_scanned=3 consumers=3' "$tmp/out" \
      && pass "a repository that trips the 40-hex pin guard is still judged on its own secret-access evidence" \
      || fail "the 40-hex pin guard abandoned the repository's remaining evidence: $(<"$tmp/out")"
  }

# The remaining early exits leak loop-scoped state without a reachable read-before-assignment
# today, so no fixture can observe them. Pin the two structural invariants that keep them
# unobservable: the per-repository reset runs before any branch can leave the iteration, and
# it names every variable the iteration assigns. The second is the one #1448 was made of --
# a variable added to the loop and forgotten from the reset list -- and a position-only
# check cannot see it.
if python3 - "$audit" <<'RESET_CONTRACT'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read().splitlines()
opener = 'while IFS= read -r repository; do'
closer = 'done <<<"$repositories"'
assert source.count(opener) == 1, "the fleet loop header is no longer unique"
assert source.count(closer) == 1, "the fleet loop footer is no longer unique"
body = source[source.index(opener) + 1:source.index(closer)]

# Join backslash continuations before anything else looks at the text. The reset statement
# is continuation-joined and the loop already wraps long commands, so a collector that
# reads raw lines would drop every name written past a wrap -- silently, which is the
# failure mode this whole contract exists to prevent.
joined = []
pending = ""
for line in body:
    stripped = line.rstrip()
    if stripped.endswith("\\"):
        pending += stripped[:-1]
        continue
    joined.append(pending + line)
    pending = ""
assert not pending, "the loop body ends inside a line continuation"

# An embedded awk/sed/jq program is a foreign language that happens to spell assignment the
# same way bash does. Match the command in word position -- bare, after `!`, after a pipe,
# or inside `$(`/`<(` -- with any options between it and its opening quote, because the
# loop calls `jq -e '` bare twice and `$(awk '` only once. Anchoring on `$(` would hand
# both jq programs to the bash tokenizer verbatim.
EMBEDDED_CMD = re.compile(r"(?:^|[\s(|&;!])(awk|sed|jq)\b[^'\n]*'")
code = []
inside_embedded = False
carry = ""
for line in joined:
    buffered, rest = carry, line
    carry = ""
    while True:
        if inside_embedded:
            close = rest.find("'")
            if close < 0:
                rest = ""
                break
            inside_embedded = False
            rest = rest[close + 1:]
            continue
        match = EMBEDDED_CMD.search(rest)
        if not match:
            buffered += rest
            break
        # Splice the program out in place rather than emitting the opener's prefix and the
        # closer's remainder as two lines. The region sits inside `"$(...)"`, so cutting it
        # in two leaves each half with an unbalanced quote -- and the tokenizer would then
        # swallow `|| name=1` written just past the closing quote, which is the loop's
        # dominant idiom and a silent false negative.
        buffered += rest[:match.start(1)] + "EMBEDDED_PROGRAM"
        after = rest[match.end():]
        close = after.find("'")
        if close < 0:
            inside_embedded = True
            break
        rest = after[close + 1:]
    if inside_embedded:
        carry = buffered
    else:
        code.append(buffered)
assert not inside_embedded, "an embedded program region was never closed"

# Whole-line comments are prose: neither a `continue` nor an `unset` written in one is
# control flow. Trailing comments are dropped by the tokenizer below.
uncommented = [line for line in code if not line.lstrip().startswith("#")]

# Anchor the reset on being the loop's only top-level `unset` rather than on being the first
# line that happens to start with one, so an unrelated `unset` cannot satisfy this vacuously.
reset_starts = [i for i, line in enumerate(uncommented) if re.match(r"^  unset\s", line)]
assert len(reset_starts) == 1, f"expected exactly one per-repository reset, found {len(reset_starts)}"
reset_at = reset_starts[0]
reset = set(uncommented[reset_at].replace("unset", "", 1).split())
assert reset, "the reset statement named nothing"

exits = [i for i, line in enumerate(uncommented) if re.search(r"\b(?:continue|break)\b", line)]
# The only legitimate pre-reset exit skips a blank inventory line before any state is set.
assert exits and uncommented[exits[0]].strip() == '[ -n "$repository" ] || continue', uncommented[exits[0]]
early = [uncommented[i].strip() for i in exits[1:] if i < reset_at]
assert not early, f"early exits precede the reset: {early}"

# An assignment can sit behind a `case` arm label, a control keyword, a `!`, a pipe, a brace
# group, or a short-circuit after a test -- `has_secret` alone is written three of those
# ways. Strip lead-ins from each segment rather than demanding the name lead the line.
LEADIN = re.compile(r"""^(?:
      (?:if|elif|while|until|then|else|do|done|fi|case|in|esac|time|!
        |command|builtin|env|exec|nohup|stdbuf)$
    | [{}]
    | \[\[?
    | \]\]?
    | [^()\s|=]+\)                                          # a case arm label
  )""", re.X)

# Options that consume the following word, per command. Getting this right is what keeps
# `read -d '' name` and `mapfile -d '' -t name` from losing their variable to an argument.
ARG_TAKING = {
    "mapfile": set("dnOsCcu"),
    "readarray": set("dnOsCcu"),
    "read": set("adinNptu"),
}
# For `read`, the argument of -a is itself a variable being assigned.
NAMES_ITS_ARG = {"read": set("a")}
DECLARATORS = ("declare", "typeset", "export", "readonly", "local")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]]*\])?\+?=")
LET_TARGET = re.compile(r"^[\"']?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+\+|--|[-+*/%&|^]?=)")
# `${name:=default}` and `${name=default}` assign wherever they are expanded, including
# inside double quotes, so they are found on the whole line rather than per word.
ASSIGN_EXPANSION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):?=")
# Arithmetic assigns through `=`, every compound operator, and pre/post increment.
ARITH_TARGET = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+\+|--|(?:[-+*/%&|^]|<<|>>)?=(?!=))")
ARITH_PREFIX = re.compile(r"(?:\+\+|--)\s*([A-Za-z_][A-Za-z0-9_]*)")


def unquote(word):
    """Strip shell quoting from a candidate name. `read -r "brandnew"` names a variable
    exactly as `read -r brandnew` does; leaving the quotes on drops it silently."""
    return re.sub(r"\$?[\"']", "", word)


def segments(line):
    """Split a line into command segments and each segment into words, honoring quotes,
    `$(…)`, `<(…)`, `${…}`, and `((…))` so a separator inside a string or an arithmetic
    header cannot split a token, and dropping an unquoted trailing comment."""
    words, current, out = [], "", []
    quote, depth, index = None, 0, 0

    def flush_word():
        nonlocal current
        if current:
            words.append(current)
            current = ""

    def flush_segment():
        nonlocal words
        flush_word()
        if words:
            out.append(words)
        words = []

    while index < len(line):
        char = line[index]
        pair = line[index:index + 2]
        if quote:
            current += char
            if char == quote and not (quote == '"' and line[index - 1] == "\\"):
                quote = None
            index += 1
            continue
        if char in "'\"":
            quote = char
            current += char
            index += 1
            continue
        if pair in ("$(", "${", "<(", ">("):
            depth += 1
            current += pair
            index += 2
            continue
        if char == "(" and (depth or not current):
            depth += 1
            current += char
            index += 1
            continue
        if depth and char in ")}":
            depth -= 1
            current += char
            index += 1
            continue
        if depth:
            current += char
            index += 1
            continue
        if char == "#" and not current:
            break
        if pair in ("&&", "||"):
            flush_segment()
            index += 2
            continue
        if char in ";|&":
            flush_segment()
            index += 1
            continue
        if char.isspace():
            flush_word()
            index += 1
            continue
        current += char
        index += 1
    flush_segment()
    return out


def arithmetic_names(word):
    """Names assigned inside `((…))`, including a C-style `for` header's three clauses."""
    if not word.startswith("(("):
        return set()
    inner = word[2:]
    if inner.endswith("))"):
        inner = inner[:-2]
    found = set()
    for clause in re.split(r"[,;]", inner):
        found |= set(ARITH_TARGET.findall(clause)) | set(ARITH_PREFIX.findall(clause))
    return found


def names_from_command(words):
    """Variables named by a command rather than by a bare `name=` assignment."""
    command, rest = words[0], words[1:]
    found = set()
    if command == "printf":
        for index, word in enumerate(rest):
            if word == "-v" and index + 1 < len(rest):
                candidate = unquote(rest[index + 1])
                if NAME.match(candidate):
                    found.add(candidate)
        return found
    if command in ("for", "select") and len(rest) >= 2 and rest[1] == "in":
        candidate = unquote(rest[0])
        return {candidate} if NAME.match(candidate) else set()
    if command == "coproc" and rest:
        candidate = unquote(rest[0])
        return {candidate} if NAME.match(candidate) else set()
    if command == "getopts" and len(rest) >= 2:
        candidate = unquote(rest[1])
        return {candidate} if NAME.match(candidate) else set()
    if command == "let":
        for word in rest:
            match = LET_TARGET.match(unquote(word))
            if match:
                found.add(match.group(1))
        return found
    if command in DECLARATORS:
        for word in rest:
            if word.startswith("-"):
                continue
            candidate = unquote(word).split("=", 1)[0].split("[", 1)[0]
            if NAME.match(candidate):
                found.add(candidate)
        return found
    if command not in ARG_TAKING:
        return found
    takes, names_arg = ARG_TAKING[command], NAMES_ITS_ARG.get(command, set())
    index = 0
    while index < len(rest):
        word = rest[index]
        if word.startswith("-") and len(word) > 1:
            cluster = set(word[1:])
            if cluster & takes and index + 1 < len(rest):
                if cluster & names_arg:
                    candidate = unquote(rest[index + 1]).split("[", 1)[0]
                    if NAME.match(candidate):
                        found.add(candidate)
                index += 2
                continue
            index += 1
            continue
        if word.startswith("<") or word.startswith(">"):
            break
        candidate = unquote(word).split("[", 1)[0]
        if NAME.match(candidate):
            found.add(candidate)
        index += 1
    return found


assigned = set()
ifs_sites = []
for line in uncommented:
    assigned |= set(ASSIGN_EXPANSION.findall(line))
    for words in segments(line):
        for word in words:
            assigned |= arithmetic_names(word)
        # `case "$x" in` is three words of scaffolding before the first arm label; on a
        # single-line `case` the arm and its assignment follow on the same segment.
        if words and words[0] == "case":
            while words and words[0] != "in":
                words = words[1:]
        while words and LEADIN.match(words[0]):
            words = words[1:]
        # Leading `NAME=value` words are assignments; more than one may stack, and anything
        # after them is the command they prefix.
        while words:
            match = ASSIGN.match(words[0])
            if not match:
                break
            assigned.add(match.group(1))
            if match.group(1) == "IFS":
                ifs_sites.append((line, len(words) > 1))
            words = words[1:]
        if words:
            assigned |= names_from_command(words)

# Confirmed by reading the script, not inherited from review: these are the only loop-body
# assignments that must survive an iteration. The three counters are fleet totals reported
# after the loop closes.
carried = {"repositories_scanned", "consumers", "failures", "IFS"}
assert carried <= assigned, f"the carry-over list names something the loop never assigns: {sorted(carried - assigned)}"
assert not (reset & carried), f"the reset clears a value the fleet audit must carry: {reset & carried}"
# IFS rides the exemption only as a command prefix, which bash scopes to the single command
# it precedes. A standalone `IFS=,` would be ordinary loop state and must not inherit it.
assert ifs_sites, "IFS is exempted but never assigned; drop the exemption"
for site, is_prefix in ifs_sites:
    assert is_prefix, f"IFS is assigned as loop state, not a command prefix: {site.strip()}"
# `visibility` and `selected_repositories` are assigned before the loop and never inside it,
# so they need no exemption; if that changes, this reddens rather than silently widening.
assert not ({"visibility", "selected_repositories"} & assigned), "fleet-wide state moved into the loop body"

forgotten = assigned - reset - carried
assert not forgotten, f"assigned per repository but never reset: {sorted(forgotten)}"
dead = reset - assigned
assert not dead, f"reset but never assigned in the loop: {sorted(dead)}"
RESET_CONTRACT
then
  pass "the per-repository reset precedes every early exit and names every variable the iteration assigns"
else
  fail "the per-repository reset is mispositioned or has drifted from the loop's assignments"
fi

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
