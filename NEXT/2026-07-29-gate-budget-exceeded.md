# Size the gate review budget to the diff, and close the empty-verdict fail-open — 2026-07-29

The merge gate gave every PR the same first-pass review budget ($0.15, or $0.50
for sensitive paths) regardless of diff size, so a large PR exhausted the cheap
tier deterministically. `classify` now emits `changed_lines` and raises the
first-pass cap to $0.60 / $0.90 for diffs of 800+ changed lines — still strictly
under the $1.00 escalation cap, so escalation remains a step up.

Investigating that turned up a fail-open in `Submit deterministic PR review`.
When all three model passes return no structured output, `VERDICT` is the empty
string, and `jq -e` on empty input exits **0** — so the fail-closed no-verdict
guard never fired and the step fell through to `gh pr review --approve` and
exited 0, letting an unreviewed PR merge. Only a malformed *non-empty* verdict
reached the fail-closed branch, which is why existing coverage never saw it. The
guard now rejects a blank verdict before consulting `jq`.

Budget exhaustion is also a named outcome now rather than the action's raw
`error_max_budget_usd` annotation: the gate reads the per-pass SDK transcripts
and reports `outcome=recovered` (annotation expected, run not blocked) or
`outcome=blocked` with a PR comment naming the diff size, the cap that was hit,
and the advice to split the PR. A missing or unparseable transcript degrades to
the generic no-verdict message and still blocks.

`scripts/ci-gate/budget-exceeded.test.sh` executes the extracted `classify`,
`Record model retry outcome` and `Submit deterministic PR review` blocks against
stubbed budget-exceeded payloads and is wired into `actions-ci`.

Refs: Verjson/.github#181, ADR 0032, observed on Verjson/verjson-cli-cloud#163.
