# 0057 — `runner_labels` is optional again, so generated callers route by lane

- **Date:** 2026-08-05
- **Issue:** [Verjson/.github#405](https://github.com/Verjson/.github/issues/405)
- **Category:** CI routing / cross-org distribution (sensitive class — it moves
  the runner selection for a job that holds `ORG_ADMIN_TOKEN` from a per-repository
  file to an organization variable)
- **Status:** Accepted
- **Supersedes:** the `runner_labels` item of ADR 0022's 2026-07-23 amendment, and
  the same requirement as restated in ADR 0042. Narrows the exclusion paragraph in
  ADR 0053.

## Context

ADR 0022 (2026-07-23) made `runner_labels` **required** on `workflow_call`, and
ADR 0042 carried the same requirement to `ai-privileged-merge.yml`. The reason was
concrete: a caller that omitted the input fell through the `runs-on` fallback to
`self-hosted,gate`, a pool no consumer org has a runner for, so the job **queued
forever with no error**. An in-job fast-fail cannot catch that — the job never
gets a runner to run a step — so failing the call outright was the only fast
signal available.

That premise expired. Since ADR 0040/0041 (#401) every `runs-on` in this
repository ends at `vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]'`. An
organization with no lane variables now lands on a hosted runner that exists, so
the queue-forever failure the requirement prevented can no longer occur — while
the requirement's own cost had become the live defect:

- Requiring the input forced every caller to spell out a **fleet label**, and
  `scripts/gen-privileged-merge-caller.sh` supplied a Verjson one,
  `["self-hosted","general"]`, into every generated consumer.
  `Verjson/verjson-identity-lifecycle` carries that literal today.
- That is precisely the coupling ADR 0041 removes: a relabel becomes a pull
  request in ~90 consumer repositories instead of an organization-variable flip.
  #401 cleared every `runs-on:` in this repository; the generator was the last
  producer of fleet labels the organization owns.
- `actionlint` cannot see this class. Its undeclared-label check inspects
  `runs-on` **arrays**; a label inside a string input is invisible to it, so the
  detection #403 added would have stayed silent indefinitely.

## Decision

1. `runner_labels` becomes `required: false` on both reusable merge workflows.
   The input is **kept**, not deleted: a self-hosted consumer outside Verjson has
   no lane variables to fall through to and is the one caller that still needs to
   name its own fleet.
2. `scripts/gen-privileged-merge-caller.sh` takes the labels as an optional
   argument and emits `with.runner_labels` only when asked, so a generated caller
   is lane-routed by default.
3. The `runs-on` precedence is unchanged on the two jobs that read the input:
   `preflight` and `gate` (`ai-review-merge.yml:178`, `:535`) still let
   `inputs.runner_labels` win, as does `privileged_merge`
   (`ai-privileged-merge.yml:82`). **`dispatch-merge` never read it**
   (`ai-review-merge.yml:1819`), so a self-hosted-only caller outside Verjson gets
   `preflight` and `gate` on its own fleet and `dispatch-merge` on `ubuntu-24.04`.
   That gap predates this decision and is tracked in
   [#411](https://github.com/Verjson/.github/issues/411) rather than changed here.
4. `require_secrets` (the other half of ADR 0022's 2026-07-23 amendment) is
   untouched.

## Consequences

### Security — an organization variable now places a job that holds `ORG_ADMIN_TOKEN`

This is the reason the decision is in the sensitive class and needs to be read
before it is relied on.

`privileged_merge` carries `GH_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}`
(`ai-privileged-merge.yml:91`). While the generator baked `runner_labels` into
every caller, changing where that job runs meant editing a file in the consumer
repository — a pull request, reviewed under that repository's rules. With the
input omitted, the selector resolves through
`vars.VERJSON_LANE_PRIVILEGED || vars.VERJSON_LANE_FALLBACK`. **Anyone who can
write those organization variables can retarget the merge-authority job onto a
runner they control, with no pull request in any consumer repository.** A
self-hosted runner sees the job's environment, so that is a path to
`ORG_ADMIN_TOKEN`.

What bounds it, stated as bounds rather than as reassurance:

- The population is organization owners / admins with variable-write access —
  the same population that writes organization **secrets**, and therefore one
  that can already reach `ORG_ADMIN_TOKEN` directly. The escalation is *within*
  what an organization-variable writer already controls, not beyond it.
- `VERJSON_LANE_PRIVILEGED` is an organization variable at `visibility: all`, so
  every repository in the organization can read it; that visibility is a known
  defect, tracked with the secrets scoping in
  [#265](https://github.com/Verjson/.github/issues/265). Read access is not write
  access, but it does mean the target lane is not confidential.
- `dispatch-merge` in `ai-review-merge.yml` has been placed this same way since
  ADR 0053, so the *mechanism* is not new here. What is new is the privilege
  reachable through it: `dispatch-merge` holds only `contents: read` and
  `actions: write`, while `privileged_merge` holds the administrative token.
- Runner admission (ADR 0033/0054) still governs which repositories a pool
  accepts, so the variable selects among admitted lanes rather than among
  arbitrary machines.

Accepted on that basis: the control moves from per-repository review to
organization-variable write, which is a strictly smaller and already
token-privileged population, and the alternative — 90 repositories pinned to a
literal fleet label — is a live availability defect with no detector.

### Consumers

Existing generated callers keep working: they pass a still-accepted input. They
stay label-pinned until regenerated by the #365 sweep, which must therefore land
after this. ADR 0053's exclusion of `ai-privileged-merge.yml` from the overflow
lane holds for exactly that set of un-regenerated callers.

## Pinned by

- `scripts/ci-gate/reusable-workflow.test.sh` — `required: false`, with this
  rationale.
- `scripts/ci-gate/privileged-merge-caller-contract.test.sh` — a generated caller
  contains no `self-hosted` literal and no `runner_labels` entry, while an
  explicit fleet is still forwarded.
- `scripts/ci-gate/runner-routing-policy.test.sh` — evaluates the real `runs-on`
  expressions for both polarities: omitted → the lane chain, supplied → the
  caller's labels; and for the omitted case with `VERJSON_RUNNER_OVERFLOW` both
  unset and set, because the organization sets it in production and it precedes
  the lane variables in `ai-review-merge.yml`'s chains.
