#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/runner-admission-reconcile.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# The stub ignores `--jq` and returns already-shaped fixtures, so it cannot
# verify that the script's jq filters frame their output the way the callers
# assume (raw one-string-per-line for `.repositories[].full_name`, one JSON
# object per line for `.runners[] | {...}`). That framing is load-bearing for
# slurp_strings/slurp_objects. It is inherent to stubbing rather than a new
# risk — the pre-existing repos fetch relies on the same guarantee — but a
# change to those filters will not be caught here.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
path=""
for arg in "$@"; do
  case "$arg" in /orgs/*) path="$arg";; esac
done
if [ -n "${FAIL_PATH:-}" ] && [[ "$path" == *"$FAIL_PATH"* ]]; then
  echo "HTTP 403: Resource not accessible" >&2
  exit 1
fi
# A deleted group is gone from BOTH surfaces: the id 404s and it is absent from
# the listing. Modelling only the 404 would let a test pass for the wrong reason.
deleted() {
  case " ${DELETED_GROUPS:-} " in *" $1 "*) return 0;; *) return 1;; esac
}
for id in 4 6; do
  if deleted "$id" && [[ "$path" == */runner-groups/"$id" || "$path" == */runner-groups/"$id"/* ]]; then
    echo '{"message":"Not Found","status":"404"}' >&2
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
done
case "$path" in
  */actions/variables/VERJSON_RUNNER_DEFAULT) printf '%s\n' "$DEFAULT_VAR" ;;
  */actions/variables/VERJSON_RUNNER_UNTRUSTED) printf '%s\n' "$UNTRUSTED_VAR" ;;
  */runner-groups/4/repositories*) printf '%s\n' "$G4_MEMBERS" ;;
  */runner-groups/6/repositories*) printf '%s\n' "$G6_MEMBERS" ;;
  */runner-groups/4/runners*) printf '%s\n' "$G4_RUNNERS" ;;
  */runner-groups/6/runners*) printf '%s\n' "$G6_RUNNERS" ;;
  */runner-groups/4) printf '%s\n' "$G4_GROUP" ;;
  */runner-groups/6) printf '%s\n' "$G6_GROUP" ;;
  # The group listing, which is how the reconciler resolves a name to an id.
  # '?' is a glob wildcard that also matches '/', so the query separator is
  # escaped: an unescaped '*/actions/runner-groups?*' would swallow EVERY
  # unknown '/runner-groups/<id>/...' path and answer it with the listing,
  # instead of letting it fall through to the guard below. A stub that answers
  # the wrong question is worse than one that errors.
  */actions/runner-groups|*/actions/runner-groups\?*)
    deleted 4 || printf '%s\n' "$G4_GROUP"
    deleted 6 || printf '%s\n' "$G6_GROUP"
    ;;
  */orgs/*/repos*) printf '%s\n' "$REPOS_FIXTURE" ;;
  *) echo "unexpected path: $path" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

export DEFAULT_VAR='{"value":"[\"self-hosted\",\"general\"]","visibility":"all"}'
export UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"general\"]","visibility":"all"}'
export G4_GROUP='{"id":4,"name":"GCP","visibility":"all","allows_public_repositories":true}'
export G6_GROUP='{"id":6,"name":"isolated","visibility":"selected","allows_public_repositories":true}'
# Member/runner fixtures are what `gh api --paginate --jq` emits: one element
# per line, concatenated across pages. Multiple lines therefore ARE the
# multi-page case, which is the shape the collector has to survive.
export G4_MEMBERS=''
export G6_MEMBERS=''
export G4_RUNNERS='{"name":"general-1","status":"online","labels":["self-hosted","Linux","X64","general"]}'
export G6_RUNNERS=''
export REPOS_FIXTURE=$'Verjson/private-lib\ttrue\nVerjson/public-app\tfalse'
export FAIL_PATH=''
export DELETED_GROUPS=''

run_case() { bash "$script" 2>&1; }
code_of() { run_case >/dev/null 2>&1; printf '%s' "$?"; }

out="$(run_case)"
[ "$(code_of)" = "0" ] \
  && grep -qF 'No drift' <<<"$out" \
  && pass "organization-wide permissive group admits new private and public repositories" \
  || fail "clean permissive policy did not reconcile: $out"

G4_GROUP='{"id":4,"name":"GCP","visibility":"all","allows_public_repositories":false}'
out="$(run_case)"
[ "$(code_of)" = "1" ] \
  && grep -qF 'Verjson/public-app' <<<"$out" \
  && pass "public repository denied by group is reported as drift" \
  || fail "public admission drift not reported: $out"

G4_GROUP='{"id":4,"name":"GCP","visibility":"selected","allows_public_repositories":true}'
# Two lines == two pages: the repo under test sits on the FIRST page, which is
# precisely what a per-page collector would drop.
G4_MEMBERS=$'Verjson/public-app\nVerjson/some-other-repo'
out="$(run_case)"
[ "$(code_of)" = "1" ] \
  && grep -qF 'Verjson/private-lib' <<<"$out" \
  && pass "new private repository missing from selected group is reported" \
  || fail "selected-group new repository gap not reported: $out"

G4_GROUP='{"id":4,"name":"GCP","visibility":"all","allows_public_repositories":true}'
G4_MEMBERS=''
G4_RUNNERS='{"name":"general-1","status":"offline","labels":["self-hosted","general"]}'
out="$(run_case)"
[ "$(code_of)" = "1" ] \
  && grep -qF 'has no matching online runner' <<<"$out" \
  && pass "selector with no online capacity is reported" \
  || fail "capacity drift not reported: $out"

G4_RUNNERS='{"name":"general-1","status":"online","labels":["self-hosted","general"]}'
UNTRUSTED_VAR='{"value":"not-json","visibility":"all"}'
[ "$(code_of)" = "2" ] \
  && pass "malformed variable is undetermined, never clean" \
  || fail "malformed variable did not return exit 2"

UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"general\"]","visibility":"selected"}'
[ "$(code_of)" = "2" ] \
  && pass "variable hidden from new repositories is undetermined" \
  || fail "non-global variable did not return exit 2"

UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"unknown-lane\"]","visibility":"all"}'
[ "$(code_of)" = "2" ] \
  && pass "ungoverned lane selector is undetermined" \
  || fail "ungoverned lane did not return exit 2"

UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"general\"]","visibility":"all"}'
FAIL_PATH='/actions/variables/VERJSON_RUNNER_DEFAULT'
[ "$(code_of)" = "2" ] \
  && pass "org API failure is undetermined, never clean" \
  || fail "API failure did not return exit 2"

FAIL_PATH=''
DEFAULT_VAR='{"value":"[\"self-hosted\",\"lane-general\"]","visibility":"all"}'
UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"lane-untrusted\"]","visibility":"all"}'
G6_GROUP='{"id":6,"name":"isolated","visibility":"all","allows_public_repositories":true}'
G4_RUNNERS='{"name":"general-1","status":"online","labels":["self-hosted","lane-general"]}'
G6_RUNNERS='{"name":"untrusted-1","status":"online","labels":["self-hosted","lane-untrusted"]}'
out="$(run_case)"
[ "$(code_of)" = "0" ] \
  && grep -qF 'No drift' <<<"$out" \
  && pass "namespaced ADR 0035 lane labels map without reconciler changes" \
  || fail "namespaced lane labels did not reconcile: $out"

# #266. Group 6 (`isolated`) was deleted on 2026-07-31 and the reconciler, which
# pinned the id, went undetermined on every run. Two distinct behaviours have to
# hold, and the second is the one that was actually broken.

# 1. A group a lane genuinely needs, gone: still fail closed — but name it. The
#    old code emitted only the request path, so asserting on the NAME is what
#    makes this fail against a reconciler that resolves by literal id.
DELETED_GROUPS='6'
out="$(run_case)"
[ "$(code_of)" = "2" ] \
  && grep -qF 'isolated' <<<"$out" \
  && pass "a lane-selected group that no longer exists fails closed, naming the group" \
  || fail "missing selected group was not reported by name: $out"

# 2. A group NO lane selects, gone: irrelevant, so it must not take the run down.
#    This is the live regression — both lanes resolve to `general`, nothing
#    routes to `isolated`, and the reconciler still died fetching it.
UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"lane-general\"]","visibility":"all"}'
out="$(run_case)"
[ "$(code_of)" = "0" ] \
  && grep -qF 'No drift' <<<"$out" \
  && pass "a deleted group that no lane selects does not block reconciliation" \
  || fail "unselected deleted group still broke the run: $out"

# 3. The general lane is the one every private repository rides. Its group going
#    missing is the highest-blast-radius case, and it had no coverage.
DELETED_GROUPS='4'
DEFAULT_VAR='{"value":"[\"self-hosted\",\"lane-general\"]","visibility":"all"}'
out="$(run_case)"
[ "$(code_of)" = "2" ] \
  && grep -qF 'GCP' <<<"$out" \
  && pass "the general lane's group going missing fails closed, naming the group" \
  || fail "missing general group was not reported by name: $out"

# 4. If the listing itself cannot be read, no group can be resolved at all. That
#    is the definition of undetermined and must never read as clean.
DELETED_GROUPS=''
FAIL_PATH='/actions/runner-groups'
[ "$(code_of)" = "2" ] \
  && pass "an unreadable runner-group listing is undetermined, never clean" \
  || fail "group listing failure did not return exit 2"

FAIL_PATH=''
DEFAULT_VAR='{"value":"[\"self-hosted\",\"lane-general\"]","visibility":"all"}'
UNTRUSTED_VAR='{"value":"[\"self-hosted\",\"lane-untrusted\"]","visibility":"all"}'

# Structural: `--paginate` emits one response per page, so a `[...]` collector
# yields one array per page and downstream `jq -e` sees only the last. The
# behavioural multi-page case above locks in the new shape; this catches a
# regression back to the old one, which no fixture can express.
! grep -qE "'\[\.(repositories|runners)\[\]" "$script" \
  && pass "group member/runner fetches use the pagination-safe streaming collector" \
  || fail "a per-page array collector reappeared in the group fetches"

grep -qF 'select(.archived == false)' "$script" \
  && pass "archived repositories remain excluded" \
  || fail "archived repository filter missing"

workflow="$here/../../.github/workflows/runner-admission-reconcile.yml"
[ -f "$workflow" ] \
  && grep -qF 'runner-admission-reconcile.sh' "$workflow" \
  && grep -qF 'ORG_ADMIN_TOKEN' "$workflow" \
  && pass "daily workflow keeps org-scoped reconciliation wiring" \
  || fail "runner admission workflow wiring drifted"

# The wrapper's exit-code contract, executed rather than grepped. House method
# (hold.test.sh, ci-wait-fail-closed.test.sh): awk-extract the exact `run:` block
# so the test cannot drift from the shipped logic, then drive it with a stub.
extract_reconcile_step() {
  awk '
    $0 == "        id: reconcile" { seen = 1 }
    seen && $0 == "        run: |" { cap = 1; next }
    cap && $0 ~ /^      - name:/ { exit }
    cap {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      exit
    }
  ' "$workflow"
}

wrapper="$tmp/reconcile-step.sh"
extract_reconcile_step >"$wrapper"
[ -s "$wrapper" ] \
  && pass "reconcile step body extracts from the workflow" \
  || fail "could not extract the reconcile step body"

# Drive the extracted block with a stub standing in for the reconciler, so the
# only thing under test is how the wrapper maps an exit code to a verdict.
# Emits "<wrapper-exit> <code-output-VALUE>". Asserting the value, not merely
# that a `code=` line exists: a count-based assertion stays green when the
# wrapper hardcodes `code=0`, which would suppress every drift issue AND fire
# the close step on every run, silently closing live drift. A test that cannot
# distinguish that is the same fail-open it is supposed to be guarding.
run_wrapper() { # run_wrapper <exit-code>
  local stub_code="$1" work="$tmp/wrap.$1" rc
  rm -rf "$work"; mkdir -p "$work/scripts/ci-gate"
  printf '#!/usr/bin/env bash\necho "stub report"\nexit %s\n' "$stub_code" \
    >"$work/scripts/ci-gate/runner-admission-reconcile.sh"
  chmod +x "$work/scripts/ci-gate/runner-admission-reconcile.sh"
  : >"$work/summary"; : >"$work/output"
  ( cd "$work" && GH_TOKEN=stub-token \
      GITHUB_STEP_SUMMARY="$work/summary" GITHUB_OUTPUT="$work/output" \
      bash "$wrapper" >/dev/null 2>&1 )
  rc=$?
  printf '%s %s' "$rc" "$(sed -n 's/^code=//p' "$work/output" | tr -d '\n')"
}

[ "$(run_wrapper 0)" = "0 0" ] \
  && pass "wrapper passes a clean reconciliation through as success" \
  || fail "clean run did not exit 0 with code=0: $(run_wrapper 0)"

[ "$(run_wrapper 1)" = "0 1" ] \
  && pass "wrapper keeps drift green so the issue step can file it" \
  || fail "drift run did not exit 0 with code=1: $(run_wrapper 1)"

[ "$(run_wrapper 2)" = "1 2" ] \
  && pass "wrapper fails the job when the org could not be read" \
  || fail "undetermined run did not fail the job: $(run_wrapper 2)"

# The gap: 127 is `command not found`, and a `set -u` abort surfaces as 1-or-worse.
# Before this, anything outside 0/1/2 fell through to the unconditional `exit 0`
# — job green, drift step skipped, nothing filed, org never actually examined.
[ "$(run_wrapper 127)" = "1 127" ] \
  && pass "wrapper treats an off-contract exit code as undetermined, not clean" \
  || fail "crash exit code was reported as clean: $(run_wrapper 127)"

# The wrapper's exit code and its `code` output only mean anything together with
# the conditions on the downstream steps. Without these, flipping the drift step
# to `== '2'` leaves the whole suite green while drift is never filed again.
grep -qF "steps.reconcile.outputs.code == '1'" "$workflow" \
  && pass "the drift-issue step is still gated on the drift code" \
  || fail "drift-issue step condition drifted from code == '1'"

grep -qF "steps.reconcile.outputs.code == '0'" "$workflow" \
  && pass "the issue-closing step is still gated on the clean code" \
  || fail "issue-closing step condition drifted from code == '0'"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
