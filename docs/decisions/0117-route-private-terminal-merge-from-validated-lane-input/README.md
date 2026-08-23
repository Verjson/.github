# 0117 — Route private terminal merge from the validated lane input

- **Date:** 2026-08-23
- **Issue:** [Verjson/.github#676](https://github.com/Verjson/.github/issues/676)
- **Extends:** [ADR 0089](../0089-caller-supplied-privileged-routing/README.md)

## Context

The reusable terminal-promotion workflow carries the organization-wide merge
credential and is the most sensitive runner-placement boundary in the organization.
ADR 0089 established a caller-supplied `privileged_lane` seam and constrained the
private-Verjson value to the exact JSON selector `["self-hosted","general"]`. The
canonical generated caller supplies `vars.VERJSON_LANE_PRIVILEGED`. ADR 0089 originally
put its exact-match check in the first step of the terminal job. That was sufficient
while placement ignored the input, but it is not pre-scheduling validation: GitHub
selects a runner and makes job secrets available before the first step executes.

The private-Verjson branch of the same job's `runs-on` expression nevertheless still
uses a hardcoded copy of `["self-hosted","general"]`. That copy is byte-equivalent to
the only currently admitted input, but it bypasses the routing seam: a future reviewed
allowlist change would not move the terminal job, even though every generated caller
would supply the new lane. Validation and placement would then disagree.

Runner placement is evaluated by GitHub before any job step executes. The input is
caller-controlled routing data, and repository-level variables can shadow the
organization variable, so consuming it increases the importance of the existing exact
allowlist. It must not become a general-purpose label override, must not be derived from
a runner-produced job output, and must not affect the fixed public-Verjson or external
organization routes.

## Decision

The private-Verjson tail of `privileged_merge.runs-on` reads
`fromJSON(inputs.privileged_lane)` instead of duplicating the currently admitted literal.
No other term or precedence in the expression changes:

- external organizations retain their optional `runner_labels` override and hosted
  default;
- the two explicitly admitted public Verjson repositories retain fixed
  `ubuntu-24.04` placement;
- only admitted private Verjson identities reach the input-backed tail;
- the separate invalid-route job continues to fail closed for unknown or visibility-
  drifted Verjson identities; and
- no `needs.*.outputs`, repository variable, or runner-produced value participates in
  placement inside the reusable workflow.

Before that job becomes eligible, a credentialless `validate_privileged_lane` job runs
only for admitted private Verjson identities on the fixed current lane. The terminal job
has an explicit `needs` edge to it. More importantly, the terminal job's GitHub-evaluated
`if` independently exact-matches `inputs.privileged_lane` to
`["self-hosted","general"]` and requires the admission result before the input-backed
`runs-on` is usable. The fixed-lane job supplies a clear failure diagnostic; its
runner-reported success is not by itself authority to select arbitrary labels.

Public Verjson and external callers are allowed through the `always()`-guarded condition
without requiring the private admission job, preserving their existing hosted and
`runner_labels` routes. Changing the admitted selector remains a separate sensitive
change requiring synchronized review of the control-plane comparison, admission check,
runner policy, and organization capacity. This ADR does not authorize changing the live
variable.

Behavioral contract tests compare the old literal expression with the input-backed
expression for every existing caller shape: public Verjson callers with no lane input,
private Verjson generated callers supplying today's literal, external hosted callers
with no lane input, and external self-hosted callers supplying `runner_labels`. Each
must resolve to byte-identical runner data.

## Security analysis

The principal bypass attempt is a private repository shadowing
`VERJSON_LANE_PRIVILEGED` with attacker-selected labels. An in-job step cannot stop that
value from selecting a runner or receiving the job secret, so moving only the old ADR
0089 step would be unsafe. The terminal job's own `if` exact-match is evaluated by
GitHub before scheduling: a missing, malformed, hosted, widened, or attacker-selected
value makes the secret-bearing job ineligible. The credentialless diagnostic job stays
on the fixed admitted lane and receives no merge secret.

A compromised admission runner can report a successful step, but that success cannot
weaken the independent exact comparison in the terminal job. Conversely, an exact input
can select only the already admitted general lane. This deliberately duplicates the
current allowlist at the scheduling boundary; eliminating all copies is less important
than preventing secret delivery to an unadmitted runner.

The other material bypass is substituting runner-produced output. The expression
continues to forbid `needs.*.outputs` and resolver jobs, preserving GitHub control-plane
evaluation of caller input. Public Verjson identities cannot fall through to the input;
external callers cannot use `privileged_lane`; and unknown Verjson identities cannot
silently skip both jobs successfully.

## Alternatives rejected

**Keep the literal until the eventual hosted cutover.** This preserves today's
placement but leaves the declared routing seam ineffective and makes a future variable
change silently incomplete.

**Read `vars.VERJSON_LANE_PRIVILEGED` directly in the reusable workflow.** Rejected
because repository variables can shadow organization variables and it would bypass the
canonical caller contract without improving trust.

**Trust a preceding job's output or conclusion as the only validator.** Rejected because
a compromised runner could forge it. The admission job is diagnostic and ordered before
terminal execution, while the terminal job independently enforces the exact value in a
GitHub control-plane expression. It is conditional on private Verjson callers, so it
does not impose hosted or Verjson-fleet capacity on external consumers.

**Remove validation because `runs-on` now reads the input.** Rejected: placement and
authorization occur at different boundaries. Input-backed routing makes the exact
allowlist more important, not less.

## Consequences and rollback

Today's effective placement is unchanged for every existing caller. The reusable
workflow now follows the already-distributed `privileged_lane` seam, so a future
approved selector change can update validation and capacity policy without another
hidden literal in this job.

Rollback restores the literal private tail and removes the private admission dependency.
It is safe only while
the admitted input remains byte-identical to `["self-hosted","general"]`; otherwise
rollback would recreate validation/placement divergence. No organization variable,
credential, App identity, ruleset, or runner registration changes as part of this
decision.
