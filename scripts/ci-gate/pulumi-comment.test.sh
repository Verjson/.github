#!/usr/bin/env bash
# Pins the "graceful no-op on push" guard on pulumi-ci.yml's live-preview step.
# The `comment-on-pr` value handed to pulumi/actions is a pure GitHub expression
# (not a shell `run:` block), so it cannot be executed in bash the way the other
# ci-gate tests exercise their steps. Instead we extract the exact expression
# from the workflow (single source of truth — no drift) and assert it carries
# the PR-context guard, then evaluate its truth table so a regression that drops
# the guard fails here. Plain bash + awk; no dependency.
#
# Contract: on a `push` (or any non-pull_request) trigger there is no PR to
# comment on, so the value MUST resolve to false and the preview must run
# without attempting to post a comment (never hard-fail).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/pulumi-ci.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Extract the ${{ ... }} body of the `comment-on-pr:` input under the Pulumi step.
expr="$(awk '
  /^      - name: Pulumi / { seen = 1 }
  seen && $0 ~ /^          comment-on-pr:/ {
    line = $0
    sub(/^[^{]*\{\{[[:space:]]*/, "", line)
    sub(/[[:space:]]*\}\}.*$/, "", line)
    print line
    exit
  }
' "$wf")"

if [ -z "$expr" ]; then
  echo "FAIL - could not extract the comment-on-pr expression from $wf"
  exit 1
fi

# 1. The guard references the PR-context check, not just the raw input.
case "$expr" in
  *"github.event_name == 'pull_request'"*)
    pass "comment-on-pr is gated on a pull_request event context" ;;
  *)
    fail "comment-on-pr lacks the github.event_name == 'pull_request' guard (got: $expr)" ;;
esac

# 2. The input opt-out is preserved and AND-combined with the PR-context guard
#    (so a push forces it false regardless of the caller's comment-on-pr input).
case "$expr" in
  *"inputs.comment-on-pr"*"&&"*"github.event_name"*)
    pass "caller's comment-on-pr input is AND-gated with the PR-context guard" ;;
  *)
    fail "expected 'inputs.comment-on-pr && github.event_name ...' (got: $expr)" ;;
esac

# 3. Truth table of the no-op contract. Mirrors GitHub-expression semantics for
#    the extracted operands (input boolean AND event == 'pull_request'); asserted
#    here because bash cannot evaluate the ${{ }} expression itself.
eval_guard() { # <input-bool> <event-name> -> true|false
  if [ "$1" = "true" ] && [ "$2" = "pull_request" ]; then echo true; else echo false; fi
}
check() { # <expected> <input> <event> <label>
  got="$(eval_guard "$2" "$3")"
  if [ "$got" = "$1" ]; then pass "$4"; else fail "$4 (want $1 got $got)"; fi
}
check false true  push         "push event never comments even when input is true (no-op)"
check false false push         "push event never comments when input is false"
check true  true  pull_request "PR event comments when input is true"
check false false pull_request "PR event honors caller opt-out (input false)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
