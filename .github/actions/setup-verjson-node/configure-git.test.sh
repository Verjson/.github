#!/usr/bin/env bash
# Plain-bash tests for configure-git.sh — no external test framework, matching
# the repo's dependency-light scripts convention. Exercises the
# Verjson/verjson-cli-cloud#59 persistent-runner idempotency contract.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/configure-git.sh"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}

# Each case gets an isolated global gitconfig so --global writes a throwaway file.
run() {
  # run <home> <env-file> [CMD-PREFIX ...] — invoke the script with a scoped
  # GIT_CONFIG_GLOBAL and GITHUB_ENV, optionally under an extra env prefix.
  local home="$1" envfile="$2"
  shift 2
  env GIT_CONFIG_GLOBAL="$home/.gitconfig" GITHUB_ENV="$envfile" "$@" bash "$script"
}
gc() {
  # gc <home> <args...> — read the scoped global gitconfig.
  local home="$1"
  shift
  env GIT_CONFIG_GLOBAL="$home/.gitconfig" git config --global "$@"
}

# 1. Cold runner: no prior gitconfig, no tokens -> succeeds, adds both rewrites.
home="$(mktemp -d)"
envf="$(mktemp)"
if run "$home" "$envf"; then
  got="$(gc "$home" --get-all url."https://github.com/".insteadOf | sort | tr '\n' ',')"
  [ "$got" = "git@github.com:,ssh://git@github.com/," ] &&
    pass "cold runner installs both insteadOf rewrites" ||
    fail "cold runner rewrites wrong: $got"
else
  fail "cold runner exited non-zero"
fi

# 2. Persistent runner pre-seeded with a multi-valued insteadOf (#59 Gap 1):
#    a second run must not error and must not duplicate entries.
home="$(mktemp -d)"
envf="$(mktemp)"
gc "$home" --add url."https://github.com/".insteadOf "ssh://git@github.com/"
gc "$home" --add url."https://github.com/".insteadOf "git@github.com:"
run "$home" "$envf" && run "$home" "$envf"
rc=$?
count="$(gc "$home" --get-all url."https://github.com/".insteadOf | wc -l | tr -d ' ')"
{ [ "$rc" -eq 0 ] && [ "$count" = "2" ]; } &&
  pass "re-run over seeded gitconfig is idempotent (rc=$rc, count=$count)" ||
  fail "re-run not idempotent (rc=$rc, count=$count)"

# 3. With a git token: helper installed, token exported, secret NOT on disk.
home="$(mktemp -d)"
envf="$(mktemp)"
run "$home" "$envf" env VERJSON_GIT_TOKEN=s3cr3t-token
helper="$(gc "$home" --get-all credential."https://github.com".helper)"
if grep -q 'VERJSON_GIT_TOKEN=s3cr3t-token' "$envf" &&
  [ -n "$helper" ] &&
  ! grep -q 's3cr3t-token' "$home/.gitconfig"; then
  pass "git token: helper installed, exported, absent from gitconfig"
else
  fail "git token wiring incorrect (helper='$helper')"
fi

# 4. Tokenless run after a tokened one on the same runner: helper is cleared.
run "$home" "$(mktemp)" # reuse home from case 3, which installed a helper
helper="$(gc "$home" --get-all credential."https://github.com".helper || true)"
[ -z "$helper" ] &&
  pass "tokenless run clears a helper left by a prior job" ||
  fail "stale credential helper survived tokenless run: $helper"

# 5. NODE_AUTH_TOKEN is exported to the job env when provided.
home="$(mktemp -d)"
envf="$(mktemp)"
run "$home" "$envf" env NODE_AUTH_TOKEN=npm-tok
grep -q 'NODE_AUTH_TOKEN=npm-tok' "$envf" &&
  pass "NODE_AUTH_TOKEN exported to job env" ||
  fail "NODE_AUTH_TOKEN not exported"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
