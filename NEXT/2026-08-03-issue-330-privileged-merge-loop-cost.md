---
date: 2026-08-03
issue: 330
title: Privileged merge stops re-paginating the PR file list on every poll
---

The privileged merge step holds a self-hosted runner for its whole polling
window, so work inside that loop is charged to the fleet, not just to the clock.
Three costs came out of it.

`workflow_files_changed` paginated the PR's complete file list on **every**
30-second tick — up to 80 times per run. It now runs once before the loop. The
file list is a property of the head SHA; the loop asserts the head is unchanged
before it would have run, and the authoritative guard immediately before
`gh pr merge` is untouched. As the base fast-forwards the three-dot diff can
only shrink, so evaluating early is the conservative direction, not the
permissive one.

The two `jq` passes that counted failed and pending checks from the same
filtered rollup are now one pass, with an explicit shape assertion so a `jq`
failure still fails closed rather than being masked by `read`.

Follow-up issues are filed with a bounded fan-out instead of serially. The
obvious way to write that is wrong in a way nothing would have reported:
backgrounding inside `jq -c '.[]' | while` puts the jobs in the pipeline's
subshell, so the trailing `wait` has no children, the step returns while the
calls are in flight, and the follow-ups vanish with every command reporting
success. It uses process substitution instead, caps in-flight calls at eight so
a fifty-item verdict cannot trip a secondary rate limit, and
`scripts/ci-gate/followup-issues.test.sh` now exercises the extracted block
against a stubbed `gh`: the pipeline form loses 7 of 12 issues and fails.

What this does **not** change is the reason the step is slow at all — the loop
occupies a runner while waiting for checks it cannot influence.
