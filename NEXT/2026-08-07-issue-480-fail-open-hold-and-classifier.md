---
date: 2026-08-07
title: Make the terminal hold and the sensitive-path classifier fail closed
issue: 480
---

Three `if jq -e '<predicate>'` sites in `ai-review-merge.yml` read a **jq error** as a
`false` predicate, because `jq -e` exits non-zero for both and `if` cannot tell them apart.

- **Both terminal-hold checkpoints** (classify and merge) therefore read "the hold could not
  be evaluated" as "not held" and proceeded toward merge — inverting the one invariant
  ADR 0012 exists to protect, since `hold` / `DO NOT MERGE` / draft is the mechanism a human
  uses to *stop* an autonomous merge. Not theoretical: running the shipped merge block
  against a stubbed `gh`, **three of six malformed metadata fixtures reached `gh pr merge`**.
  The other three exited 0 without merging, reporting success for a decision never made.
- **The sensitive-path model selector** read a jq error as "not sensitive", silently
  downgrading a PR touching `auth`/`rbac`/`rls`/`abac`/`secret`/`payment`/`webhook`/
  `middleware`/`.github/` from `claude-sonnet-5` at $0.50 to `claude-haiku-4-5` at $0.15 —
  failing open on how hard the security review tries, on exactly the changes the classifier
  exists to escalate. That chains into #441, where the smaller budget makes
  `error_max_budget_usd` likelier and a budget-exhausted pass emits a non-blocking
  placeholder verdict the gate accepts. Together: a green "reviewed" auth PR that was never
  reviewed, with no step reporting anything wrong. Neither #480 nor the duplicate #482
  mentioned this site; it came out of sweeping every `if jq -e` in both gate workflows.

All three now materialise the predicate into a `true`/`false` string and branch on it, so a
jq error aborts under `set -e` and any third value fails closed explicitly — the form
`gate-rearm.yml` has used since ADR 0063.

**The cheap-lane detectors keep `if jq -e`, deliberately.** For `submodule-only`,
`docs-only` and `deletions-only`, a jq error reads as "not eligible for the cheap lane" and
the PR falls through to a full AI review — already fail-closed. "Replace every `if jq -e`"
would have converted three safe downgrades into hard errors while looking like progress. The
*direction* of each site's failure is what decides whether it is a defect, and
`budget-exceeded.test.sh` now pins that these three retain the old form.

The empty-diff short-circuit is unchanged for the same reason: with no files there are no
sensitive paths, and it is not the unreadable-response case, since the fetch runs under
`set -o pipefail` and a 5xx fails the step outright. A test pins that an empty diff reaches
its *named* path rather than arriving at the classifier and picking the cheap tier by
accident — same model and budget, so only the reason tells them apart.

Coverage executes the extracted `run:` blocks against a stubbed `gh` rather than grepping for
the fixed shape, so a rewrite that reintroduces the fail-open breaks the tests. Rationale is
in the [2026-08-07 amendment to ADR 0012](docs/decisions/0012-gate-honors-do-not-merge-label/README.md).

Also fixed along the way: `budget-exceeded.test.sh` writes its shared `gh` stub twice, so the
later definition silently wins for anything appended after it and classify produces no
outputs for a reason unrelated to the assertion. The new cases carry their own stub instead
of depending on test order.
