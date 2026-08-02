---
date: 2026-08-02
issue: 276
title: The merge gate derives its own job names at runtime instead of waiting on itself
---

A reusable `workflow_call` publishes the callee's checks as `<caller job> /
<callee job>`, so a consumer installing the gate with `uses:
Verjson/.github/.github/workflows/ai-review-merge.yml` — a shape ADR 0039
supports — saw the gate's own jobs as `ci / preflight`, `ci / gate`,
`ci / dispatch-merge`. Both CI snapshots (`ci_wait` and the authoritative merge
recheck) filtered required checks by exact equality against a static list of
*bare* names, so the gate enumerated its own jobs as required checks and waited
for itself until the poll window expired, reporting `trusted gate/checks did not
become green` — an error pointing nowhere near the cause.

Both snapshots now derive this run's job names from
`repos/<repo>/actions/runs/<run id>/jobs`, which reports them exactly as GitHub
published them, prefixed or not, for whichever installation shape is in use. The
exclusion set is the **union** of the derived names, the existing static list and
the trusted-continuation literal: jobs are created as they start, so a run cannot
enumerate its own not-yet-created `dispatch-merge`/`ai-merge` jobs, and the
static list stays as the floor. An unreadable or unparseable jobs API falls back
to that floor and warns; it never widens the exclusion set.

Name normalization (stripping everything before `/`) was deliberately rejected:
it keys on the callee segment, so an unrelated consumer check such as
`security / review` or `release / gate` would silently drop out of the required
set — a fail-open in someone else's repository.

`scripts/ci-gate/self-job-exclusion.test.sh` pins both properties against the
shipped workflow body, covering the prefixed and un-prefixed shapes, foreign
checks that must stay required, the static floor, a null job name, and an
unreadable jobs API. Refs ADR 0036, ADR 0039.

The ADR 0042 fragment carried `issue: 276` while ADR 0042 itself records its
issue as `verjson-cloud-storage#28` and lists #276 as *deferred* work. That
identity is not expressible as a plain issue number, so the fragment was given
the issue-less UTC identity the contract reserves for exactly that case,
releasing #276 to the change that closes it. Its text is unchanged.

An adversarial review of the first draft found that run provenance alone is too
wide. In the `workflow_call` shape the gate's jobs belong to the caller's run, so
`runs/<id>/jobs` also returns the consumer's own jobs — confirmed against
`Verjson/verjson-cloud-storage` run 30601253117, which returns exactly
`ci / eligibility` and `ci / build-test`. Subtracting those dropped the
consumer's real CI from the required set and merged on red, which is strictly
worse than the deadlock being fixed. The exclusion is now the intersection of run
provenance and the gate's own job vocabulary, and the suite carries red-sibling
and pending-sibling regressions that reproduce the merge before the fix.
