#!/usr/bin/env bash
# Verjson/.github#412 — changelog-validate.yml must reject a mutable contract_ref
# BEFORE it checks anything out.
#
# `ref:` accepts any ref of Verjson/.github, and this workflow then executes
# `python3` from the result, so the ref decides what code runs on the Verjson
# lane. ~90 repositories call it. `refs/pull/<n>/merge` is the sharp case: this
# repository is public, so that ref is reachable by anyone who can open a pull
# request. A branch or tag is the quiet case: it validates against a
# non-canonical contract, which is the failure ADR 0038's pinning exists to make
# impossible.
#
# House method: awk-extract the exact `run:` block from the workflow so the test
# cannot drift from what CI runs, then execute it against fixture environments.
# Executing it matters — a grep for `ref_is_immutable` would pass on a guard that
# is present but wired after the checkout, or never reached.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/changelog-validate.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# Extract the pin guard's run block (10-space-indented body under `run: |`,
# scoped to the step with `id: pin`). Stop at the next step so a following
# `run: |` cannot append unrelated code to the script under test.
pin="$tmp/pin.sh"
awk '
  $0 == "        id: pin" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap && $0 ~ /^      - name:/ { exit }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit
  }
' "$wf" >"$pin"
if ! grep -q 'ref_is_immutable' "$pin"; then
  echo "FAIL - could not extract the pin guard run block from $wf"
  exit 1
fi

immutable_sha=0123456789abcdef0123456789abcdef01234567

run_pin() { # run_pin <contract_ref>
  ( env GITHUB_STEP_SUMMARY="$tmp/summary.md" CONTRACT_REF="$1" bash "$pin" 2>&1 )
}

# The accepted shape. Without this, deleting the guard's success path entirely
# would satisfy every rejection case below.
out="$(run_pin "$immutable_sha")"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a full 40-character lower-case commit SHA is accepted as the contract pin" \
  || fail "an immutable contract pin was rejected (rc=$rc): $out"

mutable_case() { # mutable_case <ref> <description>
  local ref="$1" description="$2" out rc
  out="$(run_pin "$ref")"; rc=$?
  { [ "$rc" -ne 0 ] && grep -q 'contract_ref' <<<"$out"; } \
    && pass "$description is rejected, naming contract_ref" \
    || fail "$description was ACCEPTED as a contract pin (rc=$rc): $out"
}

# The security case: reachable by anyone who can open a PR against this public repo.
mutable_case refs/pull/1/merge 'a pull-request merge ref'
# The quiet cases: valid refs that can move after review.
mutable_case main 'the default branch'
mutable_case fix/412-immutable-contract-ref 'a feature branch'
mutable_case v2.2.0 'a release tag'
# #312: exactly 40 hex, so neither a prefix nor a superstring passes. An
# abbreviated SHA is ambiguous by construction — git resolves it against whatever
# objects exist at fetch time — so "is a prefix of a SHA" is not the test.
mutable_case "${immutable_sha:0:12}" 'an abbreviated SHA'
mutable_case "${immutable_sha:0:39}" 'a 39-character SHA'
mutable_case "${immutable_sha}0" 'an over-long hex string'
mutable_case "${immutable_sha^^}" 'an upper-case SHA'
# Empty and whitespace: `required: true` only means the input is present, not
# that it is non-empty, and a caller interpolating an unset variable sends "".
mutable_case '' 'an empty contract_ref'
mutable_case '   ' 'a whitespace-only contract_ref'
# A 40-hex SHA with adjacent junk must not pass on a partial match — the anchors
# are what make `=~` a whole-string test rather than a search.
mutable_case " $immutable_sha" 'a SHA with a leading space'
mutable_case "$immutable_sha " 'a SHA with a trailing space'
mutable_case "refs/heads/$immutable_sha" 'a ref path that merely contains a SHA'

# Ordering is the whole point: a guard that runs after the checkout has already
# fetched and can already have executed nothing useful. Pin the guard step ahead
# of both checkouts in file order.
pin_line="$(grep -n '^        id: pin$' "$wf" | head -n1 | cut -d: -f1)"
first_checkout_line="$(grep -n 'uses: actions/checkout@' "$wf" | head -n1 | cut -d: -f1)"
{ [ -n "$pin_line" ] && [ -n "$first_checkout_line" ] && [ "$pin_line" -lt "$first_checkout_line" ]; } \
  && pass "the pin guard runs before any checkout (guard line $pin_line < checkout line $first_checkout_line)" \
  || fail "the pin guard does not precede the first checkout (guard=${pin_line:-none} checkout=${first_checkout_line:-none})"

# Both checkouts must refuse to persist credentials. The contract engine is
# `python3` from a SEPARATE checkout running in this same workspace, so a token
# left in the consumer's .git/config is inside that engine's blast radius.
# Nothing in this workflow pushes.
checkouts="$(grep -c 'uses: actions/checkout@' "$wf")"
no_persist="$(grep -c 'persist-credentials: false' "$wf")"
{ [ "$checkouts" -gt 0 ] && [ "$no_persist" -eq "$checkouts" ]; } \
  && pass "every checkout sets persist-credentials: false ($no_persist/$checkouts)" \
  || fail "only $no_persist of $checkouts checkouts set persist-credentials: false"

# The two workflows that take a contract_ref must agree on what a pin is. A
# divergence would mean an adopter's ref is a pin in one check and not the other.
sibling="$repo_root/.github/workflows/generated-artifacts.yml"
if [ -f "$sibling" ]; then
  mine="$(grep -o 'ref_is_immutable() { \[\[ "\$1" =~ [^}]*}' "$wf" | head -n1)"
  theirs="$(grep -o 'ref_is_immutable() { \[\[ "\$1" =~ [^}]*}' "$sibling" | head -n1)"
  { [ -n "$mine" ] && [ "$mine" = "$theirs" ]; } \
    && pass "the pin predicate is identical to generated-artifacts.yml's" \
    || fail "the pin predicate has drifted from generated-artifacts.yml (mine='$mine' theirs='$theirs')"
else
  fail "generated-artifacts.yml is missing; cannot pin the shared predicate"
fi

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
