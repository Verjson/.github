#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

awk '$0=="        id: arm"{f=1} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/arm.sh"
[ -s "$tmp/arm.sh" ] || { echo "FAIL - arm block missing"; exit 1; }
python3 - "$workflow" "$tmp/preauthorize.sh" "$tmp/event-policy.sh" "$root/.github/workflows/ai-review-merge.yml" "$tmp/review-title-policy.sh" <<'PY'
import sys
from pathlib import Path
import yaml

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
event_job = next(i for i, line in enumerate(lines) if line == "  event-policy:")
event_run = next(i for i in range(event_job + 1, len(lines)) if lines[i].strip() == "run: |")
event_body_indent = len(lines[event_run]) - len(lines[event_run].lstrip()) + 2
event_end = next(i for i in range(event_run + 1, len(lines)) if lines[i] == "  app-key-policy:")
Path(sys.argv[3]).write_text("\n".join(line[event_body_indent:] for line in lines[event_run + 1:event_end]) + "\n", encoding="utf-8")
review = yaml.safe_load(Path(sys.argv[4]).read_text(encoding="utf-8"))
Path(sys.argv[5]).write_text(review["jobs"]["title-policy"]["steps"][0]["run"], encoding="utf-8")
step_name = "- name: Authorize hold-clearing actor before App token mint"
start = next(i for i, line in enumerate(lines) if line.strip() == step_name)
step_indent = len(lines[start]) - len(lines[start].lstrip())
run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
body_indent = len(lines[run]) - len(lines[run].lstrip()) + 2
end = next((i for i in range(run + 1, len(lines)) if lines[i].strip().startswith("- name:") and len(lines[i]) - len(lines[i].lstrip()) == step_indent), len(lines))
Path(sys.argv[2]).write_text("\n".join(line[body_indent:] for line in lines[run + 1:end]) + "\n", encoding="utf-8")
PY
[ -s "$tmp/preauthorize.sh" ] || { echo "FAIL - hold-clearing authorization step missing"; exit 1; }
awk '$0=="      - name: Complete the authorization when no review was dispatched"{f=1} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/terminalize.sh"
[ -s "$tmp/terminalize.sh" ] || { echo "FAIL - authorization terminalizer missing"; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "api /installation")
    # Installation tokens receive 404 from this endpoint in production.
    exit 22 ;;
  "pr view "*)
    [ "${GH_VIEW_FAIL:-false}" != true ] || exit 1
    count="$(grep -c '^pr view ' "$CALLS")"
    if [ "$count" -eq 1 ]; then cat "$META_FILE"; else cat "$DISABLED_META_FILE"; fi ;;
  "api graphql "*) cat "$GRAPHQL_FILE" ;;
  *"commits/"*"/check-runs "*) cat "$LATEST_FILE" ;;
  *"actions/runs/7001 --jq"*) printf '2\n' ;;
  *"actions/runs/7001") printf '{"event":"pull_request_target","path":".github/workflows/gate-rearm.yml","head_repository":{"full_name":"Verjson/example"},"run_attempt":2}\n' ;;
  *"actions/runs/8000") printf '{"event":"pull_request_target","path":".github/workflows/ai-review-label-rearm.yml","run_attempt":1,"head_sha":"0123456789abcdef0123456789abcdef01234567","head_repository":{"full_name":"Verjson/example"},"repository":{"id":1234},"actor":{"login":"maintainer"}}\n' ;;
  *"actions/runs/7001/artifacts?per_page=100 --jq"*) printf '%s\n' "${RECEIPT_COUNT:-1}" ;;
  "run download 7001 "*)
    for arg in "$@"; do destination="$arg"; done
    mkdir -p "$destination"
    printf '{"review_policy":"%s"}\n' "$RECEIPT_POLICY" >"$destination/receipt.json" ;;
  *"collaborators/"*"/permission"*)
    [ "${GH_PERMISSION_FAIL:-false}" != true ] || exit 1
    queried_actor="${2#*/collaborators/}"
    queried_actor="${queried_actor%/permission}"
    if [ "$queried_actor" = "${PRIVILEGED_ACTOR:-other-admin}" ]; then
      role_name="${PRIVILEGED_ACTOR_ROLE_NAME:-admin}"
      base_permission="${PRIVILEGED_ACTOR_BASE_PERMISSION:-admin}"
    elif [ "$queried_actor" = "$REQUEST_ACTOR" ]; then
      role_name="${ACTOR_ROLE_NAME:-${ACTOR_PERMISSION:-triage}}"
      case "$role_name" in
        admin) base_permission=admin ;;
        maintain|write|push) base_permission=write ;;
        triage|read) base_permission=read ;;
        *) base_permission=none ;;
      esac
      base_permission="${ACTOR_BASE_PERMISSION:-$base_permission}"
    else
      role_name=none
      base_permission=none
    fi
    printf 'PERMISSION_LOOKUP %s permission=%s role_name=%s\n' \
      "$queried_actor" "$base_permission" "$role_name" >>"$CALLS"
    if [ "${3:-}" = --jq ]; then
      case "${4:-}" in
        '.permission // ""') printf '%s\n' "$base_permission" ;;
        '.role_name // ""') printf '%s\n' "$role_name" ;;
        *) echo "unexpected permission projection: ${4:-}" >&2; exit 2 ;;
      esac
    else
      jq -cn --arg permission "$base_permission" --arg role_name "$role_name" \
        '{permission:$permission,role_name:$role_name}'
    fi ;;
  *"issues/7/events?per_page=100"*) printf '[{"id":1,"event":"labeled","label":{"name":"ai-review"},"actor":{"login":"maintainer"}},{"id":2,"event":"labeled","label":{"name":"re-review"},"actor":{"login":"maintainer"}}]\n' ;;
  *"contents/.github/workflows/ai-review-merge.yml?ref=main"*) cat "$CALLER_FILE" ;;
  *"--method POST repos/Verjson/example/check-runs --input -"*)
    jq --argjson app_id "${CREATED_CHECK_APP_ID:-4242}" \
      '. + {id:9100,app:{id:$app_id,slug:"verjson-ai-review"}}' ;;
  *"repos/Verjson/example/check-runs/9100 --jq"*) printf 'in_progress\n' ;;
  *"--method PATCH repos/Verjson/example/check-runs/9100 "*) printf '{}\n' ;;
  "workflow run "*) printf 'DISPATCH %s\n' "$*" >>"$CALLS" ;;
  "pr comment "*) printf 'COMMENT %s\n' "$*" >>"$CALLS" ;;
  "pr edit "*) [ "${PR_EDIT_FAIL:-false}" != true ] ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" META_FILE="$tmp/meta.json"
export PRIVILEGED_ACTOR=other-admin PRIVILEGED_ACTOR_ROLE_NAME=admin PRIVILEGED_ACTOR_BASE_PERMISSION=admin
export DISABLED_META_FILE="$tmp/disabled.json" GRAPHQL_FILE="$tmp/graphql.json" LATEST_FILE="$tmp/latest.json"
export TARGET_REPO=Verjson/example PR_NUMBER=7 APP_ID=4242 APP_SLUG=verjson-ai-review
export MINTED_APP_SLUG="$APP_SLUG"
export DEFAULT_BRANCH=main EVENT_LABEL=hold EVENT_OLD_TITLE_HELD=false GITHUB_REPOSITORY_OWNER=Verjson
export EVENT_NAME=pull_request_target REPOSITORY_ID=1234
export REQUEST_ACTOR=maintainer
export WORKFLOW_REF=Verjson/example/.github/workflows/ai-review-label-rearm.yml@refs/heads/main
export WORKFLOW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export EVENT_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=''
export GITHUB_ENV="$tmp/github-env"
export ACTIONS_TOKEN=actions-token GH_TOKEN=app-token GITHUB_SERVER_URL=https://github.com
export GITHUB_RUN_ID=8000 GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$tmp"
export GITHUB_OUTPUT="$tmp/github-output"
CALLER_FILE="$tmp/current-caller.yml"
cp "$root/scripts/ci-gate/fixtures/ai-review-caller-a6b3ccc.yml" "$CALLER_FILE"
printf '# current schema caller\n' >>"$CALLER_FILE"
export CALLER_FILE
receipt_policy='eyJhY3RvciI6Im1haW50YWluZXIiLCJhY3Rvcl9wZXJtaXNzaW9uIjoibWFpbnRhaW4iLCJidWRnZXRfdXNkIjoiMS4wMCIsIm1vZGVsIjoiZ3B0LTUuNi1sdW5hIiwicHJpY2luZ192ZXJzaW9uIjoib3BlbmFpLWx1bmEtbG9uZy1jb250ZXh0LTIwMjYtMDgtMDgiLCJwcm92aWRlciI6Im9wZW5haSJ9'
substitute_policy='eyJhY3RvciI6InRydXN0ZWQtYXJtIiwiYWN0b3JfcGVybWlzc2lvbiI6ImF1dG9tYXRpb24iLCJidWRnZXRfdXNkIjoiYXV0byIsIm1vZGVsIjoiYXV0byIsInByaWNpbmdfdmVyc2lvbiI6ImFudGhyb3BpYy1uYXRpdmUtdjEiLCJwcm92aWRlciI6ImFudGhyb3BpYyJ9'
export RECEIPT_POLICY="$receipt_policy"
head_sha=0123456789abcdef0123456789abcdef01234567

write_hold() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"hold"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:{enabledAt:"now"}}' >"$META_FILE"
  printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"PR_id"}}}}\n' >"$GRAPHQL_FILE"
  printf '{"id":"PR_id","autoMergeRequest":null}\n' >"$DISABLED_META_FILE"
  export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize
}
run_arm(){
  local caller=ai-review-label-rearm.yml
  case "$EVENT_ACTION" in opened|reopened|synchronize) caller=gate-rearm.yml ;; esac
  WORKFLOW_REF="Verjson/example/.github/workflows/$caller@refs/heads/main" bash "${ARM_SCRIPT:-$tmp/arm.sh}"
}
expect_fail(){ label="$1"; if run_arm >"$tmp/out" 2>&1; then fail "$label"; else pass "$label"; fi; }
run_preauthorize(){ bash "$tmp/preauthorize.sh"; }

if python3 - "$workflow" <<'PY'
import sys
from pathlib import Path

import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = workflow["jobs"]
steps = jobs["arm"]["steps"]
preauthorize = next(i for i, step in enumerate(steps) if step.get("name") == "Authorize hold-clearing actor before App token mint")
mint = next(i for i, step in enumerate(steps) if step.get("name") == "Mint dedicated authorization App token")
assert preauthorize < mint, "actor authorization must precede App-token mint"
assert "admin|maintain" in steps[preauthorize]["run"]
assert "role_name" in steps[preauthorize]["run"]
assert "github.event.action == 'unlabeled'" in steps[preauthorize]["if"]
assert "github.event.action == 'labeled'" in steps[preauthorize]["if"]

event_policy = jobs["event-policy"]
assert event_policy["permissions"] == {}
assert "vars.CI_LANE_UNTRUSTED" in event_policy["runs-on"]
assert 'gsub("[ _-]+";" ")' in event_policy["steps"][0]["run"]
assert 'gsub("[ _-]+";"-")' in event_policy["steps"][0]["run"]
assert jobs["app-key-policy"]["needs"] == "event-policy"
assert "needs.event-policy.outputs.run_control_plane == 'true'" in jobs["app-key-policy"]["if"]
assert jobs["arm"]["needs"] == ["event-policy", "app-key-policy"]
assert "needs.event-policy.outputs.run_control_plane == 'true'" in jobs["arm"]["if"]

assert jobs["app-key-policy"]["if"] == "${{ needs.event-policy.outputs.run_control_plane == 'true' }}"
assert jobs["arm"]["if"] == "${{ needs.event-policy.outputs.run_control_plane == 'true' && needs.app-key-policy.result == 'success' }}"
assert "old_title_held" in jobs["event-policy"]["outputs"]
assert "new_title_held" in jobs["event-policy"]["outputs"]
assert "EVENT_TITLE_CHANGED" in jobs["event-policy"]["steps"][0]["env"]
marker = r"(^|[^ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_])DO\ NOT\ MERGE([^ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]|$)"
assert marker in jobs["event-policy"]["steps"][0]["run"]
review_jobs = yaml.safe_load(Path(sys.argv[1]).with_name("ai-review-merge.yml").read_text())["jobs"]
assert review_jobs["title-policy"]["permissions"] == {}
assert review_jobs["preflight"]["needs"] == "title-policy"
assert "needs.title-policy.outputs.title_held != 'true'" in review_jobs["preflight"]["if"]
assert marker in review_jobs["title-policy"]["steps"][0]["run"]
for filename in ("ai-review-merge.yml", "ai-privileged-merge.yml", "gate-rearm.yml"):
    source = Path(sys.argv[1]).with_name(filename).read_text()
    assert 'ascii_upcase | test("(^|[^ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_])DO NOT MERGE([^ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]|$)")' in source
print("workflow title-hold policy and authorization ordering pass")
PY
then
  pass "only actual title-hold transitions reach the trusted arm and token steps"
else
  fail "workflow hold-removal entry gates are incomplete"
fi

classify_control_plane() {
  : >"$GITHUB_OUTPUT"
  EVENT_ACTION="$1" EVENT_LABEL="$2" EVENT_TITLE_CHANGED="${3:-false}" \
    EVENT_OLD_TITLE="${4:-}" EVENT_NEW_TITLE="${5:-}" GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    bash "$tmp/event-policy.sh"
  sed -n 's/^run_control_plane=//p' "$GITHUB_OUTPUT"
}
for label in hold HOLD 'Do__Not--Merge'; do
  if [ "$(classify_control_plane unlabeled "$label")" = true ]; then
    pass "recognized removed hold label $label keeps the trusted control plane eligible"
  else
    fail "recognized removed hold label $label was filtered out"
  fi
done
if [ "$(classify_control_plane unlabeled documentation)" = false ] \
  && [ "$(classify_control_plane edited documentation)" = false ] \
  && [ "$(classify_control_plane opened documentation)" = true ]; then
  pass "unrelated unlabeled and body-only edits skip protected jobs while normal actions remain eligible"
else
  fail "event policy did not isolate unrelated labels and title-free edits"
fi
if [ "$(classify_control_plane edited '' true 'REDO NOT MERGE: QA' 'ordinary title')" = false ] \
  && [ "$(classify_control_plane edited '' true 'DO NOT MERGER: QA' 'ordinary title')" = false ] \
  && [ "$(classify_control_plane edited '' true 'ordinary title' 'prefix DO NOT MERGE: hold')" = true ] \
  && [ "$(classify_control_plane edited '' true 'ordinary title' 'DO NOT MERGEK')" = true ] \
  && [ "$(classify_control_plane edited '' true 'DO NOT MERGE: hold' 'ordinary title')" = true ]; then
  pass "event policy detects only whole-phrase title hold transitions"
else
  fail "event policy title marker boundaries are incorrect"
fi

review_title_held() {
  : >"$GITHUB_OUTPUT"
  PR_TITLE="$1" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$tmp/review-title-policy.sh"
  sed -n 's/^title_held=//p' "$GITHUB_OUTPUT"
}
if [ "$(review_title_held 'chore: dO nOt mErGe: QA')" = true ] \
  && [ "$(review_title_held 'REDO NOT MERGE: QA')" = false ] \
  && [ "$(review_title_held 'DO NOT MERGER: QA')" = false ] \
  && [ "$(review_title_held 'DO_NOT_MERGE')" = false ] \
  && [ "$(review_title_held 'DO NOT MERGEK')" = true ]; then
  pass "review preflight treats the hold marker as a whole phrase"
else
  fail "review preflight title marker boundaries are incorrect"
fi
for label in ai-review re-review hold 'Do__Not--Merge'; do
  if [ "$(classify_control_plane labeled "$label")" = true ]; then
    pass "recognized added label $label retains its existing workflow path"
  else
    fail "recognized added label $label was filtered out"
  fi
done
if [ "$(classify_control_plane labeled documentation)" = false ]; then
  pass "unrelated label additions skip protected jobs before App-token mint"
else
  fail "unrelated label addition reached protected jobs"
fi

export EVENT_ACTION=ready_for_review EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false REQUEST_ACTOR=maintainer
: >"$CALLS"
for permission in read triage write push; do
  : >"$GITHUB_ENV"
  export ACTOR_PERMISSION="$permission"
  if run_preauthorize >"$tmp/out" 2>&1; then
    fail "$permission actor cleared a draft hold"
  elif grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS"; then
    fail "$permission actor reached privileged dispatch"
  else
    pass "$permission actor is rejected before App-token mint"
  fi
done

for permission in maintain admin; do
  : >"$GITHUB_ENV"
  : >"$CALLS"
  export ACTOR_PERMISSION="$permission"
  if [ "$permission" = maintain ]; then base_permission=write; else base_permission=admin; fi
  if run_preauthorize >"$tmp/out" 2>&1 \
    && grep -q "^HOLD_CLEAR_ACTOR_PERMISSION=$permission$" "$GITHUB_ENV" \
    && grep -q "^PERMISSION_LOOKUP maintainer permission=$base_permission role_name=$permission$" "$CALLS"; then
    pass "$permission actor is authorized to clear a draft hold"
  else
    fail "$permission actor could not clear a draft hold"
  fi
done

export ACTOR_PERMISSION=maintain GH_PERMISSION_FAIL=true
if run_preauthorize >"$tmp/out" 2>&1; then
  fail "permission API failure cleared a draft hold"
elif grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS"; then
  fail "permission API failure reached privileged dispatch"
else
  pass "permission API failure remains fail-closed before App-token mint"
fi
unset GH_PERMISSION_FAIL

export EVENT_ACTION=unlabeled EVENT_LABEL=hold ACTOR_PERMISSION=triage
: >"$GITHUB_ENV"
: >"$CALLS"
if run_preauthorize >"$tmp/out" 2>&1; then
  fail "triage actor cleared a hold label"
elif grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS"; then
  fail "triage actor reached privileged dispatch after removing a hold label"
else
  pass "triage actor is denied hold-label removal before App-token mint"
fi

for label in hold 'Do__Not--Merge'; do
  for permission in maintain admin; do
    : >"$GITHUB_ENV"
    export ACTOR_PERMISSION="$permission" EVENT_LABEL="$label"
    if run_preauthorize >"$tmp/out" 2>&1 && grep -q "^HOLD_CLEAR_ACTOR_PERMISSION=$permission$" "$GITHUB_ENV"; then
      pass "$permission actor can clear recognized hold label $label"
    else
      fail "$permission actor could not clear recognized hold label $label"
    fi
  done
done

export EVENT_LABEL=documentation ACTOR_PERMISSION=triage
: >"$GITHUB_ENV"
: >"$CALLS"
if run_preauthorize >"$tmp/out" 2>&1 && [ ! -s "$GITHUB_ENV" ] && ! grep -q 'collaborators/' "$CALLS"; then
  pass "non-hold label removal skips hold authorization lookup"
else
  fail "non-hold label removal changed its authorization behavior"
fi

export EVENT_LABEL=hold ACTOR_PERMISSION=maintain GH_PERMISSION_FAIL=true
if run_preauthorize >"$tmp/out" 2>&1; then
  fail "permission API failure allowed hold-label removal"
elif grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS"; then
  fail "permission API failure reached privileged dispatch for hold-label removal"
else
  pass "hold-label permission API failure fails closed before App-token mint"
fi
unset GH_PERMISSION_FAIL

export EVENT_ACTION=edited EVENT_OLD_TITLE_HELD=true EVENT_NEW_TITLE_HELD=false
export REQUEST_ACTOR=pr-author PRIVILEGED_ACTOR=other-admin ACTOR_PERMISSION=triage
for permission in triage write; do
  : >"$GITHUB_ENV"
  : >"$CALLS"
  export ACTOR_PERMISSION="$permission"
  if run_preauthorize >"$tmp/out" 2>&1; then
    fail "$permission actor removed a title hold"
  elif ! grep -q "^PERMISSION_LOOKUP pr-author permission=" "$CALLS" \
      || grep -q '^PERMISSION_LOOKUP other-admin ' "$CALLS" \
      || grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS" \
      || [ -s "$GITHUB_ENV" ]; then
    fail "$permission title-hold removal did not fail before token mint for the event actor"
  else
    pass "$permission event actor is checked by login and denied title-hold removal before App-token mint"
  fi
done

export REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain
: >"$GITHUB_ENV"
: >"$CALLS"
if run_preauthorize >"$tmp/out" 2>&1 && grep -q '^HOLD_CLEAR_ACTOR_PERMISSION=maintain$' "$GITHUB_ENV"; then
  pass "a maintainer can clear an existing title hold"
else
  fail "a real title-hold removal was not authorized"
fi

for label in ai-review re-review; do
  export EVENT_ACTION=labeled EVENT_LABEL="$label" REQUEST_ACTOR=pr-author
  for permission in triage write; do
    : >"$GITHUB_ENV"
    : >"$CALLS"
    export ACTOR_PERMISSION="$permission"
    if run_preauthorize >"$tmp/out" 2>&1; then
      fail "$permission actor added $label label"
    elif ! grep -q "^PERMISSION_LOOKUP pr-author permission=" "$CALLS" \
        || grep -q '^PERMISSION_LOOKUP other-admin ' "$CALLS" \
        || grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS" \
        || [ -s "$GITHUB_ENV" ]; then
      fail "$permission $label actor was not rejected before App-token mint"
    else
      pass "$permission actor rejected for $label before App-token mint"
    fi
  done
  export REQUEST_ACTOR=maintainer
  for permission in maintain admin; do
    : >"$GITHUB_ENV"
    : >"$CALLS"
    export ACTOR_PERMISSION="$permission"
    if run_preauthorize >"$tmp/out" 2>&1 \
      && grep -q "^PERMISSION_LOOKUP maintainer permission=" "$CALLS" \
      && grep -q "role_name=$permission$" "$CALLS"; then
      pass "$permission actor authorized for $label before App-token mint"
    else
      fail "$permission actor could not authorize $label before App-token mint"
    fi
  done
done

export EVENT_ACTION=edited REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain
title_is_held() {
  [[ "${1^^}" =~ (^|[^ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_])DO\ NOT\ MERGE([^ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]|$) ]]
}
for old_title in 'chore: DO NOT MERGE QA' 'chore: QA' 'REDO NOT MERGE QA' 'DO NOT MERGER QA'; do
  for new_title in 'chore: DO NOT MERGE QA' 'chore: new title' 'REDO NOT MERGE QA' 'DO NOT MERGER QA'; do
    old_held=false; new_held=false
    title_is_held "$old_title" && old_held=true
    title_is_held "$new_title" && new_held=true
    [ "$old_held" = "$new_held" ] || continue
    export EVENT_OLD_TITLE_HELD="$old_held" EVENT_NEW_TITLE_HELD="$new_held"
    if run_preauthorize >"$tmp/out" 2>&1; then
      fail "non-clearing title edit was authorized: $old_title -> $new_title"
    else
      pass "title edit without a hold-state transition is rejected before App-token mint"
    fi
  done
done

export EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=true
: >"$GITHUB_ENV"
: >"$CALLS"
if run_preauthorize >"$tmp/out" 2>&1 && [ ! -s "$GITHUB_ENV" ] && ! grep -q 'collaborators/' "$CALLS"; then
  pass "adding a mixed-case title hold skips hold-removal authorization"
else
  fail "adding a title hold attempted hold-removal authorization"
fi

write_hold
jq '.labels=[] | .title="DO NOT MERGE: hold"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export EVENT_ACTION=edited EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=true EVENT_LABEL=''
export REQUEST_ACTOR=maintainer ACTOR_PERMISSION=triage
: >"$CALLS"
if run_arm >"$tmp/out" 2>&1 \
  && grep -q 'disablePullRequestAutoMerge' "$CALLS" \
  && ! grep -q 'collaborators/\|workflow run' "$CALLS"; then
  pass "adding a title hold disables auto-merge without hold-clear authorization"
else
  fail "adding a title hold did not disable auto-merge safely"
fi

write_hold
export EVENT_ACTION=labeled EVENT_LABEL=hold
if run_arm >"$tmp/out" 2>&1 \
  && grep -q 'disablePullRequestAutoMerge' "$CALLS" \
  && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "adding a lowercase hold label disables auto-merge without review dispatch"
else
  fail "adding a lowercase hold label did not disable auto-merge"
fi

write_hold
MINTED_APP_SLUG=renamed-app
if run_arm >"$tmp/out" 2>&1; then
  fail "minted App slug mismatch was accepted"
elif grep -q "AI review authorization App slug mismatch" "$tmp/out" \
  && ! grep -q -- '--method POST repos/Verjson/example/check-runs' "$CALLS"; then
  pass "minted App slug mismatch fails loudly before authorization creation"
else
  fail "minted App slug mismatch did not fail before authorization creation"
fi
MINTED_APP_SLUG="$APP_SLUG"
write_hold
MINTED_APP_SLUG=''
if run_arm >"$tmp/out" 2>&1; then
  fail "missing token-action App slug was accepted"
elif grep -q "AI review authorization App slug mismatch" "$tmp/out" \
  && ! grep -q -- '--method POST repos/Verjson/example/check-runs' "$CALLS"; then
  pass "missing token-action App slug fails before authorization creation"
else
  fail "missing token-action App slug did not fail before authorization creation"
fi
write_hold
MINTED_APP_SLUG='Invalid_Slug'
if run_arm >"$tmp/out" 2>&1; then
  fail "malformed token-action App slug was accepted"
elif grep -q "AI review authorization App slug mismatch" "$tmp/out" \
  && ! grep -q -- '--method POST repos/Verjson/example/check-runs' "$CALLS"; then
  pass "malformed token-action App slug fails before authorization creation"
else
  fail "malformed token-action App slug did not fail before authorization creation"
fi
MINTED_APP_SLUG="$APP_SLUG"
write_hold
if run_arm >"$tmp/out" 2>&1 && ! grep -q '^api /installation$' "$CALLS"; then
  pass "legitimate token-action slug proceeds without the inaccessible installation endpoint"
else
  fail "legitimate token-action slug attempted the production-404 installation endpoint"
fi
write_hold; printf '{"data":null,"errors":[{"message":"denied"}]}\n' >"$GRAPHQL_FILE"
expect_fail "HTTP-200 GraphQL errors fail the hold closed"
write_hold; printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"wrong"}}}}\n' >"$GRAPHQL_FILE"
expect_fail "a mutation response for another PR fails closed"
write_hold; printf '{"id":"PR_id","autoMergeRequest":{"enabledAt":"still-on"}}\n' >"$DISABLED_META_FILE"
expect_fail "auto-merge remaining enabled after mutation fails closed"

write_terminal_hold() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" \
    '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' \
    >"$META_FILE"
  export EVENT_ACTION=synchronize EVENT_LABEL='' EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false
}

app_id_mismatch_is_terminalized() {
  local arm_script="$1" check_id
  write_terminal_hold
  : >"$GITHUB_OUTPUT"
  printf '{}\n' >"$LATEST_FILE"
  if CREATED_CHECK_APP_ID=9999 ARM_SCRIPT="$arm_script" run_arm >"$tmp/out" 2>&1; then
    return 1
  fi
  check_id="$(sed -n 's/^check_id=//p' "$GITHUB_OUTPUT")"
  [ "$check_id" = 9100 ] || return 1
  CHECK_ID="$check_id" APP_TOKEN=app-token bash "$tmp/terminalize.sh" >"$tmp/terminalize.out" 2>&1 || return 1
  grep -q -- '--method PATCH repos/Verjson/example/check-runs/9100' "$CALLS" \
    && grep -q 'status=completed' "$CALLS" \
    && grep -q 'conclusion=failure' "$CALLS" \
    && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS" \
    && [ ! -e "$RUNNER_TEMP/ai-review-arm-receipt/receipt.json" ]
}

if app_id_mismatch_is_terminalized "$tmp/arm.sh"; then
  pass "a post-creation App-ID mismatch is completed as failure"
else
  fail "a post-creation App-ID mismatch stranded its authorization check"
fi

sed '/echo "check_id=\$check_id" >>"\$GITHUB_OUTPUT"/d' "$tmp/arm.sh" >"$tmp/arm-no-early-check-id.sh"
if app_id_mismatch_is_terminalized "$tmp/arm-no-early-check-id.sh"; then
  fail "removing the early check-ID export escaped the terminal-state mutation test"
else
  pass "the terminal-state mutation test detects removal of the early check-ID export"
fi

for signal in do-not-merge-label do_not_merge-label title draft; do
  write_terminal_hold
  case "$signal" in
    do-not-merge-label) jq '.labels=[{"name":"do-not-merge"}]' "$META_FILE" >"$tmp/x" ;;
    do_not_merge-label) jq '.labels=[{"name":"Do_Not_Merge"}]' "$META_FILE" >"$tmp/x" ;;
    title) jq '.title="chore: DO NOT MERGE until QA"' "$META_FILE" >"$tmp/x" ;;
    draft) jq '.isDraft=true' "$META_FILE" >"$tmp/x" ;;
  esac
  mv "$tmp/x" "$META_FILE"
  if run_arm >"$tmp/out" 2>&1 && ! grep -q 'check-runs\|workflow run' "$CALLS"; then
    pass "$signal remains a terminal arm no-op"
  else
    fail "$signal reached authorization or dispatch"
  fi
done

for malformed in truncated labels-not-array label-name-not-string title-not-string; do
  write_terminal_hold
  case "$malformed" in
    truncated) printf '{"labels":[{"name":"hold"}],"title":"change","isDraft":fal' >"$META_FILE" ;;
    labels-not-array) jq '.labels="hold"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
    label-name-not-string) jq '.labels=[{"name":{"value":"hold"}}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
    title-not-string) jq '.title=42' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
  esac
  expect_fail "$malformed hold metadata fails closed before authorization"
  ! grep -q 'check-runs\|workflow run' "$CALLS" \
    && pass "$malformed hold metadata cannot authorize or dispatch" \
    || fail "$malformed hold metadata reached authorization or dispatch"
done

for unreadable in empty null missing-hold-fields; do
  write_terminal_hold
  case "$unreadable" in
    empty) : >"$META_FILE" ;;
    null) printf 'null\n' >"$META_FILE" ;;
    missing-hold-fields)
      jq 'del(.labels, .title, .isDraft)' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE" ;;
  esac
  expect_fail "$unreadable PR metadata fails closed before authorization"
  ! grep -q 'check-runs\|workflow run' "$CALLS" \
    && pass "$unreadable PR metadata cannot authorize or dispatch" \
    || fail "$unreadable PR metadata reached authorization or dispatch"
done

write_terminal_hold
export GH_VIEW_FAIL=true
expect_fail "an arm metadata API failure fails closed"
unset GH_VIEW_FAIL
! grep -q 'check-runs\|workflow run' "$CALLS" \
  && pass "an arm metadata API failure cannot authorize or dispatch" \
  || fail "an arm metadata API failure reached authorization or dispatch"

for terminal_state in CLOSED MERGED; do
  write_terminal_hold
  jq --arg state "$terminal_state" '.state=$state' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
  if run_arm >"$tmp/out" 2>&1 && ! grep -q 'check-runs\|workflow run' "$CALLS"; then
    pass "$terminal_state PR is a terminal arm no-op"
  else
    fail "$terminal_state PR reached authorization or dispatch"
  fi
done

write_repromotion() {
  : >"$CALLS"
  jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
  jq -nc --arg head "$head_sha" '{id:9001,conclusion:"success",details_url:"https://github.com/Verjson/example/actions/runs/7001",head_sha:$head}' >"$LATEST_FILE"
  export EVENT_ACTION=unlabeled EVENT_LABEL=hold EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=maintain RECEIPT_COUNT=1
}
write_repromotion
if run_arm >"$tmp/out" 2>&1 && grep -q 'workflow run ai-privileged-merge.yml' "$CALLS" \
  && grep -qF -- "-f review_policy=$receipt_policy" "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "hold removal reuses a live receipt without another paid review"
else fail "hold removal did not reuse authorization: $(tail -1 "$tmp/out")"; fi

for release_case in hold-label normalized-label ready-for-review edited-title; do
  write_repromotion
  case "$release_case" in
    hold-label) export EVENT_ACTION=unlabeled EVENT_LABEL=hold EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=maintain ;;
    normalized-label) export EVENT_ACTION=unlabeled EVENT_LABEL='Do__Not--Merge' EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=admin ;;
    ready-for-review) export EVENT_ACTION=ready_for_review EVENT_LABEL='' EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=maintain ;;
    edited-title) export EVENT_ACTION=edited EVENT_LABEL='' EVENT_OLD_TITLE_HELD=true EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=maintain ;;
  esac
  if run_arm >"$tmp/out" 2>&1 && grep -q 'workflow run ai-privileged-merge.yml' "$CALLS" \
      && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
    pass "$release_case reuses exact-head authorization without another paid review"
  else
    fail "$release_case did not follow the receipt-preserving re-arm path"
  fi
done

write_repromotion
export EVENT_ACTION=unlabeled EVENT_LABEL=hold HOLD_CLEAR_ACTOR_PERMISSION=triage
if run_arm >"$tmp/out" 2>&1; then
  fail "triage actor was allowed to clear a hold label"
elif grep -q 'commits/.*/check-runs\|workflow run' "$CALLS"; then
  fail "triage actor clearing a hold label reached receipt lookup or dispatch"
else
  pass "triage actor cannot use hold-label removal for receipt promotion"
fi

write_repromotion
export EVENT_ACTION=ready_for_review EVENT_LABEL='' HOLD_CLEAR_ACTOR_PERMISSION=triage
if run_arm >"$tmp/out" 2>&1; then
  fail "unauthorized ready-for-review actor was silently accepted"
elif grep -q 'workflow run ai-privileged-merge.yml\|workflow run ai-review-merge.yml' "$CALLS"; then
  fail "unauthorized ready-for-review actor reached privileged dispatch"
else
  pass "unauthorized ready-for-review actor cannot dispatch privileged work"
fi

write_repromotion
jq '.title="chore: DO NOT MERGE QA"' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export EVENT_ACTION=edited EVENT_OLD_TITLE_HELD=true EVENT_NEW_TITLE_HELD=false HOLD_CLEAR_ACTOR_PERMISSION=maintain
if run_arm >"$tmp/out" 2>&1 && ! grep -q 'commits/.*/check-runs\|workflow run' "$CALLS"; then
  pass "title edit that retains the authoritative hold exits before receipt lookup"
else
  fail "title edit that retains the hold reached authorization dispatch"
fi

write_repromotion
for rejected in replay stale-head actor-mismatch; do
  write_repromotion
  export EVENT_ACTION=ready_for_review EVENT_LABEL=''
  case "$rejected" in
    replay) export GITHUB_RUN_ATTEMPT=2 ;;
    stale-head) export EVENT_HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    actor-mismatch) export REQUEST_ACTOR=other ;;
  esac
  expect_fail "lifecycle delivery rejects $rejected"
  if grep -q 'workflow run\|--method POST repos/Verjson/example/check-runs' "$CALLS"; then
    fail "rejected lifecycle delivery reached authorization or dispatch"
  else pass "rejected lifecycle delivery stops before authority"; fi
  export GITHUB_RUN_ATTEMPT=1 EVENT_HEAD_SHA="$head_sha" REQUEST_ACTOR=maintainer
done
write_repromotion
export EVENT_ACTION=converted_to_draft EVENT_LABEL=''
printf '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"PR_id"}}}}\n' >"$GRAPHQL_FILE"
printf '{"id":"PR_id","autoMergeRequest":null}\n' >"$DISABLED_META_FILE"
jq '.isDraft=true | .autoMergeRequest={enabledAt:"now"}' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
if run_arm >"$tmp/out" 2>&1 && grep -q 'disablePullRequestAutoMerge' "$CALLS" && ! grep -q 'workflow run' "$CALLS"; then
  pass "local converted-to-draft delivery disables auto-merge without dispatch"
else fail "local draft transition did not disable auto-merge"; fi
write_repromotion
export EVENT_ACTION=unlabeled EVENT_LABEL=documentation EVENT_OLD_TITLE_HELD=false EVENT_NEW_TITLE_HELD=false
if run_arm >"$tmp/out" 2>&1 && ! grep -q 'commits/.*/check-runs\|workflow run' "$CALLS"; then
  pass "unrelated label removal exits before authorization lookup or dispatch"
else
  fail "unrelated label removal reached authorization lookup or dispatch"
fi
sed "s|review_policy=\"\$(jq -er .*|review_policy=\"$substitute_policy\"|" "$tmp/arm.sh" >"$tmp/arm-substituted.sh"
write_repromotion
if ARM_SCRIPT="$tmp/arm-substituted.sh" run_arm >"$tmp/out" 2>&1 \
  && grep -qF -- "-f review_policy=$substitute_policy" "$CALLS" \
  && ! grep -qF -- "-f review_policy=$receipt_policy" "$CALLS"; then
  pass "valid constant substitution is detected instead of matching the recovered receipt policy"
else fail "constant substitution mutation escaped the exact-value assertion"; fi
write_repromotion; export RECEIPT_COUNT=0
expect_fail "expired receipt requires explicit admin recovery"
! grep -q 'workflow run ai-review-merge.yml' "$CALLS" \
  && pass "expired receipt never automatically dispatches another paid review" \
  || fail "expired receipt dispatched paid review"

write_repromotion
jq '.status="completed" | .conclusion="failure"' "$LATEST_FILE" >"$tmp/x" && mv "$tmp/x" "$LATEST_FILE"
if run_arm >"$tmp/out" 2>&1 && grep -q 're-review' "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "failed authorization requires an explicit paid re-review decision"
else fail "failed authorization hold-clear guidance is missing"; fi

write_repromotion
jq '.status="in_progress" | .conclusion=null' "$LATEST_FILE" >"$tmp/x" && mv "$tmp/x" "$LATEST_FILE"
if run_arm >"$tmp/out" 2>&1 && grep -q 'still in progress' "$CALLS" && ! grep -q 'workflow run ai-review-merge.yml' "$CALLS"; then
  pass "receipt-proven pending authorization tells maintainers to wait without redispatch"
else fail "pending authorization was not handled spend-safely"; fi

write_repromotion
jq '.status="in_progress" | .conclusion=null' "$LATEST_FILE" >"$tmp/x" && mv "$tmp/x" "$LATEST_FILE"
export RECEIPT_COUNT=0
expect_fail "unproven pending authorization requires admin recovery"
grep -q 'administrator must recover' "$CALLS" \
  && pass "unproven pending authorization emits recovery guidance" \
  || fail "unproven pending authorization guidance missing"
! grep -q 'workflow run ai-review-merge.yml' "$CALLS" \
  && pass "pending recovery never automatically dispatches another paid review" \
  || fail "pending recovery dispatched a paid review"

: >"$CALLS"
jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"re-review"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=re-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=triage
export EVENT_NAME=pull_request_target
export REREVIEW_PROVIDER=openai REREVIEW_MODEL=gpt-5.6-luna REREVIEW_BUDGET_USD=1.00
expect_fail "triage actor cannot authorize a paid re-review"
! grep -q 'check-runs' "$CALLS" && pass "unauthorized actor fails before receipt or paid dispatch" || fail "unauthorized actor reached authorization creation"

: >"$CALLS"
jq '.labels=[]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export ACTOR_PERMISSION=maintain
expect_fail "withdrawn re-review label fails authoritative current-state validation"
! grep -q -- '--method POST repos/Verjson/example/check-runs\|workflow run ai-review-merge.yml' "$CALLS" \
  && pass "withdrawn re-review cannot create a receipt check or dispatch" \
  || fail "withdrawn re-review reached authorization or paid dispatch"

# An `ai-review` label may be added after the ordinary human-path authorization
# already completed for this head. That explicit, maintainer-authorized opt-in
# must create a fresh receipt instead of being mistaken for a duplicate event.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"ai-review"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
jq -nc --arg head "$head_sha" '{id:9001,status:"completed",conclusion:"success",details_url:"https://github.com/Verjson/example/actions/runs/7001",head_sha:$head}' >"$LATEST_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=ai-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain
export EVENT_NAME=pull_request_target
export REVIEW_AUTHORITY=human PRIMARY_PROVIDER=deepseek PRIMARY_MODEL=deepseek-v4-pro PRIMARY_BUDGET_USD=5.00
export PRIMARY_FALLBACK_MODEL=deepseek-v4-flash PRIMARY_FALLBACK_BUDGET_USD=5.00
if run_arm >"$tmp/out" 2>&1 && grep -q -- '--method POST repos/Verjson/example/check-runs --input -' "$CALLS" \
  && grep -q '^check_id=9100$' "$GITHUB_OUTPUT" \
  && policy_envelope="$(sed -n 's/^review_policy=//p' "$GITHUB_OUTPUT")" \
  && policy_json="$(python3 "$root/scripts/ci-gate/review-policy-envelope.py" decode "$policy_envelope")" \
  && [ "$(jq -r '.actor + ":" + .actor_permission' <<<"$policy_json")" = maintainer:maintain ]; then
  pass "post-open ai-review opt-in bypasses the existing human-path authorization"
else
  fail "post-open ai-review opt-in lost its verified actor permission or failed before receipt creation"
fi

# Persistent label state is not a delivery and must never be reusable authority.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
sync_opt_in_temp="$tmp/sync-opt-in"; mkdir "$sync_opt_in_temp"; export RUNNER_TEMP="$sync_opt_in_temp"
export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize EVENT_LABEL='' REQUEST_ACTOR=pusher ACTOR_PERMISSION=maintain
if run_arm >"$tmp/out" 2>&1 \
  && ! grep -q 'collaborators/maintainer/permission\|--method POST repos/Verjson/example/check-runs' "$CALLS"; then
  pass "synchronize cannot promote persistent ai-review label state into authority"
else
  fail "synchronize reused persistent ai-review label state"
fi
export RUNNER_TEMP="$tmp"

# A repository-level provider choice overrides the inherited organization
# DeepSeek policy as a unit. Stale Pro->Flash fallback variables must not make
# Anthropic/OpenAI invalid or leak into their receipt policy.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
provider_temp="$tmp/provider-anthropic"; mkdir "$provider_temp"; export RUNNER_TEMP="$provider_temp"
export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize EVENT_LABEL=''
jq '.labels=[]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
printf '{}\n' >"$LATEST_FILE"
export PRIMARY_PROVIDER=anthropic PRIMARY_MODEL=auto PRIMARY_BUDGET_USD=auto
export PRIMARY_FALLBACK_MODEL=deepseek-v4-flash PRIMARY_FALLBACK_BUDGET_USD=5.00
if run_arm >"$tmp/out" 2>&1 \
  && policy_envelope="$(sed -n 's/^review_policy=//p' "$GITHUB_OUTPUT")" \
  && policy_json="$(python3 "$root/scripts/ci-gate/review-policy-envelope.py" decode "$policy_envelope")" \
  && [ "$(jq -r '.provider + ":" + .fallback_model + ":" + .fallback_budget_usd' <<<"$policy_json")" = 'anthropic::' ]; then
  pass "repository Anthropic override clears inherited DeepSeek fallback policy"
else
  fail "repository Anthropic override retained inherited DeepSeek fallback policy"
fi

: >"$CALLS"; : >"$GITHUB_OUTPUT"
provider_temp="$tmp/provider-openai"; mkdir "$provider_temp"; export RUNNER_TEMP="$provider_temp"
jq '.labels=[{"name":"re-review"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=re-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain
export EVENT_NAME=pull_request_target
export REREVIEW_PROVIDER=openai REREVIEW_MODEL=gpt-5.6-luna REREVIEW_BUDGET_USD=1.00
export REREVIEW_FALLBACK_MODEL=deepseek-v4-flash REREVIEW_FALLBACK_BUDGET_USD=5.00
if run_arm >"$tmp/out" 2>&1 \
  && policy_envelope="$(sed -n 's/^review_policy=//p' "$GITHUB_OUTPUT")" \
  && policy_json="$(python3 "$root/scripts/ci-gate/review-policy-envelope.py" decode "$policy_envelope")" \
  && [ "$(jq -r '.provider + ":" + .fallback_model + ":" + .fallback_budget_usd' <<<"$policy_json")" = 'openai::' ]; then
  pass "repository OpenAI override clears inherited DeepSeek fallback policy"
else
  fail "repository OpenAI override retained inherited DeepSeek fallback policy"
fi
export RUNNER_TEMP="$tmp"

# GitHub can omit a label-triggered pull_request_target delivery entirely. A
# maintainer can rerun a prior exact-head arm attempt; attempt 2 must bypass
# same-head deduplication only after the arm re-reads current PR/head state, and
# the new receipt must bind that run attempt. This does not simulate or claim a
# repaired label delivery.
: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq -nc --arg head "$head_sha" '{id:"PR_id",state:"OPEN",isDraft:false,title:"change",labels:[{name:"re-review"}],headRefOid:$head,headRepositoryOwner:{login:"Verjson"},autoMergeRequest:null}' >"$META_FILE"
recovery_temp="$tmp/recovery"
mkdir "$recovery_temp"
export EVENT_NAME=pull_request_target EVENT_ACTION=labeled EVENT_LABEL=re-review REQUEST_ACTOR=maintainer ACTOR_PERMISSION=maintain GITHUB_RUN_ATTEMPT=2 RUNNER_TEMP="$recovery_temp"
expect_fail "rerun cannot replay an explicit re-review delivery"
! grep -q -- '--method POST repos/Verjson/example/check-runs' "$CALLS" \
  && pass "replayed delivery fails before authorization creation" \
  || fail "replayed delivery created authorization"

: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq '.labels=[]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
repeated_recovery_temp="$tmp/repeated-recovery"
mkdir "$repeated_recovery_temp"
export GITHUB_RUN_ATTEMPT=3 RUNNER_TEMP="$repeated_recovery_temp"
expect_fail "later rerun remains fail-closed after label consumption"
export GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$tmp"

: >"$CALLS"; : >"$GITHUB_OUTPUT"
jq '.labels=[{"name":"ai-review"}]' "$META_FILE" >"$tmp/x" && mv "$tmp/x" "$META_FILE"
export EVENT_ACTION=labeled EVENT_LABEL=ai-review ACTOR_PERMISSION=triage PR_EDIT_FAIL=true
export EVENT_NAME=pull_request_target
expect_fail "unauthorized ai-review label fails even when cleanup cannot remove it"
: >"$CALLS"
export EVENT_NAME=pull_request_target EVENT_ACTION=synchronize EVENT_LABEL='' REQUEST_ACTOR=pusher
sync_retained_temp="$tmp/sync-retained"; mkdir "$sync_retained_temp"; export RUNNER_TEMP="$sync_retained_temp"
if run_arm >"$tmp/out" 2>&1 \
  && ! grep -q 'collaborators/maintainer/permission' "$CALLS" \
  && ! grep -q '^explicit_ai_review=true$' "$GITHUB_OUTPUT"; then
  pass "retained unauthorized label cannot become explicit review authority"
else
  fail "retained unauthorized label influenced the synchronized authorization policy"
fi
export RUNNER_TEMP="$tmp"
unset PR_EDIT_FAIL

write_repromotion
: >"$GITHUB_OUTPUT"
printf '{}\n' >"$LATEST_FILE"
export EVENT_ACTION=ready_for_review EVENT_LABEL='' REQUEST_ACTOR=maintainer REVIEW_AUTHORITY=human
export PRIMARY_PROVIDER=anthropic PRIMARY_MODEL=auto PRIMARY_BUDGET_USD=auto
export PRIMARY_FALLBACK_MODEL='' PRIMARY_FALLBACK_BUDGET_USD=''
if run_arm >"$tmp/out" 2>&1 && jq -e '.schema == 2 and .delivery_actor == "maintainer" and .delivery_event == "pull_request_target"' "$RUNNER_TEMP/ai-review-arm-receipt/receipt.json" >/dev/null; then
  pass "ready-for-review creates a source-bound schema-2 receipt"
else fail "ready-for-review did not create a source-bound receipt: $(tail -1 "$tmp/out")"; fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
