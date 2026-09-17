# 0188 — Contract audits assert fields, and a growing vendor schema is not drift

- **Date:** 2026-09-17
- **Status:** Accepted
- **Related:** [ADR 0091](../0091-ruleset-requires-authorization-arm/README.md), [ADR 0094](../0094-arm-required-by-its-own-property-scoped-ruleset/README.md), [ADR 0186](../0186-required-checks-bind-through-repository-properties/README.md)
- **Issues:** [Verjson/.github#1404](https://github.com/Verjson/.github/issues/1404), [Verjson/.github#1401](https://github.com/Verjson/.github/issues/1401)

## Context

`scripts/ai-review-required-workflow-audit.py` compared the live organization
ruleset `18098028` against frozen `preimage`/`postimage` objects and required an
exact whole-object match. On 2026-09-17 it exited 1 at that first precondition
and reached none of its later checks:

```
ERROR: authorization-arm-rollout-not-ready: main-protection differs from both full reviewed preimage and postimage
```

Live differed in two unrelated ways, and conflating them is the defect:

1. **Two bypass grants nobody wrote down.** `release-authorization` (`4583107`)
   and `merge-authorization` (`4693283`) hold `always` bypass on
   `main-protection`, on `ai-authorization-arm-required`, and on both
   `core-checks-*` rulesets. The merge App squash-merges on green CI and cannot
   do so without bypassing branch protection, so the grants are coherent — they
   were simply never recorded.
2. **GitHub extended its own schema.** Live `pull_request` parameters carry
   `require_extra_approval_for_unattributed_changes`, which no frozen image can
   contain. The live arm ruleset likewise carries a resolved `sha` on its
   selected workflow, and live required status checks carry `integration_id`.

The audit was also invoked nowhere. `git grep` found it only in ADRs and its own
unit test, so the exit-1 above was invisible for as long as it persisted — while
it was the only control that could have caught the fleet gap in #1401.

## Decision

**An image comparison asserts the fields the contract pins and tolerates keys the
API adds; it never tolerates an unexpected value.**

- A key present in the reviewed image must exist in the live object and carry
  exactly that value, with `true` distinct from `1`.
- A key present only in the live object is ignored.
- Lists are matched position-wise and a differing length is drift, so an added
  bypass actor or required status check is still reported.
- A drift report names the nearest reviewed image and the disagreeing fields.

Exact equality is retained where both sides are ours: the contract's internal
derivations (postimage equals preimage minus the workflows rule, rollback equals
preimage) stay whole-object comparisons, because nothing external can grow them.

**Unrecorded live state is written into the contract only as a reviewed
decision, never adopted.** The two bypass grants and the `changelog-contract`
required context ADR 0186 already decided are now recorded, each with its
rationale. `ai-review-authorization` (`4528902`) is deliberately granted no
bypass anywhere: review stays non-privileged, and an audit that re-froze live
state could never have said so.

**The audit runs on a schedule.** It shares the daily
`org-ruleset-conformance` schedule in its own job, so its exit status is
attributable and cannot mask the release-authorization result. It reports; no
pull request gates on it.

## Alternatives rejected

- **Re-freezing live state.** It would have turned green immediately and turned
  the audit into a recorder of whatever happened, including any grant an
  attacker or an accident had just made.
- **Comparing a hand-listed subset of fields.** It answers the vendor-growth
  problem and silently drops any field nobody remembered to list. Asserting the
  reviewed image and ignoring only *additions* keeps the contract as the single
  statement of what is pinned.
- **Ignoring unknown keys everywhere, including list members.** That would have
  hidden the very bypass grants this decision records.
- **Waiting for the audit to pass before scheduling it.** It fails today for a
  real reason (below). A control introduced only once green is a control that
  was never needed.

## Consequences

- The audit now reaches its fleet-coverage check and reports:
  `armed default branches without canonical deterministic required CI:
  missing=1 sample=['Verjson/verjson-agents']`. That repository carries
  `verjson-core-checks=enforced` with `verjson-stack=none`, so nothing
  deterministic sits behind its arm. This is #1401's condition, now visible, and
  it is resolved there rather than here.
- The scheduled job will therefore be red until that enrollment is resolved. A
  red report from a control that gates nothing is the intended behavior; it is
  not a merge blocker.
- Live required checks bind to `integration_id: 15368` and the reviewed images do
  not pin it. That app binding is #1381's subject and is deliberately untouched
  here; this comparison neither asserts nor weakens it.
- Adopter conformance — caller presence, the `ai-review-app` environment, its
  branch policy — remains outside the audit. It is #1401's follow-up, and it was
  blocked behind this decision because it would have sat after an unreachable
  precondition.
