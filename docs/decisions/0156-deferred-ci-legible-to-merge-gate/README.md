# 0156 — Make Renovate-deferred CI legible to the pre-merge assertion

- **Date:** 2026-09-01
- **Status:** Accepted
- **Issue:** [#1219](https://github.com/Verjson/.github/issues/1219)

## Context

`node-ci.yml`'s `build-test` job always reports (`if: always()`) so that a
`renovate/stability-days`-held PR does not leave the required `ci /
build-test` context permanently unsatisfied (#191). When the eligibility gate
defers the run, every execution step is skipped and only a `Report deferred
CI` notice step runs — but the job's own `conclusion` still reports
`success`.

`Verjson/verjson-graphql-conventions#66` showed the resulting hazard: a
Renovate lock-file bump with a real, locally-reproducible test failure
(Vite 7→8 stopped transforming decorators) carried a fully green
`statusCheckRollup`, because the deferred `build-test` run was indistinguishable
from a real pass at the only place that matters — the merge gate. The
documented pre-merge assertion,

```bash
gh pr view N --json statusCheckRollup --jq \
  '[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")'
```

returns `true` for a head CI never exercised. Under autonomous delivery, an
`--admin` merge on that verdict lands unexercised code.

The issue proposed three options and stated a preference for combining two of
them:

1. Report the deferral as `neutral`, not `success` — cheap, but the assertion
   above already accepts `NEUTRAL`, so alone it does not close the gap.
2. Annotate the check with a distinguishing output/annotation title so a gate
   can identify it with one extra projection.
3. Extend the pre-merge assertion itself to reject a `build-test` whose steps
   were entirely skipped, by projecting the check run's annotations or step
   conclusions.

## Decision

Adopt **2 plus 3**, matching the issue author's stated preference: keep the
required context satisfied so a held Renovate PR never wedges, but make the
deferral legible to whatever decides to merge.

1. **Annotate the deferral.** `node-ci.yml`'s `Report deferred CI` step emits
   `::notice title=CI deferred::...` instead of a bare, untitled `::notice`.
   GitHub Actions attaches workflow-command annotations to the job's check
   run, so the title is queryable via the standard Checks API annotations
   endpoint (`repos/<repo>/check-runs/<id>/annotations`) — the same technique
   this org's CI-triage rules already use for reading failure annotations.
2. **Strengthen the assertion.** Publish a canonical script,
   `scripts/assert-no-deferred-checks.sh <owner/repo> <pr-number>`, in this
   repository. It performs the existing `statusCheckRollup` conclusion check
   and then additionally fetches each completed check run's annotations for
   the PR head and fails closed if any annotation title matches
   `CI deferred` (overridable via `DEFERRED_CHECK_ANNOTATION_PATTERN` for a
   future distinct deferral reason). A `true` printed to stdout is the only
   passing signal, mirroring the original one-liner's contract so operators
   and agents can drop it in directly.

### Scope boundary

The *procedural* instruction to use this assertion before an `--admin` merge
lives in `verjson-agents/rules/workflow.md`, a different repository. Per this
org's "stay in your own checkout" rule, this ADR and its implementation do not
edit that file. Adopting `scripts/assert-no-deferred-checks.sh` as the
canonical replacement for the bare `statusCheckRollup` one-liner in that
external prose is reported to the repository's owner as a follow-up, not
performed here.

This repository's own `ai-privileged-merge.yml` `REQUIRED_CHECK_POLICY`
mechanism is out of scope for this decision: it already independently proves
each required check is backed by a completed, successful, trusted-workflow
run at the exact head (workflow identity, blob pin, check-suite membership),
which is a stronger and differently-shaped guarantee than the annotation
projection this ADR adds for the general `statusCheckRollup` case. Extending
it to also reject a deferred `build-test` is a candidate future enhancement,
not required to close #1219.

## Consequences

- A Renovate PR held on `renovate/stability-days` continues to satisfy the
  required `ci / build-test` context (no re-litigating #191), but its
  deferral is now visible to one extra, cheap projection instead of only to a
  human reading the job's step list.
- Operators and agents adopting `scripts/assert-no-deferred-checks.sh` in
  place of the bare rollup one-liner get fail-closed protection against
  merging a head CI never exercised. Anyone who keeps using the older
  one-liner directly is not protected — this ADR does not retract the
  hazard for that path, only publishes and documents its fix.
- Adds one extra Checks API round trip per completed check run when
  evaluating mergeability; negligible next to the trusted-workflow validation
  `ai-privileged-merge.yml` already performs per required check.
- If a future deferral reason needs a different marker, the pattern can be
  supplied via `DEFERRED_CHECK_ANNOTATION_PATTERN` without a script change.
