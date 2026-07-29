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

# A hosted fallback may only ever be reached by a caller OUTSIDE Verjson. A
# Verjson-owned job that resolves to `ubuntu-24.04` is not a soft fallback — it
# is a guaranteed failure, because GitHub-hosted minutes are unfunded for this
# org (#189). Every Verjson route must therefore land on self-hosted capacity
# the caller is actually admitted to (ADR 0033).
# The one sanctioned exception is actionlint's `github-hosted-runner` input
# (ADR 0026): hosted there is an explicit per-caller opt-in, never a default a
# Verjson caller can fall into. It is a trap while billing is off — tracked in
# #189 — but it is opt-in, so it is not a silent route.
unsafe_portable="$(
  grep -HnE "^    runs-on:.*ubuntu-(24\\.04|latest)" "$workflows"/*.yml \
    | grep -v "github.repository_owner != 'Verjson' && 'ubuntu-24.04'" \
    | grep -v "inputs.github-hosted-runner" \
    || true
)"
[ -z "$unsafe_portable" ] \
  && pass "hosted fallbacks are reachable only by callers outside Verjson" \
  || fail "hosted fallback reachable by a Verjson caller: $unsafe_portable"

grep -qF "github.repository_owner != 'Verjson'" "$workflows/actionlint.yml" \
  && grep -qF '["self-hosted","isolated","linux","x64"]' "$workflows/actionlint.yml" \
  && pass "actionlint preserves its bounded external hosted compatibility path" \
  || fail "actionlint runner contract drifted"


# --------------------------------------------------------------------------
# Runner routing policy (ADR 0033, supersedes the ADR 0031 allowlist).
#
# Four tiers, resolved in order:
#   1. an explicit `runner` input                      — per-caller override
#   2. caller outside Verjson                          — 'ubuntu-24.04'
#   3. Verjson PRIVATE repository                      — vars.VERJSON_RUNNER_DEFAULT
#   4. anything else (public, or unresolved visibility) — vars.VERJSON_RUNNER_ISOLATED
#
# Tier 4 is the fail-SAFE terminal, not a fallback: if a job's visibility cannot
# be resolved it must land on the ephemeral untrusted-PR lane, never on the
# persistent pool. Getting that backwards would run fork code beside credentials.
#
# Every case below evaluates the REAL `runs-on:` expression awk-extracted from
# the workflow (single source of truth — no copy of any expression lives here).
# --------------------------------------------------------------------------

ISOLATED='["self-hosted","isolated","linux","x64"]'
GENERAL='["self-hosted","GCP"]'

# Extract the `runs-on:` value of one job block, verbatim.
extract_runs_on() {
  awk -v job="  $2:" '
    $0 == job { in_job = 1; next }
    in_job && /^  [^[:space:]#]/ { in_job = 0 }
    in_job && /^    runs-on:/ {
      sub(/^    runs-on:[[:space:]]*/, "")
      print
      exit
    }
  ' "$1"
}

evaluator="$(mktemp)"
trap 'rm -f "$evaluator"' EXIT
cat >"$evaluator" <<'JS'
// Evaluate the GitHub Actions expression subset used by `runs-on:`. The
// operators (&&, ||, ==, !=), single-quoted strings and value-returning
// short-circuit semantics are shared with JavaScript, so the extracted
// expression is evaluated as-is rather than reimplemented.
//
// `private` arrives as 'true' | 'false' | '' — the empty case models an event
// payload that carries no repository visibility, which tier 4 must catch.
const [, , raw, repository, runnerInput, priv, varDefault, varIsolated] = process.argv;
const body = raw.trim().replace(/^\$\{\{/, '').replace(/\}\}$/, '');
const github = {
  repository,
  repository_owner: repository.split('/')[0],
  event: { repository: { private: priv === '' ? undefined : priv === 'true' } },
};
const inputs = { runner: runnerInput };
// An unset Actions variable is the empty string, not undefined.
const vars = { VERJSON_RUNNER_DEFAULT: varDefault, VERJSON_RUNNER_ISOLATED: varIsolated };
const fromJSON = (value) => JSON.parse(value);
// GitHub Actions string equality and contains() are case-insensitive; JS === is not.
// This evaluator is therefore stricter than production.
const contains = (haystack, needle) =>
  Array.isArray(haystack)
    ? haystack.some((item) => item === needle)
    : String(haystack).includes(needle);
const resolved = new Function(
  'github',
  'inputs',
  'vars',
  'fromJSON',
  'contains',
  `return (${body});`,
)(github, inputs, vars, fromJSON, contains);
process.stdout.write(
  typeof resolved === 'string' ? resolved : JSON.stringify(resolved),
);
JS

# A missing evaluator must fail the suite, never silently skip these cases.
if ! command -v node >/dev/null 2>&1; then
  fail "node is required to evaluate the extracted runs-on expression"
  exit 1
fi

# assert_route <workflow> <job> <repo> <runner-input> <private> <var-default> <var-isolated> <expected> <label>
assert_route() {
  local workflow="$1" job="$2" repository="$3" runner_input="$4" priv="$5"
  local var_default="$6" var_isolated="$7" expected="$8" label="$9"
  local expression resolved
  expression="$(extract_runs_on "$workflow" "$job")"
  if [ -z "$expression" ]; then
    fail "could not extract runs-on for job '$job' from $(basename "$workflow")"
    return
  fi
  resolved="$(node "$evaluator" "$expression" "$repository" "$runner_input" \
    "$priv" "$var_default" "$var_isolated" 2>&1)" || {
    fail "$label — evaluating '$expression' failed: $resolved"
    return
  }
  [ "$resolved" = "$expected" ] \
    && pass "$label" \
    || fail "$label (expected '$expected', got '$resolved')"
}

# Every job that carries the policy, across every reusable workflow. A job
# missing from this list is caught by the no-owner-wide-route sweep below.
policy_jobs() {
  cat <<'TARGETS'
node-ci.yml eligibility
node-ci.yml build-test
node-release.yml release
notify-umbrella.yml dispatch
helm-ci.yml lint-template
ui-ci.yml build-test
pulumi-ci.yml validate
pulumi-ci.yml preview-admission
pulumi-ci.yml preview
TARGETS
}

while read -r wf_name job; do
  wf="$workflows/$wf_name"
  name="${wf_name%.yml} $job"

  # Tier 3 — the case that was silently broken: a private Verjson repo used to
  # resolve to hosted (unfunded) or to a pool it is not admitted to (#182/#192).
  assert_route "$wf" "$job" Verjson/verjson-authn '' true '' '' \
    "$GENERAL" "$name — private Verjson repo routes to the general self-hosted pool"

  # Tier 4 — public repos stay on the ephemeral untrusted-PR lane.
  assert_route "$wf" "$job" Verjson/.github '' false '' '' \
    "$ISOLATED" "$name — public Verjson repo routes to the isolated pool"

  # Tier 4 fail-safe — unresolved visibility must NOT reach the persistent pool.
  assert_route "$wf" "$job" Verjson/verjson-authn '' '' '' '' \
    "$ISOLATED" "$name — unresolved visibility falls safe to isolated, not the persistent pool"

  # Tier 2 — the published package stays usable outside the org.
  assert_route "$wf" "$job" Acme/widgets '' true '' '' \
    'ubuntu-24.04' "$name — caller outside Verjson stays portable on hosted"

  # Configuration: the pools are org variables, so a provider migration
  # (GCP -> DigitalOcean) is a variable flip, not a PR to this repository.
  assert_route "$wf" "$job" Verjson/verjson-authn '' true '["self-hosted","do"]' '' \
    '["self-hosted","do"]' "$name — VERJSON_RUNNER_DEFAULT redirects the general pool"

  assert_route "$wf" "$job" Verjson/.github '' false '' '["self-hosted","do-isolated"]' \
    '["self-hosted","do-isolated"]' "$name — VERJSON_RUNNER_ISOLATED redirects the isolated pool"

  # A configured pool must never leak to an external caller's job.
  assert_route "$wf" "$job" Acme/widgets '' true '["self-hosted","do"]' '["self-hosted","do-isolated"]' \
    'ubuntu-24.04' "$name — configured pools do not leak to callers outside Verjson"
done < <(policy_jobs)

# The `runner` input is the per-caller override, but only on the jobs that
# expose it. pulumi-ci's `validate` and `preview-admission` deliberately do not:
# they sit on the credential boundary in ADR 0027/0029, so a caller must not be
# able to redirect them to a pool of its choosing.
while read -r wf_name job; do
  wf="$workflows/$wf_name"
  name="${wf_name%.yml} $job"
  assert_route "$wf" "$job" Verjson/verjson-authn '["self-hosted","manish"]' true '' '' \
    '["self-hosted","manish"]' "$name — explicit runner input wins"
done <<'TARGETS'
node-ci.yml eligibility
node-ci.yml build-test
node-release.yml release
notify-umbrella.yml dispatch
helm-ci.yml lint-template
ui-ci.yml build-test
pulumi-ci.yml preview
TARGETS

for job in validate preview-admission; do
  expr_no_override="$(extract_runs_on "$workflows/pulumi-ci.yml" "$job")"
  case "$expr_no_override" in
    *inputs.runner*)
      fail "pulumi-ci $job must not accept a caller runner override (ADR 0027/0029)" ;;
    '')
      fail "could not extract runs-on for pulumi-ci $job" ;;
    *)
      pass "pulumi-ci $job keeps its credential-boundary runner fixed" ;;
  esac
done

# One policy, nine jobs, six files. Enumerating (file, job) pairs above is not
# enough on its own: a NEW job added to any of these files would escape every
# assertion. This sweep binds the files themselves — no owner-wide isolated
# route, and no route that can put a Verjson caller on hosted, may reappear.
owner_wide="$(
  grep -HnE "^    runs-on:.*github\\.repository_owner == 'Verjson'" \
    "$workflows"/node-ci.yml "$workflows"/node-release.yml \
    "$workflows"/notify-umbrella.yml "$workflows"/helm-ci.yml \
    "$workflows"/ui-ci.yml "$workflows"/pulumi-ci.yml || true
)"
[ -z "$owner_wide" ] \
  && pass "no reusable workflow routes the isolated pool owner-wide" \
  || fail "owner-wide isolated route found: $owner_wide"

# The routing values must stay configurable. A literal pool inlined without its
# `vars` escape hatch is how a provider migration turns back into a code change.
for name in node-ci.yml node-release.yml notify-umbrella.yml helm-ci.yml ui-ci.yml pulumi-ci.yml; do
  wf="$workflows/$name"
  if grep -qF 'vars.VERJSON_RUNNER_DEFAULT' "$wf" \
      && grep -qF 'vars.VERJSON_RUNNER_ISOLATED' "$wf"; then
    pass "$name resolves both pools through configuration"
  else
    fail "$name inlines a runner pool with no vars override"
  fi
done

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
