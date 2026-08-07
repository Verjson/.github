# 0058 — GitHub waits for required checks; the gate stops being an orchestrator

- **Date:** 2026-08-05
- **Issues:** [Verjson/.github#341](https://github.com/Verjson/.github/issues/341)
  (no merge-gate job polls on the shared pool),
  [#263](https://github.com/Verjson/.github/issues/263) (draft-time gate skip is
  terminal), [#414](https://github.com/Verjson/.github/issues/414) (watchdog
  cadence), [#472](https://github.com/Verjson/.github/issues/472) (execution of
  steps 1–5, see the amendment below)
- **Supersedes the direction of:**
  [ADR 0049](../0049-fleet-watchdog-preempts-poll-jobs/README.md) and
  [ADR 0056](../0056-fleet-watchdog-retained-and-retargeted/README.md) — both
  manage a deadlock this ADR removes. Neither is reversed here; they remain
  correct until the migration below completes.
- **Category:** merge-gate behaviour + **branch protection ruleset** (sensitive
  class, org-wide blast radius)

## Context

`gate` holds a self-hosted runner for up to 30 minutes and `privileged_merge`
for up to 45, doing nothing but polling the commit check-runs and statuses
rollup for a head SHA (`ai-review-merge.yml:581-947`). On a fixed-size pool a
sleeping job is indistinguishable from a working one, and the work being waited
on needs the runner being slept on. That is a deadlock, not a queue.

Every mitigation so far has managed the deadlock rather than removed it: a fast
lane for `shell-tests` (ADR 0047), hosted routing for public targets (ADR 0048,
which reaches 2 of 90 repositories), a watchdog that preempts poll jobs after
the jam forms (ADR 0049/0056), and an overflow lane that moves `gate` to hosted
capacity (ADR 0053, explicitly temporary borrowed budget).

The thing none of them names: **the poll loop is a hand-rolled, worse
reimplementation of a rule GitHub already enforces server-side, for free, while
holding zero runners.**

Two facts make this actionable, and both were verified rather than assumed:

1. `main-protection` (ruleset `18098028`) is an **organization** ruleset with
   `conditions.repository_name.include = ["~ALL"]`. Its rules are `deletion`,
   `non_fast_forward`, `required_linear_history`, `pull_request`, `workflows`.
   **There is no `required_status_checks` rule.** GitHub has never been told
   which checks must pass, so it cannot wait for them, so the gate does it in
   bash.
2. `allow_auto_merge` is already `true`, and the ruleset already restricts
   `allowed_merge_methods` to `squash`.

The gate's own merge step is already dead (`ai-review-merge.yml:1587` is
`if: ${{ false }}`); the merge is performed by `ai-privileged-merge.yml`, which
is the job still on `VERJSON_LANE_PRIVILEGED` and the one the watchdog has
actually preempted.

## Decision

**Declare required checks to GitHub, enable native auto-merge, and reduce the
gate from an orchestrator to a participant.**

- The gate **stops waiting**. It reviews the diff, publishes a verdict as its
  own check conclusion and a PR review, and exits — minutes, not tens of
  minutes, and never idle on a runner.
- **GitHub does the waiting**, because waiting is what the platform is for.
  Auto-merge merges when every required check is green and review requirements
  are met.
- The poll loop, the self-job-exclusion logic it needs (#276), the absent-checks
  grace window (#143) and the `allow_absent_checks` escape hatch all cease to
  exist. They are all consequences of consuming the rollup by hand; nothing
  consumes it by hand any more.

### Required checks are a declared core contract, not an observed one

Observed contexts today vary per repository — `.github` has `shell-tests`,
`verjson-upload` has `ci / build-test`, `verjson-infra` adds
`changelog / validate` and two bespoke names. **This variance is drift, not a
constraint to design around.** Deriving required checks from what each
repository happens to emit would make the archaeology permanent and enshrine a
stale repository's naming as organizational policy.

Instead the organization **declares a core set of check names per repository
stack**, and repositories conform to it.

The contract surface already exists. A reusable call's check name is
`<caller job> / <inner job>` **only when the caller job is unmatrixed**. A
`strategy.matrix` changes every emitted context to
`<caller job> (<matrix values>) / <inner job>`, so the canonical unmatrixed
context is absent, not merely renamed. The org already pins every right-hand
side:

| Reusable workflow | Inner jobs (org-pinned) |
| --- | --- |
| `node-ci.yml` | `eligibility`, `build-test` |
| `helm-ci.yml` | `lint-template` |
| `pulumi-ci.yml` | `validate`, `preview-admission`, `preview` |
| `ui-ci.yml` | `build-test` |
| `changelog-validate.yml` | `validate` |

The free variables are the **caller's job name** and whether it has a matrix.
A generated thin caller pins both — the pattern already established by
`scripts/gen-changelog-caller.sh` and `scripts/gen-privileged-merge-caller.sh`.
Canonical caller job names are therefore part of the contract: `ci` for the
stack CI workflow, `changelog` for changelog validation, and both must be
unmatrixed. Multi-version coverage uses one unmatrixed canonical caller plus
separately named additional jobs, or one unmatrixed job per version with only
the selected canonical job placed under required checks.

The core set becomes small, declarable and stack-scoped:

| Scope | Required contexts |
| --- | --- |
| Every repository | `gate` |
| Every package repository | `changelog / validate` |
| `node` | `ci / build-test`, `ci / eligibility` |
| `ui` | `ci / build-test` |
| `helm` | `ci / lint-template` |
| `pulumi` | `ci / validate`, `ci / preview` |
| `actions` (this repository) | `shell-tests` |

`gate` is universal because the existing `workflows` rule already forces
`ai-review-merge.yml@main` to run everywhere.

`changelog / validate` is treated as core for every package repository rather
than as a per-repository opt-in: the changelog contract (ADR 0038) is the
direction of travel for all packages, and a check that is core is one every new
repository inherits instead of acquiring by remembering to.

**This makes changelog adoption a prerequisite of the migration, not a parallel
track.** A repository that does not yet call `changelog-validate.yml` emits no
`changelog / validate` context, so requiring it there is the permanently-pending
wedge described below. Two consequences follow, and both are load-bearing:

1. Every package repository must be wired to the changelog contract **before**
   the `changelog / validate` requirement goes `active` for it. `evaluate` mode
   is what surfaces the repositories that are not.
2. **#404 is on this critical path.** It shipped the reusable workflow but not
   the generated thin caller, so there is currently no generated artifact that
   pins the caller job name to `changelog`. Until that caller exists, conformance
   is by hand-written convention — which is exactly the drift this section
   replaces. The caller generator is a prerequisite for requiring the context,
   not a tidy-up after it.

Scoping is by **custom repository property** (`conditions.repository_property`),
so each stack is one org-level ruleset rather than ninety repository-level ones.
The org property schema is currently empty and must be created first;
`verjson-stack` is defined with one allowed value per row above.

### A required check must be skippable, but never absent

The distinction that makes this safe, and the one thing every consumer must get
right:

- A **conditional job** (`if:` false) reports a check run with conclusion
  `skipped`, which satisfies a required check. Safe to require.
- A **`paths:`-filtered workflow** that does not match emits **no check run at
  all**, which is permanently pending. Requiring it wedges the repository.

So the core contract requires that a stack's CI workflow is **not
`paths:`-filtered at the workflow level**. Work is gated with job-level `if:`
instead. `node-ci`'s `eligibility` and `pulumi-ci`'s `preview-admission` are
already conditional jobs, and are safe to require for that reason.

Note also that `privileged_merge` appears bare in the required-workflow install
shape and as `privileged_merge / privileged_merge` in the reusable-call shape.
Neither is ever required — see below — but the same ambiguity applies to any
context, which is a second reason to pin caller job names by generation rather
than by convention.

### The merge machinery is never a required check

`dispatch-merge` and `privileged_merge` **perform** the merge. A merge that
waits for them waits for itself. They are excluded from every tier, in both
install shapes.

### Survey: the contract covers a minority of the organization

Measured with `scripts/classify-repo-stacks.sh` on 2026-08-05, across 91
non-archived repositories:

| Result | Count | Meaning |
| --- | --- | --- |
| conformant | 40 | emits its stack's contexts under canonical caller names |
| **nonconformant** | **6** | calls a reusable CI workflow from a non-canonical job, so the contract would wedge it |
| **unrecognised CI** | **45** | defines real workflow jobs but calls no reusable CI at all |

Stacks: 18 `node`, 2 `actions`, 1 each `ui` / `helm` / `pulumi`. **18 of 91 are
on the changelog contract.**

The 45 are the finding that matters, and they were invisible until `none` was
split from "no CI at all". They are not empty repositories — `scv-k8s` defines
53 jobs, `scv-iac` 34, `verjson-observability` 16. Requiring only `gate` there
would take repositories with substantial CI and make that CI **advisory**: their
merges would stop waiting for the checks they wait for today, silently, with no
PR failing to announce it.

So the two-tier model holds but its second tier cannot be empty for these. Each
of the 45 needs one of:

1. **Adopt a reusable stack workflow** — brings it into the contract, and is the
   direction the org is already travelling.
2. **Declare its own required checks** at repository scope — legitimate as a
   transitional mechanism for a repository the contract does not describe. Note
   this is *deriving* required checks from what a repository emits, rejected
   above as organizational policy; it is acceptable here precisely because it is
   scoped to one repository and explicitly transitional, not a rule for the org.
3. **Confirm it genuinely has no merge-blocking CI** — true for template and
   docs repositories, and it must be a decision on the record rather than a
   default nobody noticed.

Only the owner of each repository can make that call, which is why the audit
reports and does not decide.

## Migration order is the load-bearing part

**Per-repository required checks must land before the gate stops waiting.**

Until a repository declares its CI contexts, auto-merge considers only the
checks it knows are required — so between "gate stops waiting" and "repository
declares its CI", nothing verifies CI at all and a red PR merges. That window is
a worse defect than the deadlock this ADR removes.

Sequence, each step reversible on its own:

1. Create the `verjson-stack` custom property schema and classify every
   repository. Classification is data, not enforcement, so this step cannot
   block anything.
2. Land the generated changelog thin caller (#404) and wire package
   repositories to it, so `changelog / validate` actually reports where it will
   be required. Conformance audit (`scripts/required-checks-audit.sh`) reports
   which repositories do not yet emit their stack's core set.
3. Create one org ruleset per stack carrying the core contract, at
   `enforcement: evaluate`. Evaluate mode reports what *would* be blocked
   without blocking anything — the ruleset equivalent of the dry-run discipline
   this repository already applies to destructive automation.
4. Read the evaluate-mode results and drive the audit to zero. A context that
   never reports is the failure mode to hunt for here, and it is visible in this
   step and cheap in this step only.
5. Promote the stack rulesets to `active`, and add `gate` to the `~ALL` rule.
6. **Only now** remove the poll loop and switch to auto-merge.
7. Retire the watchdog.

Steps 1–2 are the real work and they are ordinary conformance work, not
ruleset work. Steps 3–5 are cheap once the audit is clean, and dangerous if it
is not — which is the entire reason the audit exists as a separate artifact.

**The watchdog stays armed and load-bearing for the whole of steps 1–5.** It is
the only mitigation for a `privileged_merge` jam, and this migration does not
reduce that exposure until step 5. Fixing its defects is therefore still worth
doing while this proceeds; ADR 0056 stands until step 6.

### Amendment (2026-08-06) — steps 1–5 executed, with two corrections

Steps 1 through 5 were carried out. Two things this ADR asserted turned out to be
wrong, and one measurement changed the shape of what could land.

**Evaluate mode does not work on this organization.** Steps 3 and 4 above are built on
it, and the plan is unexecutable as written. The rulesets API *accepts*
`enforcement: evaluate` on a Team plan — confirmed with a probe ruleset scoped to a
non-existent repository, since deleted — but `GET /orgs/Verjson/rulesets/rule-suites`
returns `403 Upgrade to GitHub Enterprise to enable this feature`. A staged rule here
blocks nothing *and* reports nothing, which is strictly worse than either alternative
because it looks like protection. The dry-run discipline was preserved by measuring the
blast radius directly instead: sweep every open non-draft PR for the check-runs a rule
would require, classify what would be blocked, remediate or exempt, then go straight to
`active`. Recorded in full in ADR 0061, which applied the same method first.

**Scoping needed a second property.** `verjson-stack` alone cannot express the rulesets,
because a nonconformant repository still belongs to its stack — scoping the node rule on
`verjson-stack == node` would have included `verjson-ai`, whose caller job name means the
contexts never report. A second property `verjson-core-checks` (`enforced` / `exempt`)
carries conformance, and a ruleset condition naming both properties ANDs them. Verified
empirically rather than assumed: `verjson-email` (node, conformant) receives
`ci / build-test` and `ci / eligibility`; `verjson-ai` (node, exempt) receives neither.

**Re-measured 2026-08-06** with `scripts/classify-repo-stacks.sh` across the same 91
non-archived repositories: 43 conformant, 4 nonconformant, 44 unrecognised CI — 19 `node`,
2 `actions`, 1 each `ui` / `helm` / `pulumi`, 67 `none`.

What landed:

| Ruleset | Scope | Required contexts |
| --- | --- | --- |
| `core-checks-node` (20515817) | `verjson-stack=node` ∧ `verjson-core-checks=enforced` — 18 repositories | `ci / build-test`, `ci / eligibility` |
| `core-checks-actions` (20515822) | `verjson-stack=actions` ∧ `enforced` — 2 repositories | `shell-tests` |
| `changelog-contract-required` (20513599) | `changelog-contract=adopted` — 23 repositories (ADR 0061) | `changelog / validate` |

Both new rulesets are `active`, `strict: false`, `do_not_enforce_on_create: true`, bypass
`OrganizationAdmin` only. Blast radius before activation: of 25 open non-draft PRs on the
18 node repositories, 19 already satisfied both contexts and 6 did not — **none because the
context was absent.** One was in progress; five were genuinely failing `ci / build-test` and
had been mergeable anyway, which is the defect being closed.

`helm`, `pulumi` and `ui` get no ruleset: each stack has exactly one repository and all
three are nonconformant, so there is nothing yet to enforce.

**Step 5's second half — adding `gate` to the `~ALL` rule — is held, and the measurement is
why.** The corrected complete-context audit on 2026-08-06 found **14 of 97** open non-draft
PRs without the current `gate` context, not the earlier 53-of-87 estimate. Two were runs in
flight; the remaining 12 span six repositories. Six carry the gate's legacy
`classify`/`ai-review`/`ai-merge` names and six have no gate history. Requiring the current
context would wedge all 12 permanently, which is the exact "permanently pending" failure
this ADR names in *A required check must be skippable, but never absent*. Requiring `gate`
is deferred until an ownership-routed re-trigger sweep is done and a fresh audit reports
zero.

### Amendment (2026-08-07, #474) — make the sweep reproducible and ownership bounded

`scripts/gate_coverage_audit.py` pages the organization-wide open-PR search and verifies
that every head check-rollup is complete before deciding that `gate` is absent. It reports
one JSON line per exact `owner/repo#PR`, including draft, hold, fork, canonical workflow
availability, legacy-context/head-stale reason, and the supported retrigger.

The default is read-only. A repository-local active workflow uses the canonical
`re-review` label. An organization-required workflow uses reversible close/reopen because
the required-workflow record does not receive `labeled` events (#477). Both produce
PR-associated events without pushing to another author's branch or using
`workflow_dispatch` (whose checks do not attach to the PR rollup). Mutation
requires both `--apply` and an exact repeated `--authorize-repo owner/repo`; eligible PRs
outside that set are emitted as `refused_unmanaged`. Rate limits, truncated check
connections, malformed pages, and unavailable repository metadata fail the whole audit
closed rather than undercounting the gap.

The JSON output is the compact durable handoff surface: group refused records by repository
and route one repository-level handoff to its owning PM. Do not create one tracker per PR.
The tool contains no workflow-dispatch, push, or merge operation. Close/reopen is available
only for an exact authorized repository whose required-workflow shape needs that event.

**Step 6 is therefore blocked for most of the organization, and blocked for a reason this
ADR already gives.** The 67 `none` repositories have declared no required checks. If the
gate stops waiting there before they do, their CI becomes advisory silently — the window
this ADR calls "a worse defect than the deadlock". Step 6 can proceed only where required
checks exist, which today means the 18 node and 2 actions repositories. Any implementation
of step 6 must therefore be conditional on the target repository having declared required
checks, so the poll loop retires per repository as each conforms, rather than org-wide on a
single date.

### Amendment (2026-08-06) — step 6 shipped, conditional per repository

Implemented in `ai-review-merge.yml`, `gate` job, step `Wait once for the rest of CI to
be green`. Before the poll loop the gate asks GitHub what it already requires:

```
GET /repos/{owner}/{repo}/rules/branches/{base_branch}
```

If any rule of type `required_status_checks` names at least one context, the gate emits
`::notice::phase=ci-wait result=required-checks-declared` and exits 0 without reading the
rollup. If none does, it polls exactly as before. This is the conditional form the
amendment above requires: no allowlist and no per-repository variable, so a repository
opts itself in the moment a ruleset is scoped to it, and the 66 repositories that declare
nothing keep the gate as their only CI verifier.

**Skipping does not make a red PR mergeable.** The ci-wait poll was never the merge
precondition it looks like: `ai-review-merge.yml`'s own merge step has been `if: ${{ false
}}`, and the live path is `dispatch-merge` → `ai-privileged-merge.yml`, which
independently polls the whole rollup to `failed == 0 && pending == 0` before its `--admin`
squash. What the gate's poll actually buys is *not paying for a model review of a PR that
fails its own CI*, and that cost is what step 6 trades away where GitHub is already
blocking the merge.

**The measurement that scopes it.** Re-run across the same 91 non-archived repositories on
2026-08-06 (`GET /repos/{o}/{r}/rules/branches/{default_branch}` per repository):

| Required contexts on the default branch | Repositories |
| --- | --- |
| none | 66 |
| `changelog / validate`, `ci / build-test`, `ci / eligibility` | 17 |
| `build-test`, `changelog / validate` | 2 |
| `changelog / validate` | 2 |
| `changelog / validate`, `ci / build-test`, `ci / eligibility`, `guard` | 1 |
| `changelog / validate`, `shell-tests` | 1 |
| `shell-tests` | 1 |
| endpoint answers `403 Upgrade to GitHub Pro` | 1 |

**Two residuals this amendment states rather than solves.** First, the skip keys on *any*
required context, not on a repository's *core set*: the four repositories that require only
`changelog / validate` (or only `build-test` under a bare, non-`ci /` job name) stop having
their remaining CI waited on by the gate, even though `ai-privileged-merge.yml` still
refuses to merge them red. Second, `GET /rules/branches` does not report a rule's
enforcement, so a rule staged in `evaluate` mode would read as blocking. That is inert here
— rule-suites is `403` on this plan (see the previous amendment), so nothing in this org is
staged — but it stops being inert the day the org moves to Enterprise.

**Fail-closed is the load-bearing property, and it is pinned by mutation.** Every branch of
the probe falls back to polling: an API error, a body that is not an array (the `403`
repository above returns a JSON *object*, and `.[]` over an object iterates its values
rather than failing), an unparseable or empty payload, a rule with no named context, an
unreadable PR, or a base branch that fails validation. The base branch is the PR's own —
`github.event.pull_request.base.ref`, falling back to `gh pr view` on the
`workflow_dispatch` / `workflow_call` paths that carry no payload — and it is validated
before it reaches an API URL: a bare ASCII ref, no `..`, and the allowlist is evaluated in a
C-locale subshell because under `en_US.UTF-8` a bash `[[ =~ ]]` range of `A-Za-z` matches
`ü` (verified on bash 5.2), which would otherwise admit a non-ASCII ref.
`scripts/ci-gate/required-checks-skip-poll.test.sh` extracts the shipped step and executes
it against a stubbed `gh`; ten separate mutations of the guard were each killed by a named
assertion, including the two that survived the first draft of the suite.

**Steps 5b and 7 stay open.** Requiring `gate` on `~ALL` is still blocked by the 53
gate-less open PRs (#474), and the watchdog stays armed: `ai-privileged-merge.yml` still
polls, still routes on `VERJSON_LANE_PRIVILEGED`, and is untouched by this step. ADR 0056
therefore still stands.

### Amendment (2026-08-07) — matrixed reusable callers are nonconformant (#431)

The static classifier originally checked the reusable workflow filename and
caller job key, but not `strategy.matrix`. That admitted a caller named `ci`
even though GitHub emitted only `ci (20.20.2) / build-test`,
`ci (24) / build-test`, and their eligibility counterparts. Requiring the
canonical unmatrixed names would have wedged the repository while the
classifier called it conformant.

`scripts/classify-repo-stacks.sh` now treats a matrix on any recognized reusable
CI or changelog caller as nonconformant and names the suffixed context shape in
its remediation. The fixtures cover block and flow-style matrices and both
orders of `strategy` and `uses`.

The Groups B/C re-sweep projected all non-archived repositories'
default-branch workflow blobs in one read-only GraphQL query. One live instance
remained: `Verjson/verjson-customer-lifecycle`, whose `ci` job matrices Node
20.20.2 and 24 around `node-ci.yml@v2.2.0`; remediation is handed off in
[verjson-customer-lifecycle#16](https://github.com/Verjson/verjson-customer-lifecycle/issues/16).
No consumer repository was changed here.

Ruleset activation has a second head-level gate: after the default-branch
workflow is remediated, every open PR must be rebased or updated onto that
commit before canonical contexts are required. Older PR heads still contain
the matrixed workflow, so GitHub cannot produce checks that did not exist when
those heads were created.

## What this must preserve, and how

- **Anti-TOCTOU head binding (ADR 0039).** Strengthened, not weakened. Today the
  gate re-derives and re-checks the head in bash. Under auto-merge, check runs
  are bound to a SHA by GitHub, and `dismiss_stale_reviews_on_push` plus
  `require_last_push_approval` (both already set) mean a push invalidates the
  approval. The platform enforces the binding the gate approximates.
- **Provenance (ADR 0044).** Unchanged. The `workflows` rule still pins
  `ai-review-merge.yml@refs/heads/main` as the entry workflow, and `gate`
  becoming a required context makes that binding *stronger* — the review verdict
  is now a merge precondition GitHub enforces, not one the gate self-asserts.
- **`hold` / `DO NOT MERGE` / draft (ADR 0012).** Auto-merge does not know about
  labels, so a required `merge-hold` check re-evaluated on
  `pull_request: labeled|unlabeled|ready_for_review` carries this. It fails while
  a hold label is present and passes when it is removed. This also closes #263:
  the hold becomes a check that can flip back to green, instead of a gate skip
  that is terminal until a new head SHA.
- **Privileged merges.** PRs touching `.github/workflows/**` are blocked by the
  `workflows` rule for ordinary actors. Auto-merge is performed as the actor that
  enabled it, so a bypass actor enabling auto-merge replaces
  `ai-privileged-merge.yml` entirely. The bypass list (`OrganizationAdmin`,
  `Integration 2740`) is unchanged by this ADR — no new privilege is granted.

### Open question: which actor satisfies the approval rule

The `pull_request` rule requires `required_approving_review_count: 1`. **Today
that requirement is not satisfied — it is bypassed.** PR #408 carried zero
reviews while its gate ran to success, and the merge path is
`Integration 2740` / `OrganizationAdmin` with `bypass_mode: always`.

`require_code_owner_review: true` is currently vacuous: the repository has no
`CODEOWNERS` file, so no path has an owner. That is worth knowing before anyone
adds one, because adding `CODEOWNERS` would silently make code-owner approval a
real precondition for every auto-merge.

Two candidate paths, and this ADR does not pick one because the choice must be
verified empirically on a live PR rather than reasoned about:

1. **Auto-merge enabled by the bypass actor.** Preserves today's behaviour
   exactly — the approval rule is bypassed as it already is — and needs no new
   privilege. It also means the review rule continues to enforce nothing, which
   is honest only if stated.
2. **The gate's review counts as the approval.** The gate already has a
   "Submit deterministic PR review" step. If that review is attributed to an
   actor that is not the PR author, it satisfies the rule without any bypass,
   and the ruleset becomes load-bearing rather than decorative. This is the
   better end state.

**Verification before step 6:** open a throwaway PR, enable auto-merge as the
intended actor, and confirm it merges with the required checks green and no
manual `--admin`. Do not infer this from documentation; the interaction between
bypass actors, `require_last_push_approval` and auto-merge is exactly the kind of
thing that behaves differently than it reads.

## Consequences

- No merge-gate job polls on any pool, which closes #341 structurally rather
  than by configuration. Returning `VERJSON_RUNNER_OVERFLOW` to a self-hosted
  value can no longer reintroduce the deadlock, because there is no poll to
  reintroduce.
- ADR 0053's overflow lane can be given back, as its own terms require.
- `scripts/fleet-watchdog.sh`, its workflow, its tests and the
  `VERJSON_WATCHDOG_*` switches are deleted at step 6 — and #414 (cadence) is
  superseded rather than fixed.
- ~1000 lines of poll, rollup-parsing and self-exclusion logic leave
  `ai-review-merge.yml`, along with the defect classes that live in them (#276,
  #143, #263).
- Model-review budget is now spent before CI is known to be green, where today
  the poll defers it. This is a real cost increase and is accepted: a runner held
  for 30 minutes on a contended pool costs more than a review on a PR that later
  fails, and #292's re-review skip already suppresses repeat cost on unchanged
  diffs.
- **Risk, stated plainly:** a wrong or misspelled required context wedges every
  merge in the affected scope until an admin removes it. At `~ALL` that is the
  whole organization. This is why steps 1–3 exist and why `evaluate` is not
  optional.

## Alternatives considered

- **Event re-entry on `workflow_run: completed`** — #341's original proposal.
  Rejected: the gate also waits on commit *statuses* (`renovate/stability-days`,
  `ai-review-merge.yml:771`), which are not workflows and emit no such event; a
  `workflow_run` run carries default-branch context and no PR payload, forcing
  head re-derivation and reopening #377's conflation class; and it changes the
  entry-workflow identity ADR 0044 binds to. It is most of the cost of this ADR
  for a fraction of the benefit, and it keeps the gate an orchestrator.
- **Keep managing the deadlock** — more watchdog, more lanes. Each mitigation so
  far has been narrower than it looked, and none removes the poll.
- **Raise the hosted spending limit** so every repository uses hosted capacity.
  Buys time at recurring cost; a job still sleeps on a runner, and hosted minutes
  already hit the limit once (2026-07-17).
