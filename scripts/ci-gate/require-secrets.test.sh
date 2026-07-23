#!/usr/bin/env bash
# Tests the merge gate's require_secrets guard (Verjson/.github#131) by extracting
# the exact `run:` block from ai-review-merge.yml — the single source of truth, so
# the test can't drift from the shipped logic — and exercising it against a
# stubbed GH_TOKEN. Every gate step drives `gh pr view/merge` under
# ORG_ADMIN_TOKEN; a cross-org workflow_call consumer that forgets
# `secrets: inherit` would otherwise die much later in an opaque `gh` auth error.
# The guard must fail closed (with an actionable message) when the token is empty
# and proceed when it is present. Plain bash + awk; no test-framework or
# YAML-library dependency (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract the guard step's run script verbatim (10-space-indented body after
# `run: |`, scoped to the step whose `id:` is require_secrets).
script="$tmp/require_secrets.sh"
awk '
  $0 == "        id: require_secrets" { seen = 1 }
  seen && !cap && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit  # end of this step: stop before the next step re-arms capture
  }
' "$wf" >"$script"
if ! grep -q 'GH_TOKEN' "$script"; then
  echo "FAIL - could not extract the require_secrets run block from $wf"
  exit 1
fi

# run_case <token-value> — exercise the guard with GH_TOKEN set to the argument.
run_case() {
  export GH_TOKEN="$1"
  bash -eo pipefail "$script" >/dev/null 2>&1
  echo "rc=$?"
}

# (a) Present token (org direct path, or a consumer that passed secrets: inherit)
# → the guard proceeds.
[ "$(run_case 'a-non-empty-token-placeholder')" = "rc=0" ] \
  && pass "present ORG_ADMIN_TOKEN proceeds" \
  || fail "present token was rejected"

# (b) Empty token (consumer forgot secrets: inherit) → fail closed (exit 1).
[ "$(run_case '')" = "rc=1" ] \
  && pass "empty ORG_ADMIN_TOKEN fails closed (no opaque gh auth error later)" \
  || fail "empty token NOT rejected — run would die later in an opaque gh auth error"

# (c) Unset token (GH_TOKEN never exported) must also fail closed, not error on
# an unbound variable under `set -u`. The guard uses ${GH_TOKEN:-} for this.
[ "$(unset GH_TOKEN; bash -eo pipefail "$script" >/dev/null 2>&1; echo "rc=$?")" = "rc=1" ] \
  && pass "unset GH_TOKEN fails closed (handled under set -u)" \
  || fail "unset GH_TOKEN did not fail closed cleanly"

# (d) The actionable message must name the fix so a consumer knows what to do.
msg="$(GH_TOKEN='' bash -eo pipefail "$script" 2>&1 || true)"
grep -q 'secrets: inherit' <<<"$msg" \
  && pass "failure message tells a consumer to pass 'secrets: inherit'" \
  || fail "failure message does not mention 'secrets: inherit'"

# (e) The guard must never echo the token value itself.
grep -q 'echo .*GH_TOKEN' "$script" \
  && fail "guard echoes GH_TOKEN — token could leak into logs" \
  || pass "guard never echoes the token value"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
