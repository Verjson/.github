#!/usr/bin/env bash
# Verjson/.github#404 — the shared generated-artifact validation workflow.
#
# House method: awk-extract the exact `run:` block from
# .github/workflows/generated-artifacts.yml (single source of truth — no copy of
# the logic lives here) and execute it against fixture repositories.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/generated-artifacts.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# The `run:` block of the step carrying `id: <step>`, dedented to column 0.
extract() { # extract <step-id> <destination>
  awk -v want="        id: $1" '
    $0 == want { seen = 1 }
    seen && $0 == "        run: |" { cap = 1; next }
    cap && $0 ~ /^      - name:/ { exit }
    cap {
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      exit
    }
  ' "$wf" >"$2"
}

validate="$tmp/validate.sh"
extract validate "$validate"
[ -s "$validate" ] \
  || { echo "FAIL - could not extract the validate run block from $wf"; exit 1; }

# A consumer repository carrying a real, current ADR index.
make_adr_repo() { # make_adr_repo <path>
  local ws="$1"
  mkdir -p "$ws/scripts" "$ws/docs/decisions/0001-example"
  cp "$repo_root/scripts/gen-adr-index.sh" "$ws/scripts/gen-adr-index.sh"
  cat >"$ws/docs/decisions/0001-example/README.md" <<'ADR'
# 0001 — Example decision

- **Date:** 2026-08-05
ADR
  cat >"$ws/docs/decisions/README.md" <<'INDEX'
# Decisions

<!-- BEGIN ADR INDEX -->
<!-- END ADR INDEX -->
INDEX
  bash "$ws/scripts/gen-adr-index.sh" >/dev/null
}

run_validate() { # run_validate <workspace> [env assignments...]
  local ws="$1"
  shift
  ( cd "$ws" && env GITHUB_WORKSPACE="$ws" GITHUB_STEP_SUMMARY="$ws/summary.md" \
      RUN_ADR_INDEX=false RUN_CHANGELOG=false CONTRACT_DIR=.changelog-contract \
      CONTRACT_REF='' LEGACY_DIR='' BASE_SHA='' HEAD_SHA='' \
      "$@" bash "$validate" 2>&1 )
}

# --------------------------------------------------------------------------
# Clean: the committed artifact matches what the generator produces.
# --------------------------------------------------------------------------
ws="$tmp/clean"
make_adr_repo "$ws"
out="$(run_validate "$ws" RUN_ADR_INDEX=true)"
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a current ADR index passes the adr-index check" \
  || fail "a current ADR index was rejected (rc=$rc): $out"

# --------------------------------------------------------------------------
# Stale: the generator produces something other than what is committed. The
# whole point of centralising this is that the consumer is told WHICH generator
# to re-run, so a failing job is actionable without opening the workflow.
# --------------------------------------------------------------------------
ws="$tmp/stale"
make_adr_repo "$ws"
mkdir -p "$ws/docs/decisions/0002-added-later"
cat >"$ws/docs/decisions/0002-added-later/README.md" <<'ADR'
# 0002 — A decision whose row was never generated

- **Date:** 2026-08-05
ADR
out="$(run_validate "$ws" RUN_ADR_INDEX=true)"
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a stale ADR index fails the adr-index check" \
  || fail "a stale ADR index passed — the check is fail-open"

# Asserted on the workflow's OWN report, not on whatever the generator happened
# to print: `gen-adr-index.sh --check` already names itself on stderr, so a
# looser grep passes without the shared workflow reporting anything at all.
grep -q '::error title=Generated artifact out of date: ADR index::' <<<"$out" \
  && pass "the failure is reported in the workflow's uniform annotation form" \
  || fail "no uniform failure annotation for the ADR index: $out"

grep -qE '^ +bash scripts/gen-adr-index\.sh$' "$ws/summary.md" \
  && pass "the job summary names the generator command to re-run" \
  || fail "the job summary does not name the generator: $(cat "$ws/summary.md")"

# --------------------------------------------------------------------------
# Missing: the caller opted into a check whose generator the repository does not
# have. That is a caller mistake, not a clean repository — it must fail, and it
# must not be reported as "stale", which sends the consumer to regenerate a file
# with a script that is not there.
# --------------------------------------------------------------------------
ws="$tmp/missing"
make_adr_repo "$ws"
rm -f "$ws/scripts/gen-adr-index.sh"
out="$(run_validate "$ws" RUN_ADR_INDEX=true)"
rc=$?
[ "$rc" -ne 0 ] \
  && pass "an absent generator fails the check instead of passing vacuously" \
  || fail "adr-index passed with no scripts/gen-adr-index.sh — the check is fail-open"

grep -q '::error title=Generated artifact check unavailable: ADR index::' <<<"$out" \
  && pass "an absent generator is reported as unavailable, not as stale" \
  || fail "an absent generator is misreported: $out"

grep -q 'scripts/gen-adr-index.sh' "$ws/summary.md" \
  && pass "the report names the script the repository is missing" \
  || fail "the report does not name the missing script: $(cat "$ws/summary.md")"

# --------------------------------------------------------------------------
# Every check off. Booleans default to false, so a caller that mistypes an input
# name — or copies the caller before deciding what to check — gets a workflow
# that validates nothing and reports green. That is the fail-open shape this
# workflow exists to remove, so it is an error rather than a no-op.
# --------------------------------------------------------------------------
ws="$tmp/nothing"
make_adr_repo "$ws"
out="$(run_validate "$ws")"
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a call with every check disabled fails instead of reporting a green no-op" \
  || fail "a call that validates nothing passed green: $out"

grep -q 'no generated-artifact check was enabled' <<<"$out" \
  && pass "the empty-call failure says which input to set" \
  || fail "the empty-call failure is not explained: $out"

# A consumer repository on the canonical changelog contract, with the contract
# checked out where the workflow's own checkout step puts it.
make_changelog_repo() { # make_changelog_repo <path>
  local ws="$1"
  mkdir -p "$ws/NEXT" "$ws/.changelog-contract/scripts"
  cp "$repo_root/scripts/changelog.py" "$ws/.changelog-contract/scripts/changelog.py"
  cat >"$ws/NEXT/2026-08-05-issue-404-example.md" <<'FRAGMENT'
---
date: 2026-08-05
issue: 404
title: Example
---

Body text.
FRAGMENT
}

# --------------------------------------------------------------------------
# Clean: unreleased fragments parse and render under the pinned contract.
# --------------------------------------------------------------------------
ws="$tmp/changelog-clean"
make_changelog_repo "$ws"
out="$(run_validate "$ws" RUN_CHANGELOG=true CONTRACT_REF=0123456789abcdef0123456789abcdef01234567)"
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a repository with valid fragments passes the changelog check" \
  || fail "valid fragments were rejected (rc=$rc): $out"

# --------------------------------------------------------------------------
# Stale: a fragment the canonical engine rejects.
# --------------------------------------------------------------------------
ws="$tmp/changelog-stale"
make_changelog_repo "$ws"
printf 'no front matter here\n' >"$ws/NEXT/2026-08-05-issue-404-broken.md"
out="$(run_validate "$ws" RUN_CHANGELOG=true CONTRACT_REF=0123456789abcdef0123456789abcdef01234567)"
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a fragment the contract rejects fails the changelog check" \
  || fail "an invalid fragment passed — the changelog check is fail-open: $out"

grep -q '::error title=Generated artifact out of date: Changelog::' <<<"$out" \
  && pass "the changelog failure uses the same uniform annotation" \
  || fail "the changelog failure is not reported uniformly: $out"

# --------------------------------------------------------------------------
# Missing: the contract checkout did not land the engine. Fails as unavailable
# and names contract_ref, because "your fragments are wrong" would be a lie.
# --------------------------------------------------------------------------
ws="$tmp/changelog-missing"
make_changelog_repo "$ws"
rm -rf "$ws/.changelog-contract"
out="$(run_validate "$ws" RUN_CHANGELOG=true CONTRACT_REF=0123456789abcdef0123456789abcdef01234567)"
rc=$?
[ "$rc" -ne 0 ] \
  && pass "an absent contract engine fails instead of passing vacuously" \
  || fail "the changelog check passed with no contract checkout: $out"

grep -q '::error title=Generated artifact check unavailable: Changelog::' <<<"$out" \
  && grep -q 'contract_ref' <<<"$out" \
  && pass "an absent contract engine is reported as unavailable and names contract_ref" \
  || fail "an absent contract engine is misreported: $out"

# --------------------------------------------------------------------------
# The changelog check is meaningless without a pin, and an unpinned checkout
# would silently validate against whatever Verjson/.github@HEAD happens to be.
# --------------------------------------------------------------------------
ws="$tmp/changelog-unpinned"
make_changelog_repo "$ws"
out="$(run_validate "$ws" RUN_CHANGELOG=true)"
rc=$?
[ "$rc" -ne 0 ] && grep -q 'contract_ref' <<<"$out" \
  && pass "changelog without contract_ref fails and says which input is missing" \
  || fail "changelog ran unpinned (rc=$rc): $out"

# --------------------------------------------------------------------------
# Two broken artifacts, one run. Checks accumulate rather than short-circuit, so
# a consumer fixes both in one round instead of learning about the second only
# after paying for another CI run.
# --------------------------------------------------------------------------
ws="$tmp/both-broken"
make_adr_repo "$ws"
make_changelog_repo "$ws"
mkdir -p "$ws/docs/decisions/0002-added-later"
cat >"$ws/docs/decisions/0002-added-later/README.md" <<'ADR'
# 0002 — A decision whose row was never generated

- **Date:** 2026-08-05
ADR
printf 'no front matter here\n' >"$ws/NEXT/2026-08-05-issue-404-broken.md"
out="$(run_validate "$ws" RUN_ADR_INDEX=true RUN_CHANGELOG=true \
  CONTRACT_REF=0123456789abcdef0123456789abcdef01234567)"
rc=$?
[ "$rc" -ne 0 ] \
  && grep -q 'out of date: ADR index' <<<"$out" \
  && grep -q 'out of date: Changelog' <<<"$out" \
  && pass "both failing checks are reported in one run" \
  || fail "the run stops at the first failure (rc=$rc): $out"

# --------------------------------------------------------------------------
# legacy_dir is a pass-through to the contract engine, not decoration: a
# repository mid-migration keeps its fragments elsewhere, and dropping the value
# would validate an empty set and report green.
# --------------------------------------------------------------------------
ws="$tmp/legacy"
make_changelog_repo "$ws"
mkdir -p "$ws/legacy-next"
printf 'no front matter here\n' >"$ws/legacy-next/2026-08-05-issue-404-broken.md"
out="$(run_validate "$ws" RUN_CHANGELOG=true LEGACY_DIR=legacy-next \
  CONTRACT_REF=0123456789abcdef0123456789abcdef01234567)"
rc=$?
[ "$rc" -ne 0 ] \
  && pass "legacy_dir reaches the contract engine, so its fragments are validated too" \
  || fail "legacy_dir was dropped — fragments there are never checked: $out"

# --------------------------------------------------------------------------
# The boundary itself (#404). Checks are ENUMERATED opt-ins: a caller names a
# supported artifact, never a command. An input that reached the shell as code
# would turn every consumer's workflow file into a remote-execution surface on
# the shared runner pool, which is the one thing this workflow must not become.
# --------------------------------------------------------------------------
declared_inputs="$(awk '
  /^  workflow_call:/ { in_call = 1; next }
  in_call && /^    inputs:/ { in_inputs = 1; next }
  in_inputs && /^[a-z]/ { exit }
  in_inputs && /^      [a-z][a-z_-]*:$/ {
    gsub(/[ :]/, "")
    print
  }
' "$wf")"
expected_inputs="$(printf '%s\n' adr-index changelog contract_ref legacy_dir runner | sort)"
[ "$(printf '%s\n' "$declared_inputs" | sort)" = "$expected_inputs" ] \
  && pass "the input surface is exactly the enumerated set" \
  || fail "input surface drifted: got [$(printf '%s' "$declared_inputs" | tr '\n' ' ')] want [$(printf '%s' "$expected_inputs" | tr '\n' ' ')]"

# Both artifact selectors are booleans, so `adr-index: rm -rf /` is not even a
# type-valid call — the rejection is GitHub's, before any shell starts.
for boolean in adr-index changelog; do
  awk -v want="      $boolean:" '
    $0 == want { seen = 1; next }
    seen && /^      [a-z]/ { exit }
    seen { print }
  ' "$wf" | grep -q '^        type: boolean$' \
    && pass "$boolean is typed boolean, so it cannot carry a command" \
    || fail "$boolean is not declared as a boolean input"
done

# No input value is interpolated into the script body, and nothing eval's one.
# Values arrive through `env:`, where the shell treats them as data.
grep -q '\${{' "$validate" \
  && fail "the validate script interpolates an expression into its body: $(grep '\${{' "$validate")" \
  || pass "no workflow expression is interpolated into the script body"

grep -qE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$validate" \
  && fail "the validate script eval's a value" \
  || pass "the validate script never eval's an input"

# --------------------------------------------------------------------------
# Folded, not duplicated (#404). Where the generated artifact IS the changelog,
# this runs the canonical engine from the pinned contract — the same commands
# changelog-validate.yml runs — instead of adding a second render pass.
# --------------------------------------------------------------------------
canonical="$repo_root/.github/workflows/changelog-validate.yml"
grep -qF '.changelog-contract/scripts/changelog.py' "$validate" \
  && pass "the changelog check runs the engine from the pinned contract checkout" \
  || fail "the changelog check does not use the pinned contract engine"

for subcommand in validate check-pr; do
  grep -qF "changelog.py $subcommand" "$canonical" && grep -qF "\"\$engine\" $subcommand" "$validate" \
    && pass "the changelog check runs the canonical '$subcommand' subcommand" \
    || fail "the changelog check and changelog-validate.yml disagree on '$subcommand'"
done

grep -qE 'render-next' "$validate" \
  && fail "the changelog check adds a second render pass on top of validate" \
  || pass "renderability is established by validate alone — the renderer runs once"

# --------------------------------------------------------------------------
# Plumbing the shared workflow owns so no consumer hand-writes it again.
# --------------------------------------------------------------------------
grep -qxF 'permissions:' "$wf" && grep -qxF '  contents: read' "$wf" \
  && pass "the shared workflow pins read-only permissions" \
  || fail "the shared workflow does not pin contents: read"

grep -qE '^    timeout-minutes: [0-9]+$' "$wf" \
  && pass "the job carries a timeout" \
  || fail "the job has no timeout, so a hung generator holds a runner"

checkouts="$(grep -cE '^        uses: actions/checkout@[0-9a-f]{40} # v[0-9]+$' "$wf")"
[ "$checkouts" -eq "$(grep -cE '^        uses: actions/checkout@' "$wf")" ] \
  && [ "$checkouts" -ge 1 ] \
  && pass "every checkout is pinned to a full commit SHA" \
  || fail "a checkout is not pinned by SHA"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
