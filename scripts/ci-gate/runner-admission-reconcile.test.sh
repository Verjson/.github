#!/usr/bin/env bash
# Drives runner-admission-reconcile.sh against a stubbed `gh`.
#
# The cases that matter most are the undetermined ones. A reconciler that
# reports "no drift" when it could not read the org is worse than no reconciler
# at all — it manufactures confidence. Every failure path is executed here, not
# just asserted about.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/runner-admission-reconcile.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
# Emulates `gh api --paginate <path> --jq <expr>` by returning the already
# projected fixture for the path, the way the real call would after --jq.
path=""
for arg in "$@"; do
  case "$arg" in /orgs/*) path="$arg";; esac
done
case "$path" in
  *"$FAIL_PATH"*) [ -n "${FAIL_PATH:-}" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; };;
esac
# Order matters: the runner-group path ends in `/repositories`, so a `*/repos*`
# arm placed first would swallow it and hand back the wrong fixture.
case "$path" in
  */runner-groups/4/repositories*) printf '%s' "${G4_FIXTURE:-}";    [ -n "${G4_FIXTURE:-}" ] && echo;;
  */runner-groups/6/repositories*) printf '%s' "${G6_FIXTURE:-}";    [ -n "${G6_FIXTURE:-}" ] && echo;;
  */orgs/*/repos*)                 printf '%s' "${REPOS_FIXTURE:-}"; [ -n "${REPOS_FIXTURE:-}" ] && echo;;
  *) echo "unexpected path: $path" >&2; exit 1;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export FAIL_PATH=""

run_case() {
  REPOS_FIXTURE="$1" G4_FIXTURE="$2" G6_FIXTURE="$3" FAIL_PATH="${4:-}" \
    bash "$script" 2>&1
}
code_of() {
  run_case "$@" >/dev/null 2>&1
  printf '%s' "$?"
}

CLEAN_REPOS=$'Verjson/lib-a\ttrue\nVerjson/.github\tfalse'
CLEAN_G4=$'Verjson/lib-a'
CLEAN_G6=$'Verjson/.github'

# --- happy path ------------------------------------------------------------
out="$(run_case "$CLEAN_REPOS" "$CLEAN_G4" "$CLEAN_G6")"
code="$(code_of "$CLEAN_REPOS" "$CLEAN_G4" "$CLEAN_G6")"
{ [ "$code" = "0" ] && printf '%s' "$out" | grep -qF 'No drift'; } \
  && pass "clean org reports no drift and exits 0" \
  || fail "clean org did not report clean (exit $code): $out"

# --- a private repo outside the general group would queue forever -----------
out="$(run_case $'Verjson/lib-a\ttrue\nVerjson/orphan\ttrue' "$CLEAN_G4" "$CLEAN_G6")"
code="$(code_of $'Verjson/lib-a\ttrue\nVerjson/orphan\ttrue' "$CLEAN_G4" "$CLEAN_G6")"
{ [ "$code" = "1" ] && printf '%s' "$out" | grep -qF 'Verjson/orphan'; } \
  && pass "private repo missing from the general group is flagged (exit 1)" \
  || fail "private-repo drift not caught (exit $code): $out"

# --- a public repo outside the isolated group, same ------------------------
out="$(run_case $'Verjson/site\tfalse' "$CLEAN_G4" "$CLEAN_G6")"
code="$(code_of $'Verjson/site\tfalse' "$CLEAN_G4" "$CLEAN_G6")"
{ [ "$code" = "1" ] && printf '%s' "$out" | grep -qF 'Verjson/site'; } \
  && pass "public repo missing from the isolated group is flagged (exit 1)" \
  || fail "public-repo drift not caught (exit $code): $out"

# --- the #189 case: a brand-new repo admitted nowhere ----------------------
code="$(code_of $'Verjson/brand-new\ttrue' '' "$CLEAN_G6")"
[ "$code" = "1" ] \
  && pass "newly created repo in no group is flagged (the #189 hang)" \
  || fail "new-repo hang not caught (exit $code)"

# --- security-relevant: public repo admitted to the persistent pool --------
out="$(run_case $'Verjson/.github\tfalse' $'Verjson/.github' "$CLEAN_G6")"
printf '%s' "$out" | grep -qF 'admitted to the persistent pool' \
  && pass "public repo in the persistent pool is reported" \
  || fail "public-on-general not reported: $out"

# --- archived repositories are not counted ---------------------------------
# The fixture models the post-filter projection, so an archived repo simply
# never appears; this asserts the filter is in the query, not bolted on later.
grep -qF 'select(.archived == false)' "$script" \
  && pass "archived repositories are excluded at the API projection" \
  || fail "archived filter missing from the repos query"

# --- FAIL-CLOSED: every undetermined path must exit 2, never 0 -------------
code="$(code_of "$CLEAN_REPOS" "$CLEAN_G4" "$CLEAN_G6" '/repos')"
[ "$code" = "2" ] \
  && pass "repos API failure is undetermined (exit 2), not clean" \
  || fail "repos API failure returned $code — a failed read must never read as clean"

code="$(code_of "$CLEAN_REPOS" "$CLEAN_G4" "$CLEAN_G6" '/runner-groups/4/')"
[ "$code" = "2" ] \
  && pass "runner-group API failure is undetermined (exit 2), not clean" \
  || fail "runner-group API failure returned $code"

code="$(code_of '' "$CLEAN_G4" "$CLEAN_G6")"
[ "$code" = "2" ] \
  && pass "empty repository list is undetermined (exit 2), not clean" \
  || fail "empty repo list returned $code — an empty org is not a healthy org"

code="$(code_of "$CLEAN_REPOS" '' '')"
[ "$code" = "2" ] \
  && pass "both groups empty is undetermined (exit 2), not drift" \
  || fail "both-groups-empty returned $code"

# --- the workflow must actually run this, with a token that can read the org
wf="$here/../../.github/workflows/runner-admission-reconcile.yml"
if [ -f "$wf" ]; then
  { grep -qF 'runner-admission-reconcile.sh' "$wf" \
      && grep -qF 'ORG_ADMIN_TOKEN' "$wf"; } \
    && pass "workflow runs the reconciler with an org-scoped token" \
    || fail "workflow does not wire the reconciler to an org-scoped token"
  # Exit 2 must not be swallowed into the same branch as 0.
  grep -qE '(-eq 2|== 2|\) 2\))' "$wf" \
    && pass "workflow distinguishes undetermined from clean" \
    || fail "workflow does not handle exit 2 separately from exit 0"
else
  fail "runner-admission-reconcile.yml is missing"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
