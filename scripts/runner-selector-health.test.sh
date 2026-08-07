#!/usr/bin/env bash
# Behavioral tests for queued runner-selector health (Verjson/.github#511).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/runner-selector-health.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
path=""
for arg in "$@"; do
  [[ "$arg" == /* || "$arg" == repos/* || "$arg" == orgs/* ]] && path="$arg"
done
[ "${FAIL_PATH:-}" = "$path" ] && exit 1
case "$path" in
  */orgs/TestOrg/repos*|orgs/TestOrg/repos*) cat "$REPOS_FILE" ;;
  */orgs/TestOrg/actions/runner-groups*|orgs/TestOrg/actions/runner-groups*)
    case "$path" in
      */runner-groups/1/runners*) cat "$DEFAULT_RUNNERS_FILE" ;;
      */runner-groups/2/runners*) cat "$ALL_RUNNERS_FILE" ;;
      */runner-groups/3/runners*) cat "$SELECTED_RUNNERS_FILE" ;;
      */runner-groups/3/repositories*) cat "$SELECTED_REPOS_FILE" ;;
      *) cat "$GROUPS_FILE" ;;
    esac
    ;;
  */actions/runs/*/jobs*) cat "$JOBS_FILE" ;;
  */actions/runs?status=queued*) cat "$RUNS_FILE" ;;
  */actions/runs?status=in_progress*) cat "${INPROGRESS_RUNS_FILE:-$RUNS_FILE}" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_detector() (
  export PATH="$tmp/bin:$PATH" ORG=TestOrg NOW_EPOCH=1786111200
  bash "$script" >"$tmp/out.txt" 2>&1
)

cat >"$tmp/repos.json" <<'JSON'
[{"full_name":"TestOrg/alpha","private":true,"archived":false}]
JSON
cat >"$tmp/groups.json" <<'JSON'
{"runner_groups":[
  {"id":1,"name":"Default","default":true,"visibility":"all","allows_public_repositories":true},
  {"id":2,"name":"All","default":false,"visibility":"all","allows_public_repositories":true},
  {"id":3,"name":"Selected","default":false,"visibility":"selected","allows_public_repositories":true}
]}
JSON
cat >"$tmp/runs.json" <<'JSON'
{"workflow_runs":[{"id":41,"name":"CI","created_at":"2026-08-07T13:00:00Z"}]}
JSON
cat >"$tmp/jobs.json" <<'JSON'
{"jobs":[{"id":99,"name":"build","status":"queued","labels":["self-hosted","GCP"]}]}
JSON
printf '{"runners":[]}\n' >"$tmp/default-runners.json"
printf '{"runners":[]}\n' >"$tmp/all-runners.json"
printf '{"runners":[]}\n' >"$tmp/selected-runners.json"
printf '{"repositories":[]}\n' >"$tmp/selected-repos.json"

export REPOS_FILE="$tmp/repos.json" GROUPS_FILE="$tmp/groups.json"
export RUNS_FILE="$tmp/runs.json" JOBS_FILE="$tmp/jobs.json"
export INPROGRESS_RUNS_FILE="$tmp/in-progress-runs.json"
export DEFAULT_RUNNERS_FILE="$tmp/default-runners.json"
export ALL_RUNNERS_FILE="$tmp/all-runners.json"
export SELECTED_RUNNERS_FILE="$tmp/selected-runners.json"
export SELECTED_REPOS_FILE="$tmp/selected-repos.json"
printf '{"workflow_runs":[]}\n' >"$INPROGRESS_RUNS_FILE"

if run_detector; then
  fail "an unsatisfiable selector reported clean"
else
  rc=$?
  { [ "$rc" -eq 1 ] \
    && grep -qF 'TestOrg/alpha run=41 job=99' "$tmp/out.txt" \
    && grep -qF 'labels=["self-hosted","GCP"]' "$tmp/out.txt" \
    && grep -qF 'age_minutes=60' "$tmp/out.txt" \
    && grep -qF 'cause=labels/offline-capacity' "$tmp/out.txt"; } \
    && pass "reports an unsatisfiable selector with identity, labels, age, and cause" \
    || { fail "unsatisfiable selector report is incomplete"; sed 's/^/diag - /' "$tmp/out.txt"; }
fi

cat >"$tmp/selected-runners.json" <<'JSON'
{"runners":[{"id":7,"name":"selected-one","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"general"}]}]}
JSON
cat >"$tmp/jobs.json" <<'JSON'
{"jobs":[{"id":99,"name":"build","status":"queued","labels":["self-hosted","general"]}]}
JSON
if run_detector; then
  fail "a matching runner hidden by selected-group admission reported clean"
else
  { [ "$?" -eq 1 ] && grep -qF 'cause=runner-group-admission' "$tmp/out.txt"; } \
    && pass "distinguishes selected-group admission from label/offline drift" \
    || { fail "selected-group admission cause was not reported"; sed 's/^/diag - /' "$tmp/out.txt"; }
fi

cat >"$tmp/selected-repos.json" <<'JSON'
{"repositories":[{"full_name":"TestOrg/alpha"}]}
JSON
cat >"$tmp/selected-runners.json" <<'JSON'
{"runners":[{"id":7,"name":"selected-one","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"general"}]}]}
JSON
run_detector \
  && pass "a compatible admitted busy runner is capacity pressure, not selector drift" \
  || { fail "busy compatible capacity was reported unsatisfiable"; sed 's/^/diag - /' "$tmp/out.txt"; }

printf '{"repositories":[]}\n' >"$tmp/selected-repos.json"
cat >"$tmp/all-runners.json" <<'JSON'
{"runners":[{"id":8,"name":"all-one","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"general"}]}]}
JSON
run_detector \
  && pass "visibility all admits the requesting repository" \
  || { fail "visibility all was not honored"; sed 's/^/diag - /' "$tmp/out.txt"; }

printf '{"runners":[]}\n' >"$tmp/all-runners.json"
cat >"$tmp/default-runners.json" <<'JSON'
{"runners":[{"id":9,"name":"default-one","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"general"}]}]}
JSON
run_detector \
  && pass "the default runner group is evaluated explicitly" \
  || { fail "default-group capacity was ignored"; sed 's/^/diag - /' "$tmp/out.txt"; }

printf '{"workflow_runs":[]}\n' >"$RUNS_FILE"
cat >"$INPROGRESS_RUNS_FILE" <<'JSON'
{"workflow_runs":[{"id":41,"name":"CI","created_at":"2026-08-07T13:00:00Z"}]}
JSON
printf '{"runners":[]}\n' >"$tmp/default-runners.json"
if run_detector; then
  fail "a queued job inside an in-progress run reported clean"
else
  { [ "$?" -eq 1 ] && grep -qF 'run=41 job=99' "$tmp/out.txt"; } \
    && pass "detects queued jobs inside otherwise in-progress runs" \
    || { fail "in-progress run queue was not inspected"; sed 's/^/diag - /' "$tmp/out.txt"; }
fi

cat >"$INPROGRESS_RUNS_FILE" <<'JSON'
{"workflow_runs":[{"id":41,"name":"CI","created_at":"2026-08-07T14:03:00Z"}]}
JSON
if run_detector; then
  fail "bounded timestamp skew hid an unsatisfiable selector"
else
  { [ "$?" -eq 1 ] && grep -qF 'age_minutes=0' "$tmp/out.txt"; } \
    && pass "bounded API timestamp skew clamps queue age instead of becoming undetermined" \
    || { fail "bounded timestamp skew did not produce a usable report"; sed 's/^/diag - /' "$tmp/out.txt"; }
fi

cat >"$RUNS_FILE" <<'JSON'
{"workflow_runs":[{"id":41,"name":"CI","created_at":"2026-08-07T13:00:00Z"}]}
JSON
printf '{"workflow_runs":[]}\n' >"$INPROGRESS_RUNS_FILE"
cat >"$tmp/default-runners.json" <<'JSON'
{"runners":[{"id":9,"name":"default-one","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"general"}]}]}
JSON

FAIL_PATH="orgs/TestOrg/actions/runner-groups/2/runners?per_page=100" run_detector
rc=$?
{ [ "$rc" -eq 2 ] && grep -qF 'UNDETERMINED' "$tmp/out.txt"; } \
  && pass "unreadable runner-group data fails closed as undetermined" \
  || { fail "unreadable runner data reported a clean org"; sed 's/^/diag - /' "$tmp/out.txt"; }

FAIL_PATH="orgs/TestOrg/actions/runner-groups?per_page=100" run_detector
rc=$?
{ [ "$rc" -eq 2 ] && grep -qF 'UNDETERMINED' "$tmp/out.txt"; } \
  && pass "an unreadable runner-group inventory is undetermined" \
  || { fail "unreadable group inventory reported clean"; sed 's/^/diag - /' "$tmp/out.txt"; }

FAIL_PATH="repos/TestOrg/alpha/actions/runs/41/jobs?per_page=100" run_detector
rc=$?
{ [ "$rc" -eq 2 ] && grep -qF 'UNDETERMINED' "$tmp/out.txt"; } \
  && pass "an unreadable queued-job page is undetermined" \
  || { fail "unreadable job data reported clean"; sed 's/^/diag - /' "$tmp/out.txt"; }

printf '{"message":"truncated page"}\n' >>"$tmp/default-runners.json"
run_detector
rc=$?
{ [ "$rc" -eq 2 ] && grep -qF 'UNDETERMINED' "$tmp/out.txt"; } \
  && pass "partial or malformed pagination never reports the org clean" \
  || { fail "partial pagination reported a clean org"; sed 's/^/diag - /' "$tmp/out.txt"; }

actions_ci="$here/actions-ci-groups.tsv"
grep -q $'\tbash scripts/runner-selector-health.test.sh$' "$actions_ci" \
  && pass "the selector-health suite is wired into actions-ci" \
  || fail "actions-ci does not run the selector-health suite"

{ [ "$(grep -cF 'gh api ' "$script")" -eq 1 ] \
  && grep -qF 'gh api --paginate "$path"' "$script" \
  && ! grep -Eq -- '(^|[[:space:]])(-X|--method)([=[:space:]]|$)|/cancel|/dispatches|registration-token' "$script"; } \
  && pass "all GitHub calls stay behind the report-only GET helper" \
  || fail "selector health gained a GitHub mutation path"

[ "$fails" -eq 0 ] || exit 1
