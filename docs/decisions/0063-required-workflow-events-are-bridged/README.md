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
on `pull_request_target` to the two activity types that leave a pull request wedged —
`ready_for_review`, and `unlabeled` for a terminal hold — and converts them into the
one entry point that does work: a `workflow_dispatch` of `ai-review-merge.yml`, which
runs under the gate's own record.

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
- **Fail closed.** An unreadable, malformed or truncated metadata response aborts
  under `set -euo pipefail` and dispatches nothing. The hold predicate is materialised
  into a `true`/`false` string rather than tested with `if jq -e …`, because a jq that
  *errors* also exits non-zero and an `if` would read that as "not held".

## Consequences

- Marking a draft ready re-enters the gate without a human pushing a commit, and
  removing a terminal hold does what #88 intended.
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
