#!/usr/bin/env bash
# Verjson/.github#173/#174: keep this published workflow package portable
# without allowing Verjson-owned jobs to drift back to GitHub-hosted runners.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflows="$root/.github/workflows"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# A literal job selector in this Verjson-owned repository must never target a
# GitHub-hosted label. Portable fallbacks belong only in organization-aware
# expressions in reusable definitions.
literal_hosted="$(
  grep -HnE '^    runs-on:[[:space:]]+(\[)?ubuntu-(24\.04|latest)([][:space:],]|$)' \
    "$workflows"/*.yml || true
)"
[ -z "$literal_hosted" ] \
  && pass "Verjson-local jobs contain no literal GitHub-hosted runs-on selector" \
  || fail "literal GitHub-hosted selectors found: $literal_hosted"

# Any job-level hosted fallback must prove it is for a caller that cannot use a
# Verjson pool — either outside the organization, or a Verjson repository not
# admitted to the isolated runner group (#182).
unsafe_portable="$(
  grep -HnE "^    runs-on:.*ubuntu-(24\\.04|latest)" "$workflows"/*.yml \
    | grep -v "github.repository_owner != 'Verjson'" \
    | grep -v "github.repository_owner == 'Verjson'.*|| 'ubuntu-24.04'" \
    | grep -vE "contains\(fromJSON\('\[\"Verjson/.*\]'\), github\.repository\).*\|\| 'ubuntu-24\.04'" \
    || true
)"
[ -z "$unsafe_portable" ] \
  && pass "hosted fallbacks are bounded to callers outside Verjson" \
  || fail "unbounded hosted fallback found: $unsafe_portable"

portable=(
  node-ci.yml
  node-release.yml
  notify-umbrella.yml
  helm-ci.yml
  ui-ci.yml
  pulumi-ci.yml
)
for name in "${portable[@]}"; do
  wf="$workflows/$name"
  # The isolated route must be bounded to Verjson callers, either by owner or
  # by the narrower isolated-pool repository allowlist (#182).
  if { grep -qF "github.repository_owner == 'Verjson'" "$wf" \
        || grep -qE "contains\(fromJSON\('\[\"Verjson/.*\]'\), github\.repository\)" "$wf"; } \
      && grep -qF '["self-hosted","isolated","linux","x64"]' "$wf" \
      && grep -qF "'ubuntu-24.04'" "$wf" \
      && grep -qF "default: ''" "$wf"; then
    pass "$name has isolated Verjson, hosted external, and explicit override routing"
  else
    fail "$name lost its portable runner contract"
  fi
done

grep -qF "github.repository_owner != 'Verjson'" "$workflows/actionlint.yml" \
  && grep -qF '["self-hosted","isolated","linux","x64"]' "$workflows/actionlint.yml" \
  && pass "actionlint preserves its bounded external hosted compatibility path" \
  || fail "actionlint runner contract drifted"

# --------------------------------------------------------------------------
# Verjson/.github#182: the isolated pool is `visibility: selected`, so a
# Verjson repo that is NOT in runner group 6's allowlist can never be assigned
# an `isolated` job — it queues until the merge gate times out. Routing must
# therefore key on the onboarded repository, not on the owner.
#
# These cases evaluate the REAL `runs-on:` expression awk-extracted from
# node-ci.yml (single source of truth — no copy of the expression lives here).
# --------------------------------------------------------------------------
node_ci="$workflows/node-ci.yml"

# Extract the `runs-on:` value of one job block, verbatim.
extract_runs_on() {
  awk -v job="  $1:" '
    $0 == job { in_job = 1; next }
    in_job && /^  [^[:space:]#]/ { in_job = 0 }
    in_job && /^    runs-on:/ {
      sub(/^    runs-on:[[:space:]]*/, "")
      print
      exit
    }
  ' "$node_ci"
}

evaluator="$(mktemp)"
trap 'rm -f "$evaluator"' EXIT
cat >"$evaluator" <<'JS'
// Evaluate the GitHub Actions expression subset used by `runs-on:`. The
// operators (&&, ||, ==, !=), single-quoted strings and value-returning
// short-circuit semantics are shared with JavaScript, so the extracted
// expression is evaluated as-is rather than reimplemented.
const [, , raw, repository, runnerInput] = process.argv;
const body = raw.trim().replace(/^\$\{\{/, '').replace(/\}\}$/, '');
const github = { repository, repository_owner: repository.split('/')[0] };
const inputs = { runner: runnerInput };
const fromJSON = (value) => JSON.parse(value);
const contains = (haystack, needle) =>
  Array.isArray(haystack)
    ? haystack.some((item) => item === needle)
    : String(haystack).includes(needle);
const resolved = new Function(
  'github',
  'inputs',
  'fromJSON',
  'contains',
  `return (${body});`,
)(github, inputs, fromJSON, contains);
process.stdout.write(
  typeof resolved === 'string' ? resolved : JSON.stringify(resolved),
);
JS

# A missing evaluator must fail the suite, never silently skip these cases.
if ! command -v node >/dev/null 2>&1; then
  fail "node is required to evaluate the extracted runs-on expression"
fi

assert_route() {
  local job="$1" repository="$2" runner_input="$3" expected="$4" label="$5"
  local expression resolved
  expression="$(extract_runs_on "$job")"
  if [ -z "$expression" ]; then
    fail "could not extract runs-on for job '$job' from node-ci.yml"
    return
  fi
  resolved="$(node "$evaluator" "$expression" "$repository" "$runner_input" 2>&1)" || {
    fail "$label — evaluating '$expression' failed: $resolved"
    return
  }
  [ "$resolved" = "$expected" ] \
    && pass "$label" \
    || fail "$label (expected '$expected', got '$resolved')"
}

for job in eligibility build-test; do
  assert_route "$job" Verjson/verjson-authn '' 'ubuntu-24.04' \
    "node-ci $job — Verjson repo outside the isolated allowlist falls back to hosted (#182)"

  assert_route "$job" Verjson/verjson-cli '' '["self-hosted","isolated","linux","x64"]' \
    "node-ci $job — allowlisted Verjson repo still routes to the isolated pool"

  assert_route "$job" Acme/widgets '' 'ubuntu-24.04' \
    "node-ci $job — caller outside Verjson stays portable on hosted"

  # The `runner` input remains the per-caller override on both sides of the
  # allowlist: an onboarded repo can still select a persistent pool, and a
  # non-onboarded one is not forced onto hosted.
  assert_route "$job" Verjson/verjson-cli '["self-hosted","GCP"]' '["self-hosted","GCP"]' \
    "node-ci $job — explicit runner input overrides the isolated default"

  assert_route "$job" Verjson/verjson-authn '["self-hosted","manish"]' '["self-hosted","manish"]' \
    "node-ci $job — explicit runner input overrides the hosted fallback"
done

# One routing policy, two jobs: they must never drift apart. GitHub Actions has
# no YAML anchors and `runs-on` cannot read the `env` context, so byte equality
# enforced here is what keeps the allowlist single-sourced.
eligibility_expr="$(extract_runs_on eligibility)"
build_test_expr="$(extract_runs_on build-test)"
[ -n "$eligibility_expr" ] && [ "$eligibility_expr" = "$build_test_expr" ] \
  && pass "node-ci eligibility and build-test share one byte-identical runs-on expression" \
  || fail "node-ci runs-on expressions drifted: '$eligibility_expr' vs '$build_test_expr'"

# Admission is a Verjson-owned boundary: no foreign repository may be granted
# the self-hosted pool through this expression.
foreign_grant="$(
  printf '%s\n' "$eligibility_expr" \
    | grep -oE '"[^"]+/[^"]+"' \
    | grep -v '^"Verjson/' \
    || true
)"
[ -z "$foreign_grant" ] \
  && pass "node-ci isolated allowlist admits only Verjson-owned repositories" \
  || fail "non-Verjson repository in the isolated allowlist: $foreign_grant"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
