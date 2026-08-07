# 0063 — A required workflow only sees three activity types, so the rest are bridged

- **Date:** 2026-08-06
- **Issue:** [Verjson/.github#468](https://github.com/Verjson/.github/issues/468)
- **Extends:** ADR 0039 (organization required-workflow runs are trusted gate provenance)
- **Constrained by:** ADR 0012 (`hold` / `DO NOT MERGE` / draft are terminal)

## Context

`ai-review-merge.yml:81` declares six `pull_request` activity types. Three of them
have never produced a single run in this organization: converting a draft to ready,
labelling, and unlabelling all leave a pull request carrying the gate's three checks
as `SKIPPED` from its last draft-era `synchronize`, with `mergeStateStatus` at
`BLOCKED` and nothing failing. The documented remedies — push an empty commit, or
`gh workflow run ai-review-merge.yml -f pr_number=N` — are invisible from the pull
request page, and the workflow `CLAUDE.md` prescribes ("open as draft, review out of
band, then mark ready" / "apply `hold` … then remove it") ends in exactly this state.

The cause is not the trigger declaration. ADR 0039 records that Verjson does not
install the gate as a repository workflow or as a reusable: the organization ruleset
`main-protection` (id `18098028`) carries a `workflows` rule mandating
`.github/workflows/ai-review-merge.yml` at `refs/heads/main` from `Verjson/.github`,
for `~ALL` repositories on the default branch. **A required workflow is scheduled by
the ruleset, not by its own `on:` block.** Its runs are created under a separate
workflow record that the workflows API does not list, and the ruleset fires them for
`opened`, `synchronize` and `reopened` only.

### Evidence

Measured on `Verjson/.github#471`, a throwaway pull request carrying four probe
workflows that declare the same trigger surface as the gate but are not
required-enforced. `probe-c` copies the gate's `types:` list verbatim; `probe-e`
copies the gate's entire `on:` block — all three arms — plus its `permissions`,
`env` and `concurrency` blocks.

| event | `AI review + auto-merge` | `probe-c` / `probe-e` |
| --- | --- | --- |
| `opened` (draft) | run `31112879942` | run `31112879789` / n/a |
| `synchronize` | run `31114028691` | run `31114027797` / `31114027754` |
| `reopened` | run `31114568043` | run `31114570224` / `31114567825` |
| `ready_for_review` | **no run** | run `31114341482` / `31114341550` |
| `labeled` | **no run** | run `31113666002` / n/a |

Two independent confirmations of the same mechanism:

- Of the 139 runs recorded under the gate's own workflow record (`312358392`), the
  100 most recent are **all** `workflow_dispatch`. Every `pull_request` run of the
  gate lives under record `312358877`, which `GET /actions/workflows/312358877`
  answers with `404` — the ruleset's record, not the file's.
- `ai-privileged-merge.yml:5` declares the identical types list on
  `pull_request_target` and is not required-enforced; it fires on
  `ready_for_review` every time.

The three dead types were added deliberately — `ready_for_review` in the gate's first
commit, `unlabeled` by #88 ("re-fire after terminal hold removal"). `scripts/ci-gate/hold.test.sh`
pins both, and both pins have been passing while asserting a capability that never
existed. This is the same failure shape this repository has hit before: a guard that
cannot fail.

## Decision

Keep the required-workflow installation. It is what ADR 0039/0044 bind gate
provenance to, and replacing it would mean re-deriving trust for ~90 repositories in
order to fix an ergonomics defect.

Instead, **bridge the missing events**. `.github/workflows/gate-rearm.yml` subscribes
on `pull_request_target` to `ready_for_review`, `labeled` for `re-review`, and
`unlabeled` except for `re-review` cleanup, then converts them into the one entry
point that does work: a `workflow_dispatch` of `ai-review-merge.yml`, which runs
under the gate's own record.

Constraints the bridge holds, pinned by `scripts/ci-gate/gate-rearm.test.sh`:

- **Terminal stays terminal.** Draft, a `hold` or `DO NOT MERGE` label (case- and
  separator-insensitive), and a `DO NOT MERGE` title marker all suppress the re-arm.
  The job guard reads the event payload; the step re-reads live pull-request state,
  because the payload is a snapshot taken before the job was scheduled. The predicate
  is the gate's own, reused verbatim, and the test pins the two copies to each other.
- **No re-entrancy.** A dispatch produces a `workflow_dispatch` run, which emits
  neither `ready_for_review` nor `unlabeled`. The gate's own label churn — it removes
  `re-review` after consuming it — is excluded by name in the guard, so the gate can
  never re-dispatch itself.
- **No privileged execution of head code.** `pull_request_target` is required because
  a fork pull request's `pull_request` token cannot dispatch a workflow. The job
  checks nothing out, runs no third-party action, and passes no pull-request-controlled
  text to a shell; the pull request number is validated against `^[1-9][0-9]*$` and
  the repository against `github.repository` before any API call. Its token holds
  `contents: read`, `actions: write`, `pull-requests: read` and nothing else.
- **Fail closed.** The hold predicate is materialised into a `true`/`false` string in
  a plain assignment rather than tested with `if jq -e …`. That is what makes it fail
  closed: a jq that *errors* also exits non-zero, and an `if` would read that as "not
  held" and dispatch anyway, whereas an assignment lets `set -e` abort the step. The
  `case` that follows only routes the two values jq can print; its `*)` arm is
  belt-and-braces, not the mechanism. So an unreadable, malformed or truncated
  metadata response dispatches nothing. The gate's own hold checks still use the
  fail-open `if jq -e …` shape — tracked as
  [#482](https://github.com/Verjson/.github/issues/482).
- **A skipped run cannot cancel a live one.** `concurrency:` is declared on the
  `rearm` job, not on the workflow. A workflow-level group is claimed before the job
  guard is evaluated, so the denied `unlabeled` event for `re-review` cleanup would
  create a run that seizes the group, cancels an in-flight re-arm mid-dispatch, and is
  then skipped by its own `if:` — leaving the pull request wedged, which is #468
  reached by another route. Cancellation is off for the same reason: the job is one
  idempotent dispatch, and the gate has its own concurrency group, so queueing a
  second re-arm is safer than killing the first.

## Consequences

- Marking a draft ready re-enters the gate without a human pushing a commit, and
  removing a terminal hold does what #88 intended.
- **The stale `SKIPPED` checks are not repainted.** The bridge dispatches the gate;
  per [#475](https://github.com/Verjson/.github/issues/475) a `workflow_dispatch`
  run's check runs never attach to the pull request. So the three gate checks left
  over from the last draft-era `synchronize` stay `SKIPPED` on the pull request page,
  and the review runs and the merge lands out of view of the checks list, through the
  privileged lane's ruleset bypass. The user-visible outcome — the pull request stops
  being wedged and merges when it should — is what is fixed; the checks list is not.
- **Consequently the bridge does not satisfy a required `gate` check.** ADR 0058 step
  5 proposes requiring `gate` on `~ALL`, which [#474](https://github.com/Verjson/.github/issues/474)
  already blocks. If that ever lands, a bridged dispatch will not produce the required
  check run either, and a readied draft would be wedged again — this time by branch
  protection rather than by an absent review. Requiring `gate` and keeping the bridge
  are not independent decisions.
- **The `labeled` lane stays dead.** `labeled` was measured dead alongside the other
  two, and the bridge deliberately does not carry it: bridging it means every label
  application dispatches a model review from a privileged context unless the guard is
  narrowed to `re-review` exactly. So the gate's documented re-review lane
  (`ai-review-merge.yml:26`, `:165`) still never fires. Bridging it or retiring it is
  tracked as [#481](https://github.com/Verjson/.github/issues/481).
- The bridge is defence in depth, not the sole guard: the gate re-checks holds at its
  classify and merge checkpoints, so a bridge that wrongly dispatched a held pull
  request would still not merge it.
- **This fixes `Verjson/.github` only.** The ruleset targets every repository in the
  organization, so every one of them has the same three dead activity types. Rolling
  the bridge out to the fleet — as a generated caller, in the shape of
  `gen-privileged-merge-caller.sh` — is tracked separately and deliberately not done
  here.
- The gate keeps its six declared `pull_request` types. They are inert under a
  required-workflow installation but correct for a direct or reusable one, and
  removing them would break a consumer that installs the gate the documented way.
- One more workflow runs per readied pull request. It makes a single API call on the
  fast lane and exits in seconds.

## Alternatives rejected

- **Drop the `workflows` rule from `main-protection`** so the gate's own `on:` block
  takes effect. This is the root-cause fix and it is wrong here: required-workflow
  runs are the provenance ADR 0039/0044 bind the privileged merge to, and the rule
  spans ~90 repositories. A sensitive, organization-wide trust change to recover
  three activity types is not proportionate.
- **Teach `ai-privileged-merge.yml` to dispatch the gate.** It already fires on
  `ready_for_review`, so it is the cheapest place to hang the logic — and the worst.
  It is a reusable consumed org-wide under the most privileged token in the fleet;
  adding an unrelated concern there widens the blast radius of every future change to
  it. A separate workflow with a three-permission token is the smaller surface.
- **Poll for wedged pull requests** from `fleet-watchdog.yml`. Correct eventually, but
  it turns a synchronous action into a delayed one and adds a scheduled job whose
  cost scales with the fleet rather than with the events.

## 2026-08-07 amendment — the `re-review` lane is bridged too (#481)

ADR 0063 bridged `ready_for_review` and `unlabeled`-of-a-terminal-hold, and
deliberately left `labeled` out: bridging it wholesale dispatches a paid model
review on every label application, from a privileged context. #481 recorded that as
a scope decision to take on its own. Taking it now.

`labeled` is bridged for **`re-review` only**, matched in the job `if:` rather than
re-checked in the step. That placement is the safety property: a name checked later
would still start a job — and bill a runner — for every label on every pull request
in the fleet. The narrowing is what makes the arm admissible at all, so the guard
pins the exact name and a test asserts that ordinary labels (`needs-review`,
`blocked`, `documentation`) do not appear in it.

Retiring the lane instead was the other option #481 offered. Bridging won because
the gate already documents the lane and guards it at `ai-review-merge.yml:165`, and
because a documented capability that silently does nothing is worse than either
having it or not: it reads as working.

**No re-entrancy, and this was already load-bearing.** The gate *consumes*
`re-review` by removing it (`ai-review-merge.yml:403`), which emits `unlabeled` —
and the `unlabeled` arm admits only the terminal-hold spellings. So the gate's own
cleanup cannot re-arm the gate. The exclusion predates this change; adding the
`labeled` arm is a no-op for it. Both halves are now pinned: that the removal path
excludes `re-review`, and that the gate is still the actor doing the removing —
because the loop analysis is only sound while that remains true.

Unchanged: `#292` means the re-review *skip* optimisation is still dead in
production (the gate cannot resolve its own identity under `github.token`), so a
re-review currently re-pays for an unchanged diff. This amendment makes the lane
fire; it does not make the skip work. The two are independent, and #292 carries a
design brief for the second.

## 2026-08-07 amendment — hold removal uses a denylist guard (#497)

The `unlabeled` arm enumerated four hold spellings, but the authoritative predicate
normalizes arbitrary runs of spaces, underscores, and hyphens. A valid hold such as
`DO__NOT__MERGE` therefore stopped the gate but its removal did not re-arm it.
Actions expressions cannot reproduce jq's `gsub("[ _-]+";" ")`, so no finite
allowlist can be equivalent to the predicate.

The arm now admits every `unlabeled` event except removal of `re-review`. The gate
removes `re-review` itself after consuming it, so that explicit denylist preserves
the no-re-entrancy invariant. The step's live, fully normalized predicate remains
authoritative and prevents dispatch while any terminal hold is still present.

This trades a cheap fast-lane job on unrelated label removal—and a dispatch when the
pull request is otherwise eligible—for correctness across the predicate's complete
hold language. The regression test pins both sides with `DO__NOT__MERGE`: the generic
guard admits its removal and the live predicate still counts it as a hold.
