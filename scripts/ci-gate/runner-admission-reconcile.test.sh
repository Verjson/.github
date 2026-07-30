#!/usr/bin/env bash
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
path=""
for arg in "$@"; do
  case "$arg" in /orgs/*) path="$arg";; esac
done
if [ -n "${FAIL_PATH:-}" ] && [[ "$path" == *"$FAIL_PATH"* ]]; then
  echo "HTTP 403: Resource not accessible" >&2
  exit 1
fi
case "$path" in
  */actions/variables/VERJSON_RUNNER_DEFAULT) printf '%s\n' "$DEFAULT_VAR" ;;
  */actions/variables/VERJSON_RUNNER_UNTRUSTED) printf '%s\n' "$UNTRUSTED_VAR" ;;
  */runner-groups/4/repositories*) printf '%s\n' "$G4_MEMBERS" ;;
  */runner-groups/6/repositories*) printf '%s\n' "$G6_MEMBERS" ;;
  */runner-groups/4/runners*) printf '%s\n' "$G4_RUNNERS" ;;
  */runner-groups/6/runners*) printf '%s\n' "$G6_RUNNERS" ;;
  */runner-groups/4) printf '%s\n' "$G4_GROUP" ;;
  */runner-groups/6) printf '%s\n' "$G6_GROUP" ;;
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
export G4_MEMBERS='[]'
export G6_MEMBERS='[]'
export G4_RUNNERS='[{"name":"general-1","status":"online","labels":["self-hosted","Linux","X64","general"]}]'
export G6_RUNNERS='[]'
export REPOS_FIXTURE=$'Verjson/private-lib\ttrue\nVerjson/public-app\tfalse'
export FAIL_PATH=''

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
G4_MEMBERS='["Verjson/public-app"]'
out="$(run_case)"
[ "$(code_of)" = "1" ] \
  && grep -qF 'Verjson/private-lib' <<<"$out" \
  && pass "new private repository missing from selected group is reported" \
  || fail "selected-group new repository gap not reported: $out"

G4_GROUP='{"id":4,"name":"GCP","visibility":"all","allows_public_repositories":true}'
G4_MEMBERS='[]'
G4_RUNNERS='[{"name":"general-1","status":"offline","labels":["self-hosted","general"]}]'
out="$(run_case)"
[ "$(code_of)" = "1" ] \
  && grep -qF 'has no matching online runner' <<<"$out" \
  && pass "selector with no online capacity is reported" \
  || fail "capacity drift not reported: $out"

G4_RUNNERS='[{"name":"general-1","status":"online","labels":["self-hosted","general"]}]'
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

grep -qF 'select(.archived == false)' "$script" \
  && pass "archived repositories remain excluded" \
  || fail "archived repository filter missing"

workflow="$here/../../.github/workflows/runner-admission-reconcile.yml"
[ -f "$workflow" ] \
  && grep -qF 'runner-admission-reconcile.sh' "$workflow" \
  && grep -qF 'ORG_ADMIN_TOKEN' "$workflow" \
  && pass "daily workflow keeps org-scoped reconciliation wiring" \
  || fail "runner admission workflow wiring drifted"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
