#!/usr/bin/env bash
# Unit tests for scripts/classify-repo-stacks.sh against a stubbed `gh`.
#
# The classifier's job is to find repositories the core check contract would
# WEDGE. So the tests that matter are the ones proving it says "nonconformant"
# where a PR-sampling audit would see nothing wrong: a repository whose checks
# are all green and all named something the contract does not require.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/classify-repo-stacks.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - classifier script not found"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/wf"
# Stub `gh`. `--jq` is applied client-side by the real CLI, so a stub that
# ignored it would return raw JSON where the script expects a path list or a
# base64 blob — every repository would scan as empty and classify `none`, and
# the tests would agree with each other while testing nothing.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--jq" ] && filter="${args[$((i + 1))]}"
done
case "$*" in
  *"contents/.github/workflows/"*)
    # One file per repo fixture; return it base64 in a `.content` field.
    # Find the argument that carries the path. `${*##...}` would strip
    # element-wise and yield the FIRST word ("api"), which silently resolves to
    # a missing file and returns empty content — a stub that lies quietly and
    # makes every repository classify as `none`.
    path=""
    for a in "$@"; do case "$a" in */contents/*) path="${a##*contents/}";; esac; done
    f="$WFDIR/$(basename "$path")"
    [ -f "$f" ] || { echo '{"content":""}'; exit 0; }
    jq -n --arg c "$(base64 -w0 <"$f")" '{content:$c}' | { [ -n "$filter" ] && jq -r "$filter" || cat; }
    exit 0 ;;
  *"contents/.github/workflows"*)
    [ "${NO_WORKFLOWS:-false}" = true ] && { echo '[]' | { [ -n "$filter" ] && jq -r "$filter" || cat; }; exit 0; }
    for f in "$WFDIR"/*.yml; do
      [ -e "$f" ] || continue
      jq -n --arg p ".github/workflows/$(basename "$f")" '{type:"file",name:($p|split("/")|last),path:$p}'
    done | jq -s -c '.' | { [ -n "$filter" ] && jq -r "$filter" || cat; }
    exit 0 ;;
  *"orgs/"*"/repos"*)
    printf '%s\n' "${REPOS:-alpha}"; exit 0 ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH"
export WFDIR="$tmp/wf"
export CRS_ORG=Verjson
export CRS_REPOS=alpha

reset_wf() { rm -f "$WFDIR"/*.yml; }
run_crs() { ( bash "$script" >"$tmp/out.txt" 2>&1; echo "rc=$?" ); }
out() { sed 's/^/diag - /' "$tmp/out.txt"; }
said() { grep -q "$1" "$tmp/out.txt"; }

# A caller workflow: job `$1` calls reusable workflow `$2`.
caller() { # $1 = job, $2 = reusable file, $3 = fixture name
  cat >"$WFDIR/$3.yml" <<EOF
name: $3
on: [pull_request]
jobs:
  $1:
    uses: Verjson/.github/.github/workflows/$2@abc123
EOF
}

# --- stack detection via a reusable call ------------------------------------
reset_wf; caller ci node-ci.yml ci
rc="$(run_crs)"
{ [ "$rc" = "rc=0" ] && said 'stack=node' && said 'result=conformant'; } \
  && pass "a repository calling node-ci from a job named 'ci' is node and conformant" \
  || { fail "node stack not detected ($rc)"; out; }

reset_wf; caller ci helm-ci.yml ci
run_crs >/dev/null
said 'stack=helm' \
  && pass "helm-ci maps to the helm stack" \
  || { fail "helm stack not detected"; out; }

# --- THE finding a PR-sampling audit cannot see -----------------------------
# This repository's checks are all green. They are named `build / build-test`,
# so requiring `ci / build-test` leaves it permanently pending — and nothing
# about its check history looks wrong.
reset_wf; caller build node-ci.yml ci
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said 'result=nonconformant' && said "CI caller job is 'build'"; } \
  && pass "a non-canonical CI caller job is reported — its checks look healthy but are named wrong" \
  || { fail "a non-canonical caller job was accepted ($rc)"; out; }

# A canonical caller name is still nonconformant when the reusable call is
# matrixed: GitHub emits `ci (<value>) / build-test`, never
# `ci / build-test`. This is the #431 shape that the uses-only scan missed.
reset_wf
cat >"$WFDIR/ci.yml" <<'EOF'
name: ci
on: [pull_request]
jobs:
  ci:
    strategy:
      matrix:
        node-version: ['20.20.2', '24']
    uses: Verjson/.github/.github/workflows/node-ci.yml@abc123
    with:
      node-version: ${{ matrix.node-version }}
EOF
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said 'result=nonconformant' && said "matrixed CI caller job 'ci'" && said 'ci (<matrix>) / …'; } \
  && pass "a matrixed reusable CI caller is rejected because canonical unmatrixed checks never emit" \
  || { fail "a matrixed reusable CI caller was accepted ($rc)"; out; }

# --- same class, changelog slot ---------------------------------------------
reset_wf; caller ci node-ci.yml ci; caller release changelog-validate.yml cl
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said "changelog caller job is 'release'"; } \
  && pass "a non-canonical changelog caller job is reported" \
  || { fail "a non-canonical changelog job was accepted ($rc)"; out; }

reset_wf; caller ci node-ci.yml ci
cat >"$WFDIR/cl.yml" <<'EOF'
name: changelog
on: [pull_request]
jobs:
  changelog:
    uses: Verjson/.github/.github/workflows/changelog-validate.yml@abc123
    strategy:
      matrix:
        contract: [canonical, compatibility]
EOF
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said "matrixed changelog caller job 'changelog'" && said 'changelog (<matrix>) / validate'; } \
  && pass "matrix detection is independent of whether strategy appears before or after uses" \
  || { fail "a post-uses changelog matrix was accepted ($rc)"; out; }

reset_wf
cat >"$WFDIR/ci.yml" <<'EOF'
name: ci
on: [pull_request]
jobs:
  ci:
    strategy: {matrix: {node-version: ['20', '24']}}
    uses: Verjson/.github/.github/workflows/node-ci.yml@abc123
EOF
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said "matrixed CI caller job 'ci'"; } \
  && pass "a flow-style strategy matrix cannot bypass classification" \
  || { fail "a flow-style matrixed caller was accepted ($rc)"; out; }

# --- package detection -------------------------------------------------------
reset_wf; caller ci node-ci.yml ci; caller changelog changelog-validate.yml cl
rc="$(run_crs)"
{ [ "$rc" = "rc=0" ] && said 'package=yes'; } \
  && pass "calling changelog-validate marks the repository as a package" \
  || { fail "package not detected ($rc)"; out; }

reset_wf; caller ci node-ci.yml ci
run_crs >/dev/null
said 'package=no' \
  && pass "a repository not on the changelog contract is package=no" \
  || { fail "package=no not reported"; out; }

# --- the ADR 0055 generated-artifacts path (#422) ---------------------------
# `generated-artifacts.yml` is the hardened changelog caller: its inner job is
# `validate`, so a caller job named `changelog` emits `changelog / validate`.
# Matching only `changelog-validate.yml` classified adopters `package=no`, so
# the audit stopped requiring the contract of the repositories that migrated.
artifact_caller() { # $1 = job, $2 = fixture name, $3.. = `with:` lines
  local job="$1" name="$2"; shift 2
  { printf 'name: %s\non: [pull_request]\njobs:\n  %s:\n' "$name" "$job"
    printf '    uses: Verjson/.github/.github/workflows/generated-artifacts.yml@abc123\n'
    printf '    with:\n'
    for line in "$@"; do printf '      %s\n' "$line"; done
  } >"$WFDIR/$name.yml"
}

reset_wf; caller ci node-ci.yml ci
artifact_caller changelog ga 'changelog: true' 'contract_ref: 0676948'
rc="$(run_crs)"
{ [ "$rc" = "rc=0" ] && said 'package=yes'; } \
  && pass "a generated-artifacts caller asking for changelog is a package" \
  || { fail "the ADR 0055 changelog path was not recognised ($rc)"; out; }

# The input is what puts a repository on the contract, not the `uses:` line.
# Keying on the workflow name alone would call this a package and then demand
# `changelog / validate` from a repository that never runs the renderer.
reset_wf; caller ci node-ci.yml ci
artifact_caller docs ga 'adr-index: true'
rc="$(run_crs)"
{ [ "$rc" = "rc=0" ] && said 'package=no'; } \
  && pass "a generated-artifacts caller asking only for adr-index is not a package" \
  || { fail "adr-index-only caller was treated as a package ($rc)"; out; }

# Same wedge as the changelog-validate case, reached through the new workflow.
reset_wf; caller ci node-ci.yml ci
artifact_caller release ga 'changelog: true'
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said "changelog caller job is 'release'"; } \
  && pass "a non-canonical generated-artifacts caller job is reported" \
  || { fail "a non-canonical generated-artifacts job was accepted ($rc)"; out; }

# --- a repository that DEFINES contract jobs rather than calling them --------
# The org's own .github repository is where the reusable workflows live, so it
# calls none of them. Classifying it `none` would make the one repository
# holding the merge gate the one whose test suite is not a merge precondition.
reset_wf
cat >"$WFDIR/actions-ci.yml" <<'EOF'
name: actions-ci
on: [pull_request]
jobs:
  shell-tests:
    runs-on: ubuntu-24.04
EOF
rc="$(run_crs)"
{ [ "$rc" = "rc=0" ] && said 'stack=actions'; } \
  && pass "a locally-defined shell-tests job classifies as the actions stack, not none" \
  || { fail "locally-defined contract job was missed ($rc)"; out; }

# --- `none` with local jobs is a review item, not a silent pass -------------
# Under-requiring does not wedge, so this is a warning rather than an error —
# but a repository whose real CI quietly stops being a merge precondition is
# the exact defect this migration must not introduce, so it must be counted
# separately and never reported as plain `conformant`.
reset_wf
cat >"$WFDIR/misc.yml" <<'EOF'
name: misc
on: [push]
jobs:
  greet:
    runs-on: ubuntu-24.04
EOF
rc="$(run_crs)"
{ said 'result=unrecognised-ci' && said 'local_jobs=1' && ! said 'result=conformant'; } \
  && pass "a 'none' repository that defines jobs is flagged for review, not counted conformant" \
  || { fail "unrecognised local CI was silently accepted ($rc)"; out; }

# --- a repository with genuinely no workflows is plain `none` ---------------
reset_wf
rc="$(NO_WORKFLOWS=true run_crs)"
{ [ "$rc" = "rc=0" ] && said 'stack=none' && said 'result=conformant' && ! said 'unrecognised-ci'; } \
  && pass "a repository with no workflows at all is plainly 'none' — nothing to review" \
  || { fail "an empty repository was flagged for review ($rc)"; out; }

# --- two stacks in one repository needs a decision, not a guess -------------
reset_wf; caller ci node-ci.yml a; caller ci helm-ci.yml b
rc="$(run_crs)"
{ [ "$rc" != "rc=0" ] && said 'the contract has no combined stack'; } \
  && pass "a repository calling two stack CI workflows is reported, never silently one of them" \
  || { fail "a two-stack repository was silently classified ($rc)"; out; }

# --- the canonical names are configurable, and actually consulted -----------
# If the comparison were against a hardcoded 'ci', overriding this would not
# change the verdict and the contract could never be renamed.
reset_wf; caller build node-ci.yml ci
rc="$(CRS_CI_JOB=build run_crs)"
{ [ "$rc" = "rc=0" ] && said 'result=conformant'; } \
  && pass "CRS_CI_JOB is consulted, so the canonical name is contract data not a literal" \
  || { fail "the canonical CI job name is hardcoded ($rc)"; out; }

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi
