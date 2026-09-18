# 0195 — An indeterminate authorization answer is never decodable as a permissive one

- **Date:** 2026-09-18
- **Status:** Accepted
- **Related:** [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md), [ADR 0193](../0193-every-ci-gate-script-is-a-gate-unless-declared-a-library/README.md)
- **Issues:** [#1476](https://github.com/Verjson/.github/issues/1476), [#1480](https://github.com/Verjson/.github/issues/1480)

## Context

Two defects on the AI-review authorization path were reported separately and turned out
to be the same mistake made in opposite directions: a question the gate could not answer
was encoded as an answer.

**#1476 — the merge gate's freshness step.** The behind-count came from

```
behind="$(gh api "repos/$REPO/compare/$base_ref...$head_sha" --jq '.behind_by' 2>/dev/null || echo 0)"
[[ "$behind" =~ ^[0-9]+$ ]] || behind=0
```

Two separate swallows, both landing on `0`. An outage, a rate limit, an auth blip, an
empty body and an unparseable body were all indistinguishable from the API genuinely
answering "this head is not behind its base". The gate then skipped `update-branch` and
emitted `proceed=true`, merging a review taken against a possibly stale base. The only
signal that anything had gone wrong was silence. This **fails open**, which is the
dangerous direction: ADR 0194 (in flight on #1469) states that a guard that fails open is
worse than an absent one, because an absent guard is at least visible.

**#1480 — the zero-provider recovery verifier.** One predicate over the paginated
`workflow_dispatch` run listing decided admission, and one message covered its failure:
`initial direct review dispatch is missing or not unique`. That message was emitted for
three unrelated conditions — the run not yet appearing in the listing (eventual
consistency on `GET /actions/runs`), a genuine duplicate dispatch, and a non-1
`run_attempt`. A not-yet-indexed run and a duplicated run produced byte-identical output,
so no occurrence could be triaged from its log. This **fails closed**, reddening a
required check on the privileged merge path; the harm is a wedge plus the habit it
teaches, which is to dismiss a red on the one check guarding direct review admission.

The shapes differ, but the root cause does not: in both, "we could not ask" was collapsed
into a value that reads as a legitimate answer.

## Decision

**An indeterminate result on an authorization path is represented as indeterminate, never
as a value that a downstream comparison can read as permissive.**

That is the rule adopted, and it is stated as a rule rather than as a description of the
whole fleet. It now holds for both indeterminacy paths in the freshness step — the PR
metadata read and the compare lookup. One known site does not yet comply: the Renovate
release-age lookup (#1495), which still swallows a failed request into `age_pending=0`.
It is named here so this ADR is not read as certifying it. Concretely:

1. **Only a well-formed answer counts as an answer.** The compare lookup is now
   `compare_behind()`, which returns non-zero when the request fails, returns nothing, or
   returns a body that is not a decimal integer. There is no default value; there is a
   success/failure distinction. This is positive evidence of an answer, rather than the
   absence of an error.

2. **Transience is absorbed by a bounded retry, not by a default.** Both sites retry —
   the compare lookup three times, the run listing five times with a 3-second gap. A
   single blip self-heals without any weakening of the predicate.

3. **Persistent indeterminacy holds, loudly.** After the retries, the freshness step emits
   `::error::` naming the condition and exits 1. It does not emit `proceed=true`, and it
   does not stall silently. This covers both ways the step can end up unable to answer:
   an unreadable PR metadata read (`:407-411`) and an unanswerable compare (`:507-523`).
   Neither writes `proceed=true`; both exit non-zero. The metadata read matters
   disproportionately because it runs first — while it failed open, a total outage never
   reached the compare guard at all, so that guard was unreachable on the one path it was
   written for.

4. **Retry only what is eventually consistent.** A missing run may appear later, so it is
   retried. A duplicate dispatch is *not* eventually consistent: retrying it would only
   widen the window in which a second dispatch could be accepted as the trusted one. It is
   refused on the first look. Neither the uniqueness assertion nor the `run_attempt == 1`
   assertion is relaxed — both still fail closed, they are merely now reported distinctly.

5. **Distinct conditions get distinct messages.** Absent, duplicated, wrong-run and
   retried each name themselves, so a future occurrence is triable from its log alone.

### Why "hold" and not "proceed" or "silently defer"

Three options were considered for persistent indeterminacy in the freshness step:

- **Proceed (status quo).** Rejected: it is the defect. It merges on an unverified base.
- **Defer silently** — emit `proceed=false` and exit 0. Rejected: nothing re-triggers the
  run, so the PR stalls with a green check and no stated reason. That reproduces #1480's
  undiagnosability in a new place.
- **Hold with a stated reason** — `::error::` plus exit 1. Chosen. It cannot merge on an
  unverified base, it is visible, and it is cleared by the ordinary push or re-run that
  any red check is cleared by.

### Blast radius, stated

This step runs on every PR in every repository the merge gate reaches, so the choice is
fleet-wide. During a sustained GitHub API outage the merge gate will red rather than
merge, across the fleet, until the API recovers. That holds for a `compare`-only outage
and for a correlated one that also breaks the PR metadata read: the metadata read now
holds instead of proceeding, so the correlated case reds at `:407-411` rather than
sliding past the compare guard. An earlier draft of this ADR claimed the fleet-wide red
while the metadata read still failed open, which made it true only for the narrower
`compare`-only outage; folding #1496 into this change is what made the sentence true.

That red is accepted deliberately: during such an outage the gate cannot establish the
property it exists to establish, and a fleet-wide hold is recoverable while a fleet-wide
merge on unverified bases is not. The bounded retries on each read are what keep an
ordinary transient blip from reaching that state.

## Consequences

- `.github/workflows/ai-review-merge.yml` freshness fails closed on an unanswerable
  compare. Repositories will occasionally see a red freshness step where they previously
  saw a silent pass; that red is the intended signal, not a regression.
- `scripts/ci-gate/verify-zero-provider-recovery.sh` emits four distinct messages where it
  emitted one. Any tooling or runbook matching the literal string
  `missing or not unique` must be updated; the org-owned test that asserted it has been.
- **Audit of the sibling pattern.** #1476 required every `2>/dev/null ||` default in
  `ai-review-merge.yml` to be audited, not just the reported one. On the base of this
  branch that pattern occurs on 25 lines (26 occurrences: line 877 chains two `git fetch`
  fallbacks on one line). One of the 25 is the compare site this ADR fixes; the remaining
  24 were traced to what consumes them: 1 remaining decision-bearing fail-open, 13 decision-bearing but
  fail-closed (an empty default can only force the conservative branch — the full paid
  review, or an explicit `exit 1`), and 10 non-decision (logging, telemetry, labels, or an
  already-terminal path).
  - **That classification covers one textual pattern, not every fail-open**, which is
    exactly how the second one was nearly missed. The `pr_json` metadata read does not
    match `2>/dev/null ||`, so the audit #1476 asked for could not have found it: when its
    three bounded attempts all failed, the step emitted a `::warning::` and ran
    `out proceed true; exit 0` — the same shape this ADR rejects, one branch earlier in
    the same step. It is **fixed in this change** (#1496), not merely disclosed, because
    leaving it would have falsified this ADR's own central claim: a total outage would
    still have proceeded, and the compare guard would have been unreachable on precisely
    the path it was written for. The cost is accepted knowingly — every PR that hits a
    sustained metadata blip now reds instead of proceeding.
  - The remaining fail-open **within the audited pattern** is the Renovate release-age
    lookup, where a failed
    `commits/$head_sha/status` request yields `age_pending=0` and the PR enters the normal
    review lane instead of `lane=defer`. Its blast radius is materially smaller than
    #1476's — it wastes a paid review and re-enters the gate, rather than merging on an
    unverified base — so it is tracked separately rather than folded into this change.
- **ADR 0194's Consequences could not be updated here.** #1476 asks for that, but 0194 is
  not on `main`: it is in flight on the open draft PR #1469, which this branch must not
  touch. This ADR therefore cites 0194 rather than amending it, and the cross-reference
  from 0194 remains outstanding.
