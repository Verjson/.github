---
date: 2026-08-05
issue: 416
title: Declare a core check contract so GitHub can do the waiting the gate does in bash
---

Records the decision to stop managing the merge-gate poll deadlock and remove it, in
[ADR 0058](docs/decisions/0058-github-waits-for-checks-not-the-gate/README.md), plus the
first read-only step towards it.

The gate holds a self-hosted runner for up to 30 minutes polling the commit check-runs and
statuses rollup (`ai-review-merge.yml:581-947`). That loop is a hand-rolled
`required_status_checks` rule. Two facts, both verified rather than assumed, make it
removable: the org ruleset `main-protection` (`18098028`, scoped `~ALL`) has **no**
`required_status_checks` rule — GitHub has never been told which checks must pass, so it
cannot wait for them — and `allow_auto_merge` is already `true`. The gate's own merge step
is already dead code (`if: ${{ false }}` at `:1587`); the merge is performed by
`ai-privileged-merge.yml`, which is the job still on the pool.

- **The contract is declared, not derived.** Required checks are a core set per repository
  stack, satisfied by the reusable workflows the org already owns. Deriving them from
  observed check names would make the current drift permanent and enshrine a stale
  repository's job naming as organizational policy. The org already pins every inner job
  name (`node-ci` publishes `build-test`/`eligibility`, `helm-ci` publishes
  `lint-template`); the only free variable is the caller's job name, which is what a
  generated thin caller pins. `changelog / validate` is core for every package repository
  rather than an opt-in, which puts **#404's missing generated caller on the critical
  path** — a context cannot be required before something pins the caller that emits it.
- **`scripts/required-checks-audit.sh`** reports which repositories do not yet emit their
  stack's core set. Read-only by construction: it writes no ruleset, because the question
  "would this rule wedge anything?" must be answerable without being able to wedge
  anything. Non-zero while any repository would be blocked, so it can gate the migration
  in CI rather than be a report somebody remembers to read.
- **A required check must be skippable but never absent.** A conditional job reports
  `skipped`, which satisfies a required check; a `paths:`-filtered workflow emits no check
  run at all and is permanently pending. The whole design rests on that distinction, so
  the audit counts a skipped run as present — reporting it as missing would send people to
  fix the one shape that is already correct.
- **The merge machinery is never required.** `dispatch-merge` and `privileged_merge`
  perform the merge; requiring them is a merge that waits for itself.

12 assertions in `scripts/required-checks-audit.test.sh`, each mutation-verified: treating
a skipped check as absent, letting the unknown-stack fault die in a subshell, dropping the
universal `gate` requirement, always exiting 0, and ignoring commit statuses are each
killed by exactly one named assertion. The subshell case was a real bug the tests caught —
`core_contract_for`'s `exit 2` inside `< <(...)` never reached the caller, so an
unclassified stack produced an empty contract and reported **conformant**.

- **`scripts/classify-repo-stacks.sh`** answers the question sampling cannot. A reusable
  call's check name is `<caller job> / <inner job>`; the org pins the right-hand side and
  nothing pins the left. A repository calling `node-ci` from a job named `build` emits
  `build / build-test`, so requiring `ci / build-test` wedges it — and its check history
  looks perfectly healthy, because the checks are green and merely named something else.
  Only reading the workflow files finds that, so this is a static scan needing no merge
  history. It also detects repositories that DEFINE contract jobs instead of calling them:
  scanning `uses:` alone classified this repository `none`, which would have made the one
  repository holding the merge gate the one whose test suite was not a merge precondition.

  Running it org-wide found a second gap in its own output: `none` conflated *no CI at
  all* with *CI we do not recognise*. The contract requires only `gate` for `none`, so a
  repository whose CI is local and unrecognised would have had its real CI quietly demoted
  to advisory — under-requiring rather than wedging, and therefore silent. Those are now
  counted and reported separately; only the wedge risk sets a non-zero exit, because a
  human has to confirm the other.

12 assertions in `scripts/classify-repo-stacks.test.sh`, all five guards mutation-verified.
The stub itself carried the bug worth recording: `${*##pattern}` strips element-wise, so the
fixture path resolved to `api`, every file read returned empty, and every repository
classified as `none`. The suite failed loudly rather than agreeing with itself, which is the
only reason it was found.

Nothing is enforced by this change. ADR 0056 stands and the watchdog stays armed and
load-bearing until the migration reaches its last step; this is step 2 of seven.

The follow-up hardens that read-only boundary: the contract and exact
evaluate-mode plan are now declared in `.github/required-check-contract.json`
with mutation disabled, while the audit statically rejects workflow-level path
filters and noncanonical stack/changelog caller job names. Archived
repositories are excluded and every unreadable, unclassified, unaudited,
pagination/rate-limit, or missing-context state prevents a green result. #404 is
complete; #416 remains open for the human-gated property/ruleset apply and
measurement.
