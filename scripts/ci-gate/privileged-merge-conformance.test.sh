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
    bash "$audit" >"$tmp/out" 2>&1
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
