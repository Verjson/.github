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
# The premise above is FALSE as stated and is corrected by ADR 0047/0048:
# hosted minutes are free for PUBLIC repositories (billing measured 2026-08-01);
# private ones are capped by a spending limit, which is a budget knob rather than
# an impossibility. The invariant that still holds is narrower — a Verjson job
# must not land on hosted *by accident*. Deliberate, reviewed routes are allowed.
#
# Sanctioned exceptions:
#  * actionlint's `github-hosted-runner` input (ADR 0026) — explicit per-caller
#    opt-in, never a default a Verjson caller falls into.
#  * `VERJSON_RUNNER_FASTLANE` (ADR 0047/0048) — the fast lane. Selected by an
#    org variable, so it is repointable at self-hosted capacity without editing
#    a workflow, and it always carries a fallback.
#  * `fleet-watchdog.yml` — polices the self-hosted fleet, so gating it on that
#    fleet would leave it queued behind the jam it exists to clear. It runs only
#    in this repository, which is public, so its minutes are free.
unsafe_portable="$(
  grep -HnE "^    runs-on:.*ubuntu-(24\\.04|latest)" "$workflows"/*.yml \
    | grep -v "github.repository_owner != 'Verjson' && 'ubuntu-24.04'" \
    | grep -v "github.repository_owner == 'Verjson'.*|| 'ubuntu-24.04'" \
    | grep -v "inputs.github-hosted-runner" \
    | grep -v "vars.VERJSON_RUNNER_FASTLANE" \
    || true
)"

# The fast lane must keep a fallback: a bare `fromJSON(vars.X)` with no `||`
# breaks every consumer the moment the variable is unset.
fastlane_no_fallback="$(
  grep -HnE "^    runs-on:.*VERJSON_RUNNER_FASTLANE" "$workflows"/*.yml \
    | grep -v "VERJSON_RUNNER_FASTLANE ||" || true
)"
[ -z "$fastlane_no_fallback" ] \
  && pass "every fast-lane selector keeps a fallback for an unset variable" \
  || fail "fast-lane selector without a fallback: $fastlane_no_fallback"
[ -z "$unsafe_portable" ] \
  && pass "hosted fallbacks are reachable only by callers outside Verjson" \
  || fail "hosted fallback reachable by a Verjson caller: $unsafe_portable"

grep -qF "github.repository_owner != 'Verjson'" "$workflows/actionlint.yml" \
  && grep -qF '["self-hosted","general"]' "$workflows/actionlint.yml" \
  && pass "actionlint preserves its bounded external hosted compatibility path" \
  || fail "actionlint runner contract drifted"

# ADR 0047 moves this suite off the shared pool. The contract is that it routes
# through a VARIABLE with a fallback chain, never a hardcoded label: the lane has
# to be repointable at a self-hosted pool from org settings alone, and an unset
# variable must degrade to the ADR 0034 general pool rather than to nothing.
grep -qF 'vars.VERJSON_RUNNER_FASTLANE || vars.VERJSON_RUNNER_DEFAULT' "$workflows/actions-ci.yml" \
  && grep -qF "'[\"self-hosted\",\"general\"]'" "$workflows/actions-ci.yml" \
  && ! grep -qF 'runs-on: [self-hosted, general]' "$workflows/actions-ci.yml" \
  && pass "repository shell validation routes through the fast-lane variable with a general fallback" \
  || fail "actions-ci fast-lane routing drifted (ADR 0047)"

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
const [, , raw, repository, runnerInput, priv, varDefault, varUntrusted, varFastlane] = process.argv;
// `inputs.github-hosted-runner` is a legal Actions reference and an illegal JS
// one — bare, it parses as `inputs.github - hosted - runner`. Rewriting it to a
// bracket access is what lets actionlint.yml be EVALUATED here rather than only
// grepped, which is how its visibility polarity went untested until ADR 0050.
const body = raw.trim().replace(/^\$\{\{/, '').replace(/\}\}$/, '')
  .replace(/inputs\.github-hosted-runner/g, "inputs['github-hosted-runner']");
const github = {
  repository,
  repository_owner: repository.split('/')[0],
  event: {
    repository: {
      private: priv === '' ? 0 : priv === 'true',
      // A STRING, and the reason ADR 0050 routes on it. `private` is a boolean
      // that Actions coerces to 0 when the payload omits it, so `private ==
      // false` is TRUE for an unreadable repository as well as a public one —
      // a fail-OPEN that would spend hosted minutes on a repo it could not
      // read. `visibility` is '' in that case, and '' == 'public' is false.
      visibility: priv === '' ? '' : priv === 'true' ? 'private' : 'public',
    },
  },
};
// Modelled as false throughout: it is the per-caller opt-in of ADR 0026, so
// every case here is the default one where a Verjson caller has NOT opted in.
const inputs = { runner: runnerInput, 'github-hosted-runner': false };
// preflight resolves the TARGET repository's visibility and publishes it as a
// STRING ('true' | 'false' | '' when unreadable). gate and dispatch-merge route
// on that rather than on `github.event.repository`, because on the dispatch path
// the event repository is the dispatcher, not the target.
const needs = { preflight: { outputs: { target_private: priv } } };
// An unset Actions variable is the empty string, not undefined.
const vars = {
  VERJSON_RUNNER_DEFAULT: varDefault,
  VERJSON_RUNNER_UNTRUSTED: varUntrusted,
  // Privileged routing prefers an isolated lane and then the default lane.
  // Existing evaluator call sites provide one private-lane fixture, so use it
  // for both names; structural assertions below pin the preference order.
  VERJSON_RUNNER_ISOLATED: varDefault,
  VERJSON_RUNNER_FASTLANE: varFastlane,
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
  Object.assign(Object.create(null), { github, inputs, needs, vars, fromJSON, contains }),
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

# assert_route <workflow> <job> <repo> <runner-input> <private> <var-default> <var-untrusted> <expected> <label> [var-fastlane]
assert_route() {
  local workflow="$1" job="$2" repository="$3" runner_input="$4" priv="$5"
  local var_default="$6" var_untrusted="$7" expected="$8" label="$9"
  local var_fastlane="${10-}"
  local expression resolved
  expression="$(extract_runs_on "$workflow" "$job")"
  if [ -z "$expression" ]; then
    fail "could not extract runs-on for job '$job' from $(basename "$workflow")"
    return
  fi
  resolved="$(node "$evaluator" "$expression" "$repository" "$runner_input" \
    "$priv" "$var_default" "$var_untrusted" "$var_fastlane" 2>&1)" || {
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
# ADR 0048 replaces ADR 0033's "Verjson never reaches hosted" invariant with a
# visibility split: a PUBLIC target is deliberately routed to elastic hosted
# capacity (free for public repos, and the fixed self-hosted pool is what made
# the 2026-08-03 deadlock possible). Private and UNRESOLVED must still not be —
# unresolved especially, so visibility that fails to read never spends money.
assert_route "$dispatch_workflow" dispatch-merge Verjson/.github '' false \
  '["self-hosted","isolated-canary"]' '["self-hosted","untrusted-canary"]' \
  '["fastlane-canary"]' \
  "dispatch-merge — a public Verjson target takes the fast lane" \
  '["fastlane-canary"]'

assert_route "$dispatch_workflow" dispatch-merge Verjson/.github '' true \
  '["self-hosted","isolated-canary"]' '["self-hosted","untrusted-canary"]' \
  '["self-hosted","isolated-canary"]' \
  "dispatch-merge — a private Verjson target stays self-hosted" \
  '["fastlane-canary"]'

assert_route "$dispatch_workflow" dispatch-merge Verjson/.github '' '' \
  '["self-hosted","isolated-canary"]' '["self-hosted","untrusted-canary"]' \
  '["self-hosted","isolated-canary"]' \
  "dispatch-merge — unresolved visibility never spends hosted minutes" \
  '["fastlane-canary"]'
assert_route "$dispatch_workflow" dispatch-merge Acme/widgets '' true '' '' \
  'ubuntu-24.04' "dispatch-merge — external callers retain hosted portability"

# ADR 0050. actionlint is a short, secretless CPU job, so on a PUBLIC target it
# takes the fast lane instead of contending for the fixed self-hosted pool with
# the merge-gate poll loops it can starve. Four polarities, because every
# interesting failure here is in a fallback rather than the happy path.
assert_route "$workflows/actionlint.yml" actionlint Verjson/.github '' false \
  '["self-hosted","d"]' '["self-hosted","u"]' '["ubuntu-24.04"]' \
  "actionlint — a public Verjson repo takes the fast lane (ADR 0050)" '["ubuntu-24.04"]'

assert_route "$workflows/actionlint.yml" actionlint Verjson/verjson-authn '' true \
  '["self-hosted","d"]' '["self-hosted","u"]' '["self-hosted","d"]' \
  "actionlint — a private Verjson repo stays on VERJSON_RUNNER_DEFAULT" '["ubuntu-24.04"]'

# The load-bearing one. The test is `== false`, never `!= true`, so a visibility
# that fails to resolve falls through to self-hosted instead of silently
# spending hosted minutes on an unreadable repository (ADR 0048's polarity rule).
assert_route "$workflows/actionlint.yml" actionlint Verjson/.github '' '' \
  '["self-hosted","d"]' '["self-hosted","u"]' '["self-hosted","u"]' \
  "actionlint — unresolved visibility still fails safe to VERJSON_RUNNER_UNTRUSTED" '["ubuntu-24.04"]'

assert_route "$workflows/actionlint.yml" actionlint Verjson/.github '' false \
  '["self-hosted","d"]' '["self-hosted","u"]' '["self-hosted","u"]' \
  "actionlint — an unset fast lane degrades to VERJSON_RUNNER_UNTRUSTED" ''

# Mutation check. The obvious way to write the public branch —
# `private == false` — is FAIL-OPEN: Actions coerces a missing `private` to 0,
# and 0 == false, so an unreadable repository would reach the fast lane. That
# form passed the three positive cases above and failed only the unresolved one,
# which is exactly how it would have shipped. Pin its absence directly, so the
# regression cannot return through a rewrite that keeps the tests passing.
grep -qF "github.event.repository.visibility == 'public'" "$workflows/actionlint.yml" \
  && ! grep -qF 'github.event.repository.private == false' "$workflows/actionlint.yml" \
  && pass "actionlint routes public on the visibility STRING, not the coercible private boolean" \
  || fail "actionlint uses the fail-open 'private == false' form (ADR 0050)"

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
changelog-validate.yml validate
changelog-release.yml release
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
changelog-validate.yml validate
changelog-release.yml release
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
policy_files="node-ci.yml node-release.yml notify-umbrella.yml helm-ci.yml ui-ci.yml pulumi-ci.yml actionlint.yml changelog-validate.yml changelog-release.yml"
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

# --------------------------------------------------------------------------
# Guidance is routing too. helm-ci.yml told callers to pin their kind smoke
# tests to `[self-hosted, docker]` long after the Docker lane stopped existing;
# a caller who followed it got a job that queued forever with no check run
# (#271, #182's silent mode). Nothing caught it because the pin lived in a
# COMMENT, and every check above reads `runs-on:` lines only.
#
# So bind every self-hosted label named in a bracketed selector list — in code
# or in a comment — to the declared set in .github/actionlint.yaml. That file is
# the organization-wide actionlint policy, i.e. the list of labels a Verjson
# workflow may name at all, which makes it the right authority: a label absent
# from it is one nothing may route on, so recommending it in prose is the same
# defect as routing on it.
#
# SCOPE, stated precisely because a guard trusted past its reach is worse than
# none. This matches the bracketed forms — `["self-hosted","general"]` and
# `[self-hosted, docker]` — on a single line. It does NOT match the YAML
# block-sequence spelling, nor a bare mention like "the self-hosted docker
# lane" in prose. Those remain unguarded; widening to bare words would need a
# deny-list of retired labels rather than this allow-list shape.
#
# The surface includes `.github/actions/**` docs, not just workflows: the same
# defect shipped a second time in setup-verjson-node's README, where a consumer
# copies the usage block verbatim.
#
# Also unguarded, and known: prose ATTRIBUTIONS in actionlint.yaml's own comments
# ("gate — carried today by the gha-general-* runners"). Those name runners
# rather than labels, so no selector-shaped check can see them going stale. If
# that class recurs, it needs a live-fleet check, not a wider regex here.
# --------------------------------------------------------------------------
declared="$(sed -n '/^self-hosted-runner:/,/^[^ #]/p' "$root/.github/actionlint.yaml" \
  | sed -n 's/^    - \([A-Za-z0-9._-]*\).*/\1/p')"
[ -n "$declared" ] \
  && pass "read $(printf '%s\n' "$declared" | wc -l | tr -d ' ') declared runner label(s) from actionlint.yaml" \
  || fail "could not read declared labels from .github/actionlint.yaml — extraction is broken"

# actionlint.yml's self-test feeds actionlint a workflow pinned to this label to
# prove the central policy actually rejects an unknown one. It is a NEGATIVE
# CONTROL, so it must stay undeclared — declaring it would leave the self-test
# passing while proving nothing.
control_label="retired-runner-label"
grep -qxF "$control_label" <<<"$declared" \
  && fail "$control_label is declared in actionlint.yaml — actionlint.yml's negative control no longer proves anything" \
  || pass "the actionlint self-test's negative control label stays undeclared"

# Both halves, or this asserts something about a control that no longer exists:
# deleting the invalid-runner fixture would leave the check above green while
# nothing proves the policy rejects an unknown label at all.
grep -qF "$control_label" "$workflows/actionlint.yml" \
  && pass "actionlint.yml still exercises the undeclared-runner negative control" \
  || fail "actionlint.yml's undeclared-runner negative control is missing — nothing proves the policy rejects unknown labels"

undeclared=""
for f in "$workflows"/*.yml "$root"/.github/actions/*/README.md "$root"/.github/actions/*/action.yml; do
  [ -f "$f" ] || continue
  # The exemption is scoped to the file that owns the fixture. Repo-wide, it
  # would silently excuse a genuine `runs-on: [self-hosted, retired-runner-label]`
  # anywhere else — the exact "exemption hides a real label" hole.
  exempt="self-hosted"
  [ "$(basename "$f")" = "actionlint.yml" ] && exempt="self-hosted|$control_label"
  # `tr -d "\"'"` strips BOTH quote styles: `['self-hosted', 'general']` is legal
  # YAML, and stripping only double quotes made it fail as the bogus label
  # `'general'`. Blank lines are dropped with a second grep rather than an empty
  # ERE alternation, which is undefined in POSIX and errors outright on non-GNU
  # grep — leaving the scan silently empty and passing forever.
  mentioned="$(grep -oE '\[[^][]*self-hosted[^][]*\]' "$f" \
    | tr -d "\"'" | tr ',[]' '\n\n\n' | sed 's/^ *//; s/ *$//' \
    | grep -vxE "$exempt" | grep -v '^$' | sort -u)"
  # Quoted: an unquoted expansion word-splits a prose label containing a space.
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    grep -qxF "$label" <<<"$declared" \
      || undeclared="$undeclared$(basename "$f"): $label"$'\n'
  done <<<"$mentioned"
done

[ -z "$undeclared" ] \
  && pass "every self-hosted label in a bracketed selector — workflows and action docs — is declared" \
  || fail "workflow(s) name a runner label absent from .github/actionlint.yaml:"$'\n'"$undeclared"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
