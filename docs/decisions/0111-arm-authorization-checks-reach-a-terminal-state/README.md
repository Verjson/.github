# 0111 — An armed authorization check always reaches a terminal state

- **Date:** 2026-08-20
- **Status:** Accepted
- **Issues:** [#964](https://github.com/Verjson/.github/issues/964), [#931](https://github.com/Verjson/.github/issues/931)
- **Category:** Merge-gate / authorization behavior — **sensitive class**
- **Extends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md) (head-bound authorization check-run), [ADR 0081](../0081-event-driven-terminal-ai-promotion/README.md) (event-driven terminal promotion)

## Context

`gate-rearm.yml` creates the required `AI review authorization` check-run as
`in_progress` **before** it uploads the immutable arm receipt and dispatches the
trusted review. That ordering is deliberate: the check-run ID is part of the receipt,
so the check must exist first.

Every failure path *after* creation completed the check-run explicitly — a fork head,
an unconsumed `re-review` label, a failed dispatch — except one. The `Upload immutable
arm receipt` step is an `actions/upload-artifact` action with no inline handler, and the
dispatch step that follows carries an `if:` with no status function, so an implicit
`success()` skips it when the upload fails. A failed upload therefore ended the job with
the check-run still `in_progress`, and nothing else in the system ever completed it:

- The trusted review was never dispatched, so `ai-review-merge.yml`'s
  `complete-authorization` job — the normal owner of that `PATCH ... status=completed` —
  never ran.
- ADR 0081 §4 makes `ai-promotion-retry.yml` treat a pending required check as "not
  ready yet; a later CI completion supplies the next attempt". It is a promotion retry,
  not a check-run reconciler, and completing someone else's pending check is explicitly
  not its job.
- Any subsequent arm event for the same head hit the duplicate-event guard
  (`Authorization already exists for $head_sha`), which keys only on a check-run being
  present, and exited `0` as a no-op — so the arm run reported **success** while doing
  nothing.

The quota outage in #931 made that path routine: the upload step failed with
`Artifact storage quota has been hit`. Observed on 2026-08-19/20, both
`verjson-browser-agent#46` (head `6402c75`) and `verjson-cloud-storage#92` (head
`de80854`) were `BLOCKED` behind *only* `in_progress` authorization check-runs — four
and three of them respectively, each from a different arm attempt, none with a
conclusion, and a later arm run at 19:58Z that "succeeded" purely by taking the
duplicate-event no-op. The PRs could not proceed and showed no failure explaining why.

## Decision

The arm gives the check-run it created a terminal state before its job ends. A new final
step, `Complete the authorization when no review was dispatched`, runs when

```
always() && steps.arm.outputs.check_id != '' && steps.dispatch.outcome != 'success'
```

reads the check-run, and — **only if it is still `in_progress`** — completes it with
`conclusion=failure`, titled `Authorization receipt unavailable`, with output directing
the operator to rerun the arm run (`GITHUB_RUN_ATTEMPT > 1` is the existing
`operator_recovery` path) and explicitly *not* to add the `re-review` label.

Three properties keep this inside the authorization trust boundary rather than adjacent
to it:

- **It can only ever write a failure.** The step has no branch that writes `success`, so
  it cannot manufacture authorization. `scripts/ci-gate/arm-authorization-terminal-state.test.sh`
  asserts the absence of `conclusion=success` in the step body as a structural invariant.
- **It never touches a check-run it does not own.** A dispatched review owns its check-run
  (`steps.dispatch.outcome == 'success'` skips the step entirely), and the `in_progress`
  precheck means a path that already completed the check — the fork refusal, the retained
  `re-review` label, the failed dispatch — keeps its own, more specific conclusion.
- **No receipt means no spend.** Dispatch happens strictly after receipt publication, so a
  check-run stranded by a failed upload provably never incurred a model charge. Recovering
  it by rerunning the arm is the *first* paid review for that head, not a second one, and
  ADR 0080's one-automatic-review-per-head accounting is undisturbed.

Failing the required check is the honest outcome, not a regression: `in_progress` and
`failure` block the PR identically, but only `failure` is visible, carries recovery
guidance, and is a state GitHub and a human can both reason about.

## Consequences

- A receipt-upload failure now surfaces as a red required check with an actionable
  message instead of a silent, permanently pending one.
- The recovery is manual by design (rerun the arm run). This ADR does **not** make the
  arm re-arm a head automatically after a failed authorization; the duplicate-event guard
  still absorbs ordinary PR events once any check-run exists for that head. Automatic
  recovery would have to distinguish a genuinely dead authorization from a live one, and
  that is a spend-policy decision, deliberately left out of scope here.
- Check-runs already stranded before this lands are not retroactively completed. They
  clear on the next arm run attempt, which creates a fresh check-run.
- A residual window remains: a failure *inside* the arm step between the check-run's
  creation and the step writing `check_id` to `$GITHUB_OUTPUT` leaves no output for the
  guard to key on. That window contains only local `jq`/`mkdir` work plus the fork path,
  which completes the check itself.

## Rejected alternatives

- **Make `ai-promotion-retry.yml` complete dangling check-runs.** It runs on unrelated CI
  completions with `checks: read`, has no receipt for a never-published authorization, and
  would have to conclude a check for a head whose arm it cannot verify. It would also
  contradict ADR 0081 §4, whose fail-safe is precisely that a pending check means "wait".
  The failure belongs to the job that created the check-run.
- **Complete any `in_progress` authorization check at the end of the arm job.** The happy
  path deliberately leaves the check `in_progress` for the trusted review to complete; a
  blanket rule would tear down every live authorization.
- **Treat the duplicate-event guard as the bug and re-arm when the previous authorization
  looks dead.** Plausible, and it would make the system self-heal once quota clears, but
  it turns a stranded check into automatic paid dispatch on the strength of an inference
  ("no live receipt artifact ⇒ no spend happened"). That is a spend-policy change and
  needs its own decision, not a bug fix.
- **Add `continue-on-error` to the upload step.** Would let dispatch proceed without a
  published receipt, breaking ADR 0079's trust anchor — strictly worse than a stuck check.
