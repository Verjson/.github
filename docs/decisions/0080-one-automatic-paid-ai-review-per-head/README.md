# 0080 — Allow one automatic paid AI review per head

- **Date:** 2026-08-08
- **Issue:** [Verjson/.github#637](https://github.com/Verjson/.github/issues/637)
- **Supersedes:** ADR 0002 and ADR 0015 automatic in-run escalation decisions
- **Category:** AI merge gate / cost authorization (sensitive-class)

## Context

The gate could invoke Claude three times in one run: a selected first pass and
two $1 escalation passes whenever earlier output was absent or semantically
invalid. A small diff with denied tool calls exhausted every pass without a
verdict. The gate failed closed, but had already paid for three attempts and
misdescribed tool-boundary non-progress as an oversized diff.

Native auto-merge now owns the wait for ordinary CI, and exact-head App receipts
deduplicate automatic authorization. Neither mechanism requires multiple model
attempts. Paying again after an inconclusive review is a separate cost decision
that belongs to a maintainer.

## Decision

An eligible head receives at most one automatic paid model invocation. Its
selected classifier budget ($0.15, $0.50, $0.60, or $0.90) is therefore the
maximum automatic spend for that head.

Budget exhaustion, turn exhaustion, an SDK terminal result, semantically invalid
structured output, or no usable verdict fails closed. The gate labels and
comments with the observed cause. Permission denials are reported as tool-boundary
non-progress rather than evidence that the diff is oversized.

A later paid attempt requires the existing explicit maintainer `re-review`
label. The workflow consumes that label. Ordinary CI changes, duplicate events,
and an unchanged-head re-fire cannot create an automatic second paid pass.
Exact-head receipt and dedicated-App authorization semantics are unchanged.

## Consequences

- Automatic spend is bounded by the selected first-pass budget, never an
  escalation ladder.
- Transient structured-output failures can require maintainer intervention, in
  exchange for preventing silent repeat spend.
- Fail-closed merge safety is preserved; unusable output never authorizes merge.
- ADRs 0002 and 0015 remain historical records of the retired escalation design.

## Verification

`scripts/ci-gate/ai-review-retry.test.sh` mutation-tests the single-action and
selected-budget invariant. `scripts/ci-gate/budget-exceeded.test.sh` executes
budget, turn, terminal, missing-telemetry, and permission-denial outcomes.
