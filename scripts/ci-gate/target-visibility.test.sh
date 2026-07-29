#!/usr/bin/env bash
# Pins the "Resolve target repo visibility" step in ai-review-merge.yml
# (Verjson/.github#170). `runs-on` expressions only see event/inputs context, so
# on the workflow_dispatch re-gate path the gate job would otherwise route on the
# DISPATCHING repo's visibility, not the target's. This step resolves the
# org-guarded TARGET_REPO with `gh` and publishes `target_private` for the gate
# job's `runs-on` ternary.
#
# The load-bearing case is the failure one: an unreadable/erroring target must
# leave the output EMPTY, because the gate routes the isolated pool only on the
# exact string 'false' and falls back to the operator-only `gate` pool for
# anything else. If a lookup failure ever aborted the step, or leaked a
# truthy-looking value, routing would fail OPEN onto the wrong pool. Extracts the
# real `run:` block from the workflow (single source of truth) and drives it with
# a stubbed `gh`. Plain bash + awk; no test-framework or YAML-library dependency
# (runs on the bare self-hosted pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }

# Extract the step's run script verbatim (10-space-indented body after `run: |`,
# scoped to the step whose `id:` is target_visibility).
script="$tmp/target-visibility.sh"
awk '
  $0 == "        id: target_visibility" { seen = 1 }
  seen && !cap && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit  # end of this step: stop before the next step re-arms capture
  }
' "$wf" >"$script"
if ! grep -q 'target_private' "$script" || ! grep -q 'gh api' "$script"; then
  echo "FAIL - could not extract the target_visibility run block from $wf"
  exit 1
fi

# Stub `gh` on PATH: GH_STUB_OUT is what `gh api ... --jq .private` prints,
# GH_STUB_RC its exit status (nonzero simulating an unreadable/erroring target).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "${GH_STUB_RC:-0}" -ne 0 ]; then
  echo "HTTP 404: Not Found (https://api.github.com/repos/${TARGET_REPO:-})" >&2
  exit "$GH_STUB_RC"
fi
printf '%s\n' "${GH_STUB_OUT:-}"
GH
chmod +x "$tmp/bin/gh"

run_step() {
  # run_step <gh-stdout> <gh-rc>
  export PATH="$tmp/bin:$PATH"
  export TARGET_REPO="Verjson/.github"
  export RUNNER_TEMP="$tmp/runner-temp"
  export GITHUB_OUTPUT="$tmp/github-output.txt"
  mkdir -p "$RUNNER_TEMP"
  : >"$GITHUB_OUTPUT"
  export GH_STUB_OUT="$1" GH_STUB_RC="$2"
  bash "$script" >"$tmp/out.txt" 2>&1
  echo "rc=$?"
}
output_has() { grep -qxF "$1" "$tmp/github-output.txt"; }
log_has() { grep -q "$1" "$tmp/out.txt"; }

# (a) A public target resolves to 'false' — the only value that routes the gate
# job onto the isolated pool.
rc="$(run_step 'false' 0)"
{ [ "$rc" = "rc=0" ] && output_has 'target_private=false'; } \
  && pass "public target publishes target_private=false" \
  || fail "public target did not publish target_private=false ($rc)"

# (b) A private target resolves to 'true' → gate pool.
rc="$(run_step 'true' 0)"
{ [ "$rc" = "rc=0" ] && output_has 'target_private=true'; } \
  && pass "private target publishes target_private=true" \
  || fail "private target did not publish target_private=true ($rc)"

# (c) A failed lookup must NOT abort the required preflight job and must publish
# an EMPTY value with a ::warning — routing then fails closed to the gate pool.
rc="$(run_step '' 1)"
{ [ "$rc" = "rc=0" ] && output_has 'target_private=' && log_has '::warning::'; } \
  && pass "failed lookup exits 0 and publishes an empty target_private (fail closed, #170)" \
  || fail "failed lookup aborted the step or published a non-empty value ($rc)"

# (d) The gate job must consume that contract: route the isolated pool only on
# the exact 'false', so '' (and 'true') fall back to the `gate` pool.
gate_routing="$(grep -n "needs.preflight.outputs.target_private == 'false'" "$wf" || true)"
{ [ -n "$gate_routing" ] && grep -q "target_private: \${{ steps.target_visibility.outputs.target_private }}" "$wf"; } \
  && pass "gate runs-on routes on the exact 'false', so an empty value stays on the gate pool" \
  || fail "gate runner routing no longer keys off target_visibility's 'false' contract"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
