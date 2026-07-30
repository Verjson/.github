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
    | grep -v "github.repository_owner == 'Verjson'.*|| 'ubuntu-24.04'" \
    | grep -v "inputs.github-hosted-runner" \
    || true
)"
[ -z "$unsafe_portable" ] \
  && pass "hosted fallbacks are reachable only by callers outside Verjson" \
  || fail "hosted fallback reachable by a Verjson caller: $unsafe_portable"

grep -qF "github.repository_owner != 'Verjson'" "$workflows/actionlint.yml" \
  && grep -qF '["self-hosted","general"]' "$workflows/actionlint.yml" \
  && pass "actionlint preserves its bounded external hosted compatibility path" \
  || fail "actionlint runner contract drifted"

grep -qF 'runs-on: [self-hosted, general]' "$workflows/actions-ci.yml" \
  && pass "repository shell validation uses the temporary general pool" \
  || fail "actions-ci drifted from the temporary ADR 0034 runner exception"

for local_workflow in \
  node-cache-integration.yml \
  rework-reconcile.yml \
  runner-admission-reconcile.yml \
  tag-major.yml; do
  if grep -E '^    runs-on:' "$workflows/$local_workflow" \
      | grep -qvF 'runs-on: [self-hosted, general]'; then
    fail "$local_workflow contains a repository-local job outside the general lane"
  else
    pass "$local_workflow keeps every repository-local job on the general lane"
  fi
done


# --------------------------------------------------------------------------
# Runner routing policy (ADR 0033, supersedes the ADR 0031 allowlist).
#
# Three tiers, resolved in order:
#   1. an explicit `runner` input                      — per-caller override
#   2. caller outside Verjson                          — 'ubuntu-24.04'
#   3. private Verjson repository                     — default org variable
#   4. public or unresolved Verjson repository        — untrusted org variable
#
# Every case below evaluates the REAL `runs-on:` expression awk-extracted from
# the workflow (single source of truth — no copy of any expression lives here).
# --------------------------------------------------------------------------

GENERAL='["self-hosted","general"]'

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
//
// Actions compares mixed types by coercing to number (null -> 0, false -> 0,
// true -> 1), so `null == false` is TRUE there while JS `null == false` is
// false. Modelling unresolved visibility as 0 rather than undefined/null makes
// JS's own loose `==` agree with Actions on BOTH polarities: 0 == true is
// false, 0 == false is true. That matters because ai-review-merge.yml already
// makes this same decision with `== false`; a future flip here must be
// validated against real semantics, not against a model that only happens to
// agree with the polarity in use today.
const vm = require('node:vm');
const [, , raw, repository, runnerInput, priv, varDefault, varUntrusted] = process.argv;
const body = raw.trim().replace(/^\$\{\{/, '').replace(/\}\}$/, '');
const github = {
  repository,
  repository_owner: repository.split('/')[0],
  event: { repository: { private: priv === '' ? 0 : priv === 'true' } },
};
const inputs = { runner: runnerInput };
// An unset Actions variable is the empty string, not undefined.
const vars = {
  VERJSON_RUNNER_DEFAULT: varDefault,
  VERJSON_RUNNER_UNTRUSTED: varUntrusted,
  // Privileged routing prefers an isolated lane and then the default lane.
  // Existing evaluator call sites provide one private-lane fixture, so use it
  // for both names; structural assertions below pin the preference order.
  VERJSON_RUNNER_ISOLATED: varDefault,
};
const fromJSON = (value) => JSON.parse(value);
// GitHub Actions string equality and contains() are case-insensitive; JS === is not.
// This evaluator is therefore stricter than production. `contains` is kept even
// though the routing expressions no longer use it (the ADR 0031 allowlist is
// retired) because ai-review-merge.yml still does, and this evaluator is the
// obvious thing to reach for the next time a runs-on expression needs checking.
const contains = (haystack, needle) =>
  Array.isArray(haystack)
    ? haystack.some((item) => item === needle)
    : String(haystack).includes(needle);

// Evaluate in a fresh vm context rather than `new Function` (#187). The input is
// awk-extracted from workflow files in this repository, so it is not untrusted
// today — anyone who can edit those can already edit this .test.sh, which bash
// executes outright. The change is about the pattern, not this call site: a
// context built from a null-prototype object exposes no `process`, `require`,
// `fetch`, or module loader, so the same helper stays safe if it is ever pointed
// at a workflow from a fork or another org.
//
// This is hardening, not a security boundary — Node documents `vm` as not a
// sandbox against hostile code. What it does buy: ambient authority is gone by
// construction, and the timeout bounds a pathological expression instead of
// hanging CI.
const context = vm.createContext(
  Object.assign(Object.create(null), { github, inputs, vars, fromJSON, contains }),
);
const resolved = vm.runInContext(`(${body})`, context, {
  timeout: 5000,
  filename: 'runs-on-expression',
});
process.stdout.write(
  typeof resolved === 'string' ? resolved : JSON.stringify(resolved),
);
JS

# A missing evaluator must fail the suite, never silently skip these cases.
if ! command -v node >/dev/null 2>&1; then
  fail "node is required to evaluate the extracted runs-on expression"
  exit 1
fi

# The evaluator must carry no ambient authority (#187). These probes are what
# stops a future revert to `new Function` for ambient globals such as `process`;
# the `require` probe separately documents that neither evaluator exposes the
# CommonJS wrapper's module-local loader.
assert_no_ambient() {
  local expression="$1" symbol="$2"
  local out
  out="$(node "$evaluator" "$expression" Verjson/example '' true '' '' 2>&1)" && {
    fail "evaluator resolved '$symbol' instead of rejecting it: $out"
    return
  }
  case "$out" in
    *"$symbol is not defined"*) pass "evaluator context exposes no $symbol" ;;
    *) fail "evaluator rejected '$symbol' for the wrong reason: $out" ;;
  esac
}

assert_no_ambient '${{ process.env.HOME }}' process
assert_no_ambient '${{ require("node:fs") }}' require

# assert_route <workflow> <job> <repo> <runner-input> <private> <var-default> <var-untrusted> <expected> <label>
assert_route() {
  local workflow="$1" job="$2" repository="$3" runner_input="$4" priv="$5"
  local var_default="$6" var_untrusted="$7" expected="$8" label="$9"
  local expression resolved
  expression="$(extract_runs_on "$workflow" "$job")"
  if [ -z "$expression" ]; then
    fail "could not extract runs-on for job '$job' from $(basename "$workflow")"
    return
  fi
  resolved="$(node "$evaluator" "$expression" "$repository" "$runner_input" \
    "$priv" "$var_default" "$var_untrusted" 2>&1)" || {
    fail "$label — evaluating '$expression' failed: $resolved"
    return
  }
  [ "$resolved" = "$expected" ] \
    && pass "$label" \
    || fail "$label (expected '$expected', got '$resolved')"
}

# The split merger has two declarations during the compatibility window: an
# inert reusable-file declaration and the live pull_request_target workflow.
# Evaluate both owner branches instead of rejecting the hosted label text:
# Verjson must always resolve to an isolated/default self-hosted pool, while an
# external consumer keeps the required portable hosted route.
for privileged_workflow in ai-privileged-merge.yml; do
  privileged_path="$workflows/$privileged_workflow"
  grep -qF 'VERJSON_RUNNER_ISOLATED || vars.VERJSON_RUNNER_DEFAULT' "$privileged_path" \
    && pass "$privileged_workflow privileged job prefers isolated then default" \
    || fail "$privileged_workflow privileged job lost isolated/default preference"

  assert_route "$privileged_path" privileged_merge Verjson/.github '' false \
    '["self-hosted","isolated-canary"]' '["self-hosted","untrusted-canary"]' \
    '["self-hosted","isolated-canary"]' \
    "$privileged_workflow — Verjson privileged merge cannot reach hosted"

  assert_route "$privileged_path" privileged_merge Verjson/.github '' false '' '' \
    '["self-hosted","gate"]' \
    "$privileged_workflow — missing Verjson variables fall back to the gate pool"

  assert_route "$privileged_path" privileged_merge Acme/widgets '' true \
    '["self-hosted","isolated-canary"]' '["self-hosted","untrusted-canary"]' \
    'ubuntu-24.04' \
    "$privileged_workflow — external privileged caller retains hosted portability"
done

dispatch_workflow="$workflows/ai-review-merge.yml"
grep -qF 'VERJSON_RUNNER_ISOLATED || vars.VERJSON_RUNNER_DEFAULT' "$dispatch_workflow" \
  && pass "dispatch-merge prefers isolated then default" \
  || fail "dispatch-merge lost isolated/default preference"
assert_route "$dispatch_workflow" dispatch-merge Verjson/.github '' false \
  '["self-hosted","isolated-canary"]' '["self-hosted","untrusted-canary"]' \
  '["self-hosted","isolated-canary"]' \
  "dispatch-merge — Verjson cannot reach hosted"
assert_route "$dispatch_workflow" dispatch-merge Acme/widgets '' true '' '' \
  'ubuntu-24.04' "dispatch-merge — external callers retain hosted portability"

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

  # Both live variables temporarily select general, but each visibility class
  # must consult its own variable so #204 can harden public work with one flip.
  assert_route "$wf" "$job" Verjson/verjson-authn '' true \
    '["self-hosted","private-canary"]' '["self-hosted","public-canary"]' \
    '["self-hosted","private-canary"]' "$name — private Verjson repo uses VERJSON_RUNNER_DEFAULT"

  assert_route "$wf" "$job" Verjson/.github '' false \
    '["self-hosted","private-canary"]' '["self-hosted","public-canary"]' \
    '["self-hosted","public-canary"]' "$name — public Verjson repo uses VERJSON_RUNNER_UNTRUSTED"

  assert_route "$wf" "$job" Verjson/verjson-authn '' '' \
    '["self-hosted","private-canary"]' '["self-hosted","public-canary"]' \
    '["self-hosted","public-canary"]' "$name — unresolved visibility fails safe to VERJSON_RUNNER_UNTRUSTED"

  # Tier 2 — the published package stays usable outside the org.
  assert_route "$wf" "$job" Acme/widgets '' true '' '' \
    'ubuntu-24.04' "$name — caller outside Verjson stays portable on hosted"

  assert_route "$wf" "$job" Verjson/verjson-authn '' true '' '' \
    "$GENERAL" "$name — missing variables fall back to the compatible general lane"

  assert_route "$wf" "$job" Verjson/.github '' false '["self-hosted","default-only"]' '' \
    '["self-hosted","default-only"]' "$name — untrusted falls back to default during migration"

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

# --------------------------------------------------------------------------
# Exhaustive, not enumerated. Every check above names specific (file, job)
# pairs, so a NEW job added to any of these files escapes all of them. Review
# demonstrated that: appending a job with an INVERTED policy — public repos to
# the persistent pool — left the suite fully green. That is the exact invariant
# ADR 0033 is built on, so the sweep has to bind every `runs-on:` line that
# exists, not a list someone has to remember to update.
#
# Prefixes legitimately differ, but every routed job must expose both lane
# variables and preserve the compatible general fallback.
# --------------------------------------------------------------------------
policy_files="node-ci.yml node-release.yml notify-umbrella.yml helm-ci.yml ui-ci.yml pulumi-ci.yml actionlint.yml"
deviant=""
job_count=0
for name in $policy_files; do
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    job_count=$((job_count + 1))
    value="${line#*runs-on:}"
    value="${value# }"
    if ! grep -qF 'VERJSON_RUNNER_DEFAULT' <<<"$value" \
        || ! grep -qF 'VERJSON_RUNNER_UNTRUSTED' <<<"$value" \
        || ! grep -qF '["self-hosted","general"]' <<<"$value"; then
      deviant="$deviant$name: $line"$'\n'
    fi
  done <<EOF
$(grep -nE "^    runs-on:" "$workflows/$name")
EOF
done

[ "$job_count" -ge 10 ] \
  && pass "sweep covered $job_count routed jobs across the reusable workflows" \
  || fail "sweep found only $job_count routed jobs — extraction is broken"

[ -z "$deviant" ] \
  && pass "every routed job exposes default/untrusted variables with a compatible fallback" \
  || fail "job(s) deviate from the routing policy:"$'\n'"$deviant"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
